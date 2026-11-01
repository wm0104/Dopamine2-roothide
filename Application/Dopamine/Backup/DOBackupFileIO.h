#pragma once
#import <Foundation/Foundation.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <limits.h>
#import <stdlib.h>
#import <copyfile.h>
static const NSUInteger BMaxFiles = 8192, BMaxFile = 32 * 1024 * 1024, BMaxTotal = 128 * 1024 * 1024;
static NSString *const BDomain = @"DOConfigurationBackup";
static NSRecursiveLock *BLock;
static BOOL BFail(NSError **error, NSString *message) {
    if (error) *error = [NSError errorWithDomain:BDomain code:1 userInfo:@{NSLocalizedDescriptionKey:message ?: @"Backup operation failed"}];
    return NO;
}
static BOOL BPath(NSString *path) {
    if (![path isKindOfClass:NSString.class] || !path.length || [path hasPrefix:@"/"] || [path containsString:@"\\"] || [path rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound || ![[path.pathComponents componentsJoinedByString:@"/"] isEqual:path]) return NO;
    for (NSString *part in path.pathComponents) if ([part isEqual:@".."] || [part isEqual:@"."] || [part isEqual:@"/"]) return NO;
    return YES;
}
static BOOL BUnder(NSString *path, NSString *parent) {
    return [path isEqual:parent] || [path hasPrefix:[parent stringByAppendingString:@"/"]];
}
static NSString *BCanonical(NSString *path) {
    if (!path.length || ![path hasPrefix:@"/"]) return nil;
    char out[PATH_MAX];
    return realpath(path.fileSystemRepresentation, out) ? @(out) : nil;
}
// Pin every directory component. Never follow an archive-controlled link.
static int BOpenDirectory(NSString *path) {
    if (!path.length || ![path hasPrefix:@"/"]) { errno = EINVAL; return -1; }
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    for (NSString *part in path.pathComponents) {
        if ([part isEqual:@"/"]) continue;
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        close(fd); fd = next;
        if (fd < 0) break;
    }
    return fd;
}
static int BParent(int base, NSString *relative, BOOL create, uid_t uid, gid_t gid, NSMutableArray *created) {
    if (!BPath(relative)) return -1;
    int fd = dup(base);
    NSString *built = @"";
    NSArray *parts = relative.pathComponents;
    for (NSUInteger i = 0; i + 1 < parts.count; i++) {
        NSString *part = parts[i]; built = [built stringByAppendingPathComponent:part];
        BOOL made = NO;
        int next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        if (next < 0 && errno == ENOENT && create) {
            if (mkdirat(fd, part.fileSystemRepresentation, 0755) == 0) {
                made = YES;
                next = openat(fd, part.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            }
        }
        close(fd); fd = next;
        if (fd < 0) break;
        if (made) {
            [created addObject:built];
            if (fchown(fd, uid, gid) || fchmod(fd, 0755)) { close(fd); return -1; }
        }
    }
    return fd;
}
static NSData *BRead(int base, NSString *relative, struct stat *metadata, BOOL *missing, NSError **error) {
    if (missing) *missing = NO;
    int parent = BParent(base, relative, NO, 0, 0, nil);
    if (parent < 0) {
        if (errno == ENOENT && missing) { *missing = YES; return nil; }
        BFail(error, @"Unsafe or unavailable parent directory"); return nil;
    }
    int fd = openat(parent, relative.lastPathComponent.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC);
    close(parent);
    if (fd < 0) {
        if (errno == ENOENT && missing) { *missing = YES; return nil; }
        BFail(error, @"Cannot open regular backup file"); return nil;
    }
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_nlink != 1 || st.st_size < 0 || st.st_size > (off_t)BMaxFile) {
        close(fd); BFail(error, @"Link, non-regular file or oversized file rejected"); return nil;
    }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    NSUInteger offset = 0;
    while (offset < data.length) {
        ssize_t n = read(fd, (char *)data.mutableBytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); BFail(error, @"File changed during read"); return nil; }
        offset += n;
    }
    char extra;
    BOOL same = read(fd, &extra, 1) == 0;
    struct stat after;
    same = same && !fstat(fd, &after) && after.st_size == st.st_size && after.st_mtime == st.st_mtime && after.st_nlink == 1;
    close(fd);
    if (!same) { BFail(error, @"File changed during read"); return nil; }
    if (metadata) *metadata = st;
    return data;
}
static BOOL BWrite(int base, NSString *relative, NSData *data, struct stat st, int metadataFD, NSMutableArray *created, NSError **error) {
    int parent = BParent(base, relative, YES, st.st_uid, st.st_gid, created);
    if (parent < 0) return BFail(error, @"Cannot securely open destination parent");
    NSString *temp = [@".backup-write-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int fd = openat(parent, temp.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    BOOL ok = fd >= 0;
    NSUInteger offset = 0;
    while (ok && offset < data.length) {
        ssize_t n = write(fd, (const char *)data.bytes + offset, data.length - offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) ok = NO; else offset += n;
    }
    if (ok && metadataFD >= 0) ok = !fcopyfile(metadataFD, fd, NULL, COPYFILE_METADATA);
    if (ok) ok = !fchown(fd, st.st_uid, st.st_gid) && !fchmod(fd, st.st_mode & 0777);
    struct timespec times[2] = { st.st_atimespec, st.st_mtimespec };
    if (ok && st.st_mtimespec.tv_sec) ok = !futimens(fd, times);
    if (ok) ok = !fsync(fd);
    if (fd >= 0) close(fd);
    if (ok) ok = !renameat(parent, temp.fileSystemRepresentation, parent, relative.lastPathComponent.fileSystemRepresentation);
    if (!ok) unlinkat(parent, temp.fileSystemRepresentation, 0);
    else if (fsync(parent)) ok = NO;
    close(parent);
    return ok || BFail(error, @"Atomic configuration write failed");
}
