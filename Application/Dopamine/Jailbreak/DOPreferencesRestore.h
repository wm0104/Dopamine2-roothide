// Included only by DOMainViewController.m: no additional Xcode build target wiring.
// All untrusted traversal is descriptor-relative and never follows symlinks.
#pragma once
#import <Foundation/Foundation.h>
#import <dirent.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

static NSError *DORestoreError(NSString *message) {
    return [NSError errorWithDomain:@"DOPreferencesRestore" code:1
                          userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSString *DORestoreCanonical(NSString *path) {
    char *p = realpath(path.fileSystemRepresentation, NULL);
    if (!p) return nil;
    NSString *result = [NSString stringWithUTF8String:p];
    free(p); return result;
}
static BOOL DORestoreContains(NSString *parent, NSString *path) {
    return [path isEqualToString:parent] || [path hasPrefix:[parent stringByAppendingString:@"/"]];
}
// Only /var's system alias is accepted in user input. All other components,
// including the supplied directory, are opened without following symlinks.
static int DORestoreOpenSource(NSString *path) {
    if ([path hasPrefix:@"/var/"] || [path isEqualToString:@"/var"])
        path = [@"/private" stringByAppendingString:path];
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    for (NSString *part in path.pathComponents) {
        if ([part isEqualToString:@"/"]) continue;
        if ([part isEqualToString:@".."] || [part isEqualToString:@"."]) { close(fd); return -1; }
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        close(fd); fd = next;
        if (fd < 0) break;
    }
    return fd;
}
static int DORestoreParent(int root, NSString *relative, BOOL create) {
    int fd = dup(root);
    NSArray *parts = relative.pathComponents;
    for (NSUInteger i = 0; fd >= 0 && i + 1 < parts.count; i++) {
        const char *part = [parts[i] fileSystemRepresentation];
        if (create && mkdirat(fd, part, 0700) == 0) {
            int child = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (child < 0 || fchown(child, 501, 501) || fchmod(child, 0755)) {
                if (child >= 0) close(child);
                close(fd); return -1;
            }
            close(child);
        }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        close(fd); fd = next;
    }
    return fd;
}
static BOOL DORestoreSame(struct stat a, struct stat b) {
    return a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
           a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec &&
           a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
           a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec &&
           a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec;
}
// Stream arbitrary regular files; no extension, plist validation or size filtering.
// Original descriptors are read-only, so even hard-linked source files are safe.
static BOOL DORestoreAtomicCopy(int input, int parent, NSString *name, struct stat metadata) {
    NSString *temp = [@".dopamine-write-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int out = openat(parent, temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    if (out < 0) return NO;
    struct stat before, after;
    BOOL ok = fstat(input, &before) == 0 && S_ISREG(before.st_mode) && lseek(input, 0, SEEK_SET) == 0;
    char buffer[65536];
    while (ok) {
        ssize_t n = read(input, buffer, sizeof(buffer));
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = NO; break; }
        if (!n) break;
        ssize_t offset = 0;
        while (offset < n) {
            ssize_t written = write(out, buffer + offset, (size_t)(n - offset));
            if (written < 0 && errno == EINTR) continue;
            if (written <= 0) { ok = NO; break; }
            offset += written;
        }
    }
    ok = ok && fstat(input, &after) == 0 && DORestoreSame(before, after);
    ok = ok && fchown(out, metadata.st_uid, metadata.st_gid) == 0 &&
         fchmod(out, metadata.st_mode & 0777) == 0 && fsync(out) == 0;
    if (close(out)) ok = NO;
    if (ok) ok = renameat(parent, temp.fileSystemRepresentation, parent, name.fileSystemRepresentation) == 0;
    if (!ok) unlinkat(parent, temp.fileSystemRepresentation, 0);
    return ok;
}

@interface DOPreferencesRestore : NSObject
@property(nonatomic, copy) NSString *source;
@property(nonatomic, copy) NSString *destination;
@property(nonatomic, copy) NSString *backup;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *files;
@property(nonatomic) int sourceFD;
@property(nonatomic) int targetFD;
@property(nonatomic) NSUInteger restored;
@property(nonatomic) NSUInteger skipped;
- (BOOL)prepare:(NSString *)input destination:(NSString *)destination error:(NSError **)error;
- (BOOL)apply:(NSError **)error;
@end

@implementation DOPreferencesRestore
- (instancetype)init {
    if ((self = [super init])) { _sourceFD = -1; _targetFD = -1; _files = [NSMutableArray array]; }
    return self;
}
- (void)dealloc { if (_sourceFD >= 0) close(_sourceFD); if (_targetFD >= 0) close(_targetFD); }
- (BOOL)fail:(NSString *)message error:(NSError **)error {
    if (error) *error = DORestoreError(message);
    return NO;
}
- (BOOL)scan:(int)fd prefix:(NSString *)prefix error:(NSError **)error {
    DIR *dir = fdopendir(dup(fd));
    if (!dir) return [self fail:@"无法枚举源目录。" error:error];
    BOOL ok = YES; struct dirent *entry;
    for (;;) {
        errno = 0; entry = readdir(dir);
        if (!entry) { if (errno) ok = [self fail:@"源目录读取失败。" error:error]; break; }
        if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, "..")) continue;
        NSString *name = [[NSFileManager defaultManager] stringWithFileSystemRepresentation:entry->d_name length:strlen(entry->d_name)];
        if (!name) { ok = [self fail:@"源目录含无法表示的文件名。" error:error]; break; }
        NSString *relative = prefix.length ? [prefix stringByAppendingPathComponent:name] : name;
        struct stat st;
        if (fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { ok = [self fail:[@"无法检查：" stringByAppendingString:relative] error:error]; break; }
        if (S_ISDIR(st.st_mode)) {
            int child = openat(fd, entry->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
            if (child < 0) ok = [self fail:[@"无法打开目录：" stringByAppendingString:relative] error:error];
            else { ok = [self scan:child prefix:relative error:error]; close(child); }
        } else if (S_ISREG(st.st_mode)) {
            [self.files addObject:@{@"path":relative, @"sourceStat":[NSData dataWithBytes:&st length:sizeof(st)]}];
        } else {
            self.skipped++; // Explicitly reported; never traverse symlinks or open special files.
        }
        if (!ok) break;
    }
    closedir(dir); return ok;
}
- (BOOL)prepare:(NSString *)input destination:(NSString *)destination error:(NSError **)error {
    if (![input hasPrefix:@"/"] || [input.pathComponents containsObject:@".."] ||
        [input.pathComponents containsObject:@"."])
        return [self fail:@"请输入绝对目录路径，不支持 .、.. 或符号链接目录。" error:error];
    for (NSUInteger i = 0; i < input.length; i++) {
        if ([input characterAtIndex:i] == 0) return [self fail:@"路径不能包含 NUL 字符。" error:error];
    }
    NSString *base = input.stringByStandardizingPath;
    int baseFD = DORestoreOpenSource(base);
    if (baseFD < 0) return [self fail:@"源目录不存在、不可读或包含符号链接。" error:error];
    NSString *suffix = [base.lastPathComponent isEqualToString:@"Preferences"] ? @"" :
                       ([base.lastPathComponent isEqualToString:@"Library"] ? @"Preferences" : @"Library/Preferences");
    self.source = suffix.length ? [base stringByAppendingPathComponent:suffix] : base;
    close(baseFD);
    self.sourceFD = DORestoreOpenSource(self.source);
    if (self.sourceFD < 0) return [self fail:@"未找到可读的 Preferences 目录（支持备份根目录、Library 或 Preferences）。" error:error];
    self.source = DORestoreCanonical(self.source);
    // RootHide's /var and private/var links are trusted resolver infrastructure.
    self.destination = DORestoreCanonical(destination);
    if (!self.source || !self.destination) return [self fail:@"无法解析源目录或活动 RootHide 配置目录。" error:error];
    if (DORestoreContains(self.source, self.destination) || DORestoreContains(self.destination, self.source))
        return [self fail:@"源目录与目标目录不能相同或互相包含。" error:error];
    struct stat pinnedSource, namedSource, pinnedTarget;
    if (fstat(self.sourceFD, &pinnedSource) || stat(self.source.fileSystemRepresentation, &namedSource) ||
        pinnedSource.st_dev != namedSource.st_dev || pinnedSource.st_ino != namedSource.st_ino)
        return [self fail:@"源目录在检查时发生变化。" error:error];
    self.targetFD = open(self.destination.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (self.targetFD < 0) return [self fail:@"无法打开活动 RootHide Preferences。" error:error];
    if (fstat(self.targetFD, &pinnedTarget) ||
        (pinnedSource.st_dev == pinnedTarget.st_dev && pinnedSource.st_ino == pinnedTarget.st_ino))
        return [self fail:@"源与目标身份相同或无法验证目录身份。" error:error];
    if (![self scan:self.sourceFD prefix:@"" error:error]) return NO;
    if (!self.files.count) return [self fail:@"源目录没有普通文件。" error:error];
    // Preflight every destination before confirmation; nonexistent parents are OK.
    for (NSMutableDictionary *item in [self.files copy]) {
        NSString *path = item[@"path"];
        int parent = DORestoreParent(self.targetFD, path, NO);
        if (parent < 0) {
            if (errno == ENOENT) continue;
            return [self fail:[@"目标父目录不安全或不可读：" stringByAppendingString:path] error:error];
        }
        struct stat st;
        int r = fstatat(parent, path.lastPathComponent.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW);
        close(parent);
        if ((!r && !S_ISREG(st.st_mode)) || (r && errno != ENOENT))
            return [self fail:[@"目标不是普通文件或无法读取：" stringByAppendingString:path] error:error];
    }
    return YES;
}
- (BOOL)apply:(NSError **)error {
    struct stat pinned, named;
    if (fstat(self.targetFD, &pinned) || lstat(self.destination.fileSystemRepresentation, &named) ||
        !S_ISDIR(named.st_mode) || pinned.st_dev != named.st_dev || pinned.st_ino != named.st_ino)
        return [self fail:@"目标目录身份已改变，请重新检查，未写入配置。" error:error];
    // Freeze the overwrite set and back up ALL originals before the first restore.
    NSString *backupName = [@".dopamine-originals-" stringByAppendingString:NSUUID.UUID.UUIDString];
    if (mkdirat(self.targetFD, backupName.fileSystemRepresentation, 0700))
        return [self fail:@"无法创建原件备份；未写入配置文件。" error:error];
    self.backup = [self.destination stringByAppendingPathComponent:backupName];
    int backupFD = openat(self.targetFD, backupName.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (backupFD < 0) return [self fail:@"无法打开原件备份目录；未写入配置文件。" error:error];
    NSMutableArray *prepared = [NSMutableArray array];
    BOOL ok = YES;
    for (NSDictionary *item in self.files) {
        NSString *path = item[@"path"], *name = path.lastPathComponent;
        int parent = DORestoreParent(self.targetFD, path, NO);
        struct stat original = {0}; BOOL exists = NO;
        if (parent < 0) { if (errno != ENOENT) ok = NO; }
        else {
            int r = fstatat(parent, name.fileSystemRepresentation, &original, AT_SYMLINK_NOFOLLOW);
            if (!r) { exists = YES; if (!S_ISREG(original.st_mode)) ok = NO; }
            else if (errno != ENOENT) ok = NO;
        }
        if (ok && exists) {
            int input = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
            int output = DORestoreParent(backupFD, path, YES);
            struct stat actual;
            ok = input >= 0 && output >= 0 && fstat(input, &actual) == 0 && DORestoreSame(original, actual) &&
                 DORestoreAtomicCopy(input, output, name, original);
            if (input >= 0) close(input);
            if (output >= 0) close(output);
        }
        if (parent >= 0) close(parent);
        if (!ok) break;
        [prepared addObject:@{@"path":path, @"sourceStat":item[@"sourceStat"], @"exists":@(exists),
                             @"originalStat":[NSData dataWithBytes:&original length:sizeof(original)]}];
    }
    close(backupFD);
    if (!ok) return [self fail:@"目标发生变化或原件备份失败；未写入任何配置文件。已生成的备份保留。" error:error];
    for (NSDictionary *item in prepared) {
        NSString *path = item[@"path"], *name = path.lastPathComponent;
        int sourceParent = DORestoreParent(self.sourceFD, path, NO);
        int input = sourceParent < 0 ? -1 : openat(sourceParent, name.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
        if (sourceParent >= 0) close(sourceParent);
        struct stat expectedSource, original, actual, current;
        [item[@"sourceStat"] getBytes:&expectedSource length:sizeof(expectedSource)];
        [item[@"originalStat"] getBytes:&original length:sizeof(original)];
        int parent = DORestoreParent(self.targetFD, path, YES);
        BOOL exists = [item[@"exists"] boolValue];
        ok = input >= 0 && parent >= 0 && fstat(input, &actual) == 0 &&
             S_ISREG(actual.st_mode) && DORestoreSame(expectedSource, actual);
        if (ok) {
            int r = fstatat(parent, name.fileSystemRepresentation, &current, AT_SYMLINK_NOFOLLOW);
            ok = exists ? (!r && S_ISREG(current.st_mode) && DORestoreSame(original, current)) : (r < 0 && errno == ENOENT);
        }
        struct stat metadata = original;
        if (!exists) { metadata.st_uid = 501; metadata.st_gid = 501; metadata.st_mode = 0644; }
        if (ok) ok = DORestoreAtomicCopy(input, parent, name, metadata);
        if (input >= 0) close(input);
        if (parent >= 0) close(parent);
        if (!ok) return [self fail:[NSString stringWithFormat:@"恢复停止于 %@：源/目标发生变化、权限不足或写入失败。已完成 %lu/%lu；不会自动回滚，原件备份保留。", path, (unsigned long)self.restored, (unsigned long)self.files.count] error:error];
        self.restored++;
    }
    return YES;
}
@end
