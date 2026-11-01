#import "DOConfigurationBackupManager.h"
#ifndef DO_BACKUP_TESTING
#import "DOEnvironmentManager.h"
#import <libjailbreak/info.h>
#endif
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <dirent.h>
#import <limits.h>
#import <stdlib.h>
#import <copyfile.h>
#import <dispatch/dispatch.h>

#import "DOBackupFileIO.h"
// Only these seven folders can ever be backed up or replaced.
static NSArray<NSString *> *BBackupFolders(void) {
    return @[@"config/Preferences", @"config/ControlCenter", @"config/CallAssist",
             @"config/RootHide", @"config/CallAssistActivation", @"config/Snapper3", @"sources/sources.list.d"];
}
static NSString *BFolderForPath(NSString *path) {
    if (BPath(path)) for (NSString *folder in BBackupFolders()) if (BUnder(path, folder)) return folder;
    return nil;
}
static NSDictionary *BMetadata(struct stat st) {
    return @{@"mode":@(st.st_mode & 0777), @"uid":@(st.st_uid), @"gid":@(st.st_gid),
             @"seconds":@(st.st_mtimespec.tv_sec), @"nanoseconds":@(st.st_mtimespec.tv_nsec)};
}
static struct stat BStat(NSDictionary *metadata) {
    struct stat st = {0};
    st.st_mode = [metadata[@"mode"] unsignedIntValue]; st.st_uid = [metadata[@"uid"] unsignedIntValue];
    st.st_gid = [metadata[@"gid"] unsignedIntValue];
    st.st_mtimespec.tv_sec = [metadata[@"seconds"] longLongValue];
    st.st_mtimespec.tv_nsec = [metadata[@"nanoseconds"] longValue];
    st.st_atimespec = st.st_mtimespec;
    return st;
}

// Backups are user-visible in Files/Filza, so the name carries the creation time.
// A short suffix only appears when two backups would otherwise collide.
static NSString *BArchiveName(BOOL safety, int base) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *prefix = safety ? @"恢复前备份" : @"配置备份";
    NSString *stamp = [formatter stringFromDate:[NSDate date]];
    for (int attempt = 0; attempt < 100; attempt++) {
        NSString *name = attempt ? [NSString stringWithFormat:@"%@_%@-%d", prefix, stamp, attempt + 1]
                                 : [NSString stringWithFormat:@"%@_%@", prefix, stamp];
        struct stat existing;
        if (fstatat(base, name.fileSystemRepresentation, &existing, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT) return name;
    }
    return nil;
}

// Retention keeps the newest two manual backups and the newest safety backup.
// Only directories this build created (exact generated name AND our manifest)
// are ever removed; everything else in the folder is left untouched.
static NSString *const BRetentionMarker = @".dopamine-retention.v1";
static const NSUInteger BRetentionManualKeep = 2;
static const NSUInteger BRetentionSafetyKeep = 1;
static BOOL BGeneratedName(NSString *name, BOOL *safety) {
    if (![name isKindOfClass:NSString.class] || !name.length || name.pathComponents.count != 1) return NO;
    BOOL manual = [name hasPrefix:@"配置备份_"], safe = [name hasPrefix:@"恢复前备份_"];
    if (!manual && !safe) return NO;
    static NSRegularExpression *rule;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rule = [NSRegularExpression regularExpressionWithPattern:@"^(配置备份|恢复前备份)_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(-[0-9]{1,3})?$" options:0 error:nil];
    });
    if ([rule numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] != 1) return NO;
    if (safety) *safety = safe;
    return YES;
}
// Older builds of this app named archives after a UUID only. These count toward
// the same limit, but a name alone is never trusted: the manifest must be ours.
static BOOL BLegacyName(NSString *name, BOOL *safety) {
    if (![name isKindOfClass:NSString.class] || !name.length || name.pathComponents.count != 1) return NO;
    BOOL safe = [name hasPrefix:@"SafetyBackup-"];
    if (!safe && ![name hasPrefix:@"ConfigurationBackup-"]) return NO;
    static NSRegularExpression *rule;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        rule = [NSRegularExpression regularExpressionWithPattern:@"^(ConfigurationBackup|SafetyBackup)-[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$" options:0 error:nil];
    });
    if ([rule numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] != 1) return NO;
    if (safety) *safety = safe;
    return YES;
}
static BOOL BWriteRetentionMarker(int base, NSError **error) {
    int fd = openat(base, BRetentionMarker.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return errno == EEXIST || BFail(error, @"Cannot record the one-time cleanup confirmation");
    BOOL ok = write(fd, "1\n", 2) == 2 && !fsync(fd);
    close(fd);
    return ok || BFail(error, @"Cannot record the one-time cleanup confirmation");
}
// Removes an already verified archive. Links and special files are never followed.
static BOOL BRemoveVerifiedTree(int parent, NSString *name, NSError **error) {
    if (!BPath(name)) return BFail(error, @"Unsafe old backup name");
    int fd = openat(parent, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return BFail(error, @"Cannot open the old backup folder safely");
    DIR *stream = fdopendir(fd);
    if (!stream) { close(fd); return BFail(error, @"Cannot enumerate the old backup folder"); }
    BOOL ok = YES; struct dirent *entry; NSMutableArray *directories = [NSMutableArray array];
    while (ok && (entry = readdir(stream))) {
        NSString *child = [NSString stringWithUTF8String:entry->d_name];
        if (!child || [child isEqual:@"."] || [child isEqual:@".."]) continue;
        struct stat st;
        if (!BPath(child) || fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { ok = BFail(error, @"Invalid old backup entry"); break; }
        if (S_ISDIR(st.st_mode)) [directories addObject:child];
        else if (S_ISREG(st.st_mode) && st.st_nlink == 1) { if (unlinkat(fd, entry->d_name, 0)) ok = BFail(error, @"Cannot remove an old backup file"); }
        else ok = BFail(error, @"Links and special files are never deleted");
    }
    for (NSString *child in directories) { if (!ok) break; ok = BRemoveVerifiedTree(fd, child, error); }
    closedir(stream);
    if (ok) ok = !unlinkat(parent, name.fileSystemRepresentation, AT_REMOVEDIR) || BFail(error, @"Cannot remove the old backup folder");
    return ok;
}

@interface DOConfigurationBackupManager ()
@property(nonatomic, copy) NSString *testRoot;
@property(nonatomic, copy, readwrite) NSDictionary<NSString *, id> *lastBackupReport;
@end
@implementation DOConfigurationBackupManager
+ (void)initialize { if (self == DOConfigurationBackupManager.class) BLock = [NSRecursiveLock new]; }
+ (instancetype)sharedManager { static id manager; static dispatch_once_t once; dispatch_once(&once, ^{ manager = [self new]; }); return manager; }
#ifdef DO_BACKUP_TESTING
- (instancetype)initWithTestRoot:(NSString *)root { if ((self = [super init])) { _testRoot = root; _failAfterWrites = -1; } return self; }
#endif
// Catch exceptions INSIDE both helpers, so their non-finally privilege cleanup always runs.
- (BOOL)protected:(BOOL (^)(NSError **))block error:(NSError **)error {
    __block BOOL result = NO, ran = NO; __block NSError *failure = nil;
    void (^action)(void) = ^{ ran = YES; @try { result = block(&failure); } @catch (NSException *exception) { BFail(&failure, @"Protected file operation raised an exception"); } };
#ifdef DO_BACKUP_TESTING
    action();
#else
    [DOEnvironmentManager.sharedManager runAsRoot:^{
        @try { [DOEnvironmentManager.sharedManager runUnsandboxed:action]; }
        @catch (NSException *exception) { BFail(&failure, @"Cannot enter protected file scope"); }
    }];
#endif
    if (!ran) BFail(&failure, @"Root privileges are unavailable");
    if (!result && error) *error = failure ?: [NSError errorWithDomain:BDomain code:2 userInfo:@{NSLocalizedDescriptionKey:@"Protected operation failed"}];
    return result;
}
- (NSString *)runtimeRoot:(NSError **)error {
#ifdef DO_BACKUP_TESTING
    NSString *root = self.testRoot;
#else
    [DOEnvironmentManager sharedManager];
    const char *raw = jbinfo(rootPath);
    NSString *root = raw && raw[0] ? [NSString stringWithUTF8String:raw] : nil;
#endif
    NSString *resolved = root.length ? BCanonical(root) : nil;
    if (!resolved || [resolved isEqual:@"/"]) { BFail(error, @"Current RootHide jailbreak root is unavailable"); return nil; }
    return resolved;
}
- (NSString *)anchor:(NSString *)kind root:(NSString *)root error:(NSError **)error {
    // RootHide deliberately uses trusted runtime /var -> secondary-root links.
    // Resolve ONLY these fixed runtime anchors; no archive path participates.
    NSString *relative = [kind isEqual:@"config"] ? @"var/mobile/Library" : @"etc/apt";
    NSString *path = BCanonical([root stringByAppendingPathComponent:relative]);
    if (!path) BFail(error, @"Runtime configuration directory is unavailable");
    return path;
}
- (BOOL)validateStorageDirectory:(NSURL *)directory error:(NSError **)error {
    if (!directory.isFileURL || directory.query || directory.fragment) return BFail(error, @"Choose a local Files folder");
    NSString *original = directory.path;
    NSString *standard = original.stringByStandardizingPath;
    // Foundation may shorten /private/var to /var on macOS when enumerating URLs.
    // Accept only these system aliases; realpath equality below still rejects links.
    BOOL systemAlias = (BUnder(standard, @"/var") || BUnder(standard, @"/tmp")) &&
        [original isEqual:[@"/private" stringByAppendingString:standard]];
    if (![original isEqual:standard] && !systemAlias) return BFail(error, @"Non-canonical folder path rejected");
    NSString *path = original;
    if (BUnder(path, @"/var")) path = [@"/private" stringByAppendingString:path];
    if (BUnder(path, @"/tmp")) path = [@"/private" stringByAppendingString:path];
    NSString *resolved = BCanonical(path);
    if (!resolved || ![resolved isEqual:path]) return BFail(error, @"Folder symlink or unavailable folder rejected");
    for (NSString *part in resolved.pathComponents) if ([[part lowercaseString] containsString:@".jbroot"]) return BFail(error, @"Backups must be outside all jailbreak roots");
    BOOL allowed = NO;
#ifdef DO_BACKUP_TESTING
    allowed = BUnder(resolved, BCanonical(NSTemporaryDirectory()));
#else
    for (NSString *base in @[NSHomeDirectory(), @"/private/var/mobile/Documents", @"/private/var/mobile/Containers", @"/private/var/mobile/Library/Mobile Documents", @"/private/var/mobile/Library/CloudStorage", @"/private/var/mobile/Library/Application Support/File Provider Storage", @"/Volumes"])
        if (BUnder(resolved, BCanonical(base) ?: base) && ![resolved isEqual:base]) allowed = YES;
#endif
    if (!allowed) return BFail(error, @"Protected/system folder is not backup storage; choose a Files data folder");
    int fd = BOpenDirectory(resolved);
    if (fd < 0) return BFail(error, @"Cannot securely open selected folder");
    NSString *probe = [@".backup-probe-" stringByAppendingString:NSUUID.UUID.UUIDString];
    int out = openat(fd, probe.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
    BOOL ok = out >= 0;
    if (out >= 0) { close(out); ok = unlinkat(fd, probe.fileSystemRepresentation, 0) == 0; }
    close(fd);
    return ok || BFail(error, @"Selected folder is not writable");
}
- (BOOL)coordinate:(NSURL *)url writing:(BOOL)writing block:(BOOL (^)(NSURL *, NSError **))block error:(NSError **)error {
    __block BOOL ok = NO; __block NSError *failure = nil;
    NSFileCoordinator *coordinator = [[NSFileCoordinator alloc] initWithFilePresenter:nil];
    void (^access)(NSURL *) = ^(NSURL *actual) { @try { ok = block(actual, &failure); } @catch (NSException *e) { BFail(&failure, @"File provider operation raised an exception"); } };
    NSError *coordError = nil;
    if (writing) [coordinator coordinateWritingItemAtURL:url options:NSFileCoordinatorWritingForMerging error:&coordError byAccessor:access];
    else [coordinator coordinateReadingItemAtURL:url options:NSFileCoordinatorReadingWithoutChanges error:&coordError byAccessor:access];
    if (!ok && error) *error = failure ?: coordError;
    return ok;
}
- (BOOL)walk:(NSString *)directory prefix:(NSString *)prefix files:(NSMutableArray *)files bytes:(NSUInteger *)bytes error:(NSError **)error {
    int fd = BOpenDirectory(directory);
    if (fd < 0) return BFail(error, @"Unsafe backup directory");
    DIR *stream = fdopendir(fd);
    if (!stream) { close(fd); return BFail(error, @"Cannot enumerate directory"); }
    BOOL ok = YES; struct dirent *entry;
    while (ok && (entry = readdir(stream))) {
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if ([name isEqual:@"."] || [name isEqual:@".."]) continue;
        NSString *relative = [prefix stringByAppendingPathComponent:name ?: @""];
        struct stat st;
        if (!name || !BPath(relative) || relative.pathComponents.count > 32 || fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { ok = BFail(error, @"Invalid archive path"); break; }
        if (S_ISDIR(st.st_mode)) {
            if (files.count >= BMaxFiles) { ok = BFail(error, @"Too many backup entries"); break; }
            // Count directories too, so empty-directory bombs are bounded.
            [files addObject:@{ @"directory":relative }];
            ok = [self walk:[directory stringByAppendingPathComponent:name] prefix:relative files:files bytes:bytes error:error];
        } else if (S_ISREG(st.st_mode) && st.st_nlink == 1 && st.st_size >= 0 && st.st_size <= (off_t)BMaxFile) {
            *bytes += (NSUInteger)st.st_size;
            if (files.count >= BMaxFiles || *bytes > BMaxTotal) { ok = BFail(error, @"Backup size/count limit exceeded"); break; }
            [files addObject:@{ @"file":relative }];
        } else ok = BFail(error, @"Links, special files and oversized files are forbidden");
    }
    closedir(stream);
    return ok;
}
- (NSDictionary *)snapshot:(NSString *)root error:(NSError **)error {
    NSString *library = [self anchor:@"config" root:root error:error], *apt = [self anchor:@"sources" root:root error:error];
    if (!library || !apt) return nil;
    int configFD = BOpenDirectory(library), aptFD = BOpenDirectory(apt);
    if (configFD < 0 || aptFD < 0) { if (configFD >= 0) close(configFD); if (aptFD >= 0) close(aptFD); BFail(error, @"Cannot open runtime anchors"); return nil; }
    NSMutableArray *entries = [NSMutableArray array], *skipped = [NSMutableArray array], *directories = [NSMutableArray array];
    NSMutableDictionary *files = [NSMutableDictionary dictionary], *metadata = [NSMutableDictionary dictionary];
    NSUInteger bytes = 0, readBytes = 0; BOOL ok = YES;
    for (NSString *folder in BBackupFolders()) {
        BOOL config = [folder hasPrefix:@"config/"];
        int base = config ? configFD : aptFD;
        NSString *relative = folder.lastPathComponent;
        struct stat st;
        if (fstatat(base, relative.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW)) {
            if (errno == ENOENT) { [skipped addObject:@{@"path":folder, @"reason":@"folder-not-present"}]; continue; }
            ok = BFail(error, @"Cannot inspect a backup folder"); break;
        }
        if (!S_ISDIR(st.st_mode)) { ok = BFail(error, @"Backup roots must be real directories, not links"); break; }
        [entries addObject:@{@"directory":folder}];
        NSString *path = [(config ? library : apt) stringByAppendingPathComponent:relative];
        if (![self walk:path prefix:folder files:entries bytes:&bytes error:error]) { ok = NO; break; }
    }
    for (NSDictionary *entry in entries) {
        if (!ok) break;
        NSString *path = entry[@"file"] ?: entry[@"directory"];
        BOOL config = [path hasPrefix:@"config/"];
        int base = config ? configFD : aptFD;
        NSString *relative = [path substringFromIndex:config ? 7 : 8];
        struct stat st;
        if (entry[@"file"]) {
            NSData *data = BRead(base, relative, &st, NULL, error);
            if (!data) { ok = NO; break; }
            readBytes += data.length;
            if (readBytes > BMaxTotal) { ok = BFail(error, @"Backup size limit exceeded"); break; }
            files[path] = data;
        } else {
            int fd = BParent(base, [relative stringByAppendingPathComponent:@".entry"], NO, 0, 0, nil);
            if (fd < 0 || fstat(fd, &st)) { if (fd >= 0) close(fd); ok = BFail(error, @"Backup directory changed"); break; }
            close(fd); [directories addObject:path];
        }
        metadata[path] = BMetadata(st);
    }
    close(configFD); close(aptFD);
    // Reserve room for the manifest and category directories in the archive.
    if (entries.count + 16 > BMaxFiles) ok = BFail(error, @"Too many backup entries");
    self.lastBackupReport = @{@"included":@(files.count), @"skippedCount":@(skipped.count), @"skipped":skipped};
    return ok ? @{@"version":@2, @"files":files, @"directories":[directories sortedArrayUsingSelector:@selector(compare:)], @"metadata":metadata} : nil;
}

- (NSURL *)writeSnapshot:(NSDictionary *)snapshot directory:(NSURL *)directory safety:(BOOL)safety error:(NSError **)error {
    if (![self validateStorageDirectory:directory error:error]) return nil;
    int base = BOpenDirectory(BCanonical(directory.path));
    if (base < 0) { BFail(error, @"Storage folder became unavailable"); return nil; }
    NSString *uuid = NSUUID.UUID.UUIDString;
    NSString *stage = [@".staging-" stringByAppendingString:uuid];
    NSString *name = BArchiveName(safety, base);
    if (!name) { close(base); BFail(error, @"Cannot choose a free backup name"); return nil; }
    BOOL ok = mkdirat(base, stage.fileSystemRepresentation, 0700) == 0;
    int fd = ok ? openat(base, stage.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) : -1;
    struct stat mode = {0}; mode.st_mode = 0600; mode.st_uid = getuid(); mode.st_gid = getgid();
    NSMutableArray *created = [NSMutableArray array];
    NSDictionary *files = snapshot[@"files"];
    NSArray *paths = [files.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in snapshot[@"directories"]) if (ok) {
        int dir = BParent(fd, [path stringByAppendingPathComponent:@".entry"], YES, getuid(), getgid(), created);
        ok = dir >= 0; if (dir >= 0) close(dir);
    }
    for (NSString *path in paths) if (ok) ok = BWrite(fd, path, files[path], mode, -1, created, error);
    NSDictionary *manifest = @{@"format":@"org.roothide.configuration-backup", @"version":@2, @"files":paths,
                              @"directories":snapshot[@"directories"], @"metadata":snapshot[@"metadata"],
                              @"created":@([[NSDate date] timeIntervalSince1970]), @"safety":@(safety), @"report":self.lastBackupReport ?: @{}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
    NSUInteger total = json.length;
    for (NSData *data in files.allValues) total += data.length;
    if (total > BMaxTotal) ok = BFail(error, @"Backup including manifest exceeds size limit");
    if (ok) ok = json && BWrite(fd, @"manifest.json", json, mode, -1, created, error);
    if (fd >= 0) { if (ok) ok = !fsync(fd); close(fd); }
    if (ok) ok = !renameat(base, stage.fileSystemRepresentation, base, name.fileSystemRepresentation);
    if (ok) fsync(base);
    close(base);
    if (!ok) {
        // Only remove our UUID staging tree, never any caller-supplied archive.
        [[NSFileManager defaultManager] removeItemAtURL:[directory URLByAppendingPathComponent:stage] error:nil];
        BFail(error, @"Cannot publish complete backup"); return nil;
    }
    return [directory URLByAppendingPathComponent:name isDirectory:YES];
}
- (NSURL *)createBackupInDirectory:(NSURL *)directory error:(NSError **)error {
    [BLock lock]; @try {
        __block NSDictionary *snapshot = nil;
        if (![self protected:^BOOL(NSError **e) { NSString *root = [self runtimeRoot:e]; if (root) snapshot = [self snapshot:root error:e]; return snapshot != nil; } error:error]) return nil;
        if (![snapshot[@"directories"] count]) { BFail(error, @"None of the requested backup folders were found"); return nil; }
        __block NSURL *result = nil;
        [self coordinate:directory writing:YES block:^BOOL(NSURL *actual, NSError **e) { result = [self writeSnapshot:snapshot directory:actual safety:NO error:e]; return result != nil; } error:error];
        return result;
    } @finally { [BLock unlock]; }
}
- (NSDictionary *)loadArchive:(NSURL *)url error:(NSError **)error {
    if (![self validateStorageDirectory:url.URLByDeletingLastPathComponent error:error]) return nil;
    NSString *path = BCanonical(url.path);
    if (!url.isFileURL || ![path isEqual:[BCanonical(url.URLByDeletingLastPathComponent.path) stringByAppendingPathComponent:url.lastPathComponent]]) { BFail(error, @"Archive folder symlink rejected"); return nil; }
    NSMutableArray *entries = [NSMutableArray array]; NSUInteger bytes = 0;
    if (![self walk:path prefix:@"" files:entries bytes:&bytes error:error]) return nil;
    int fd = BOpenDirectory(path); if (fd < 0) return nil;
    BOOL absent = NO; NSData *json = BRead(fd, @"manifest.json", NULL, &absent, error);
    id manifest = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:error] : nil;
    BOOL ok = absent || (json && [manifest isKindOfClass:NSDictionary.class] &&
        [manifest[@"format"] isEqual:@"org.roothide.configuration-backup"] &&
        ( [manifest[@"version"] isEqual:@1] || [manifest[@"version"] isEqual:@2]) && [manifest[@"files"] isKindOfClass:NSArray.class]);
    BOOL complete = ok && [manifest[@"version"] isEqual:@2];
    NSArray *directories = complete ? manifest[@"directories"] : @[];
    NSDictionary *metadata = complete ? manifest[@"metadata"] : @{};
    NSSet *declared = manifest ? [NSSet setWithArray:ok ? manifest[@"files"] : @[]] : nil;
    if (complete && (![directories isKindOfClass:NSArray.class] || ![metadata isKindOfClass:NSDictionary.class])) ok = NO;
    NSMutableDictionary *files = [NSMutableDictionary dictionary]; NSMutableSet *seen = [NSMutableSet set], *actualDirectories = [NSMutableSet set];
    NSUInteger readBytes = json.length;
    if (ok && manifest) for (id file in manifest[@"files"]) if (!BPath(file)) { ok = NO; break; }
    if (ok && manifest && declared.count != [manifest[@"files"] count]) ok = NO;
    if (ok && complete) for (id directory in directories) if (!BFolderForPath(directory)) { ok = NO; break; }
    if (ok && complete && [NSSet setWithArray:directories].count != directories.count) ok = NO;
    for (NSDictionary *entry in entries) {
        if (!ok) break;
        NSString *file = entry[@"file"], *directory = entry[@"directory"];
        if (directory) {
            if (complete && ![directory isEqual:@"config"] && ![directory isEqual:@"sources"]) [actualDirectories addObject:directory];
            continue;
        }
        if ([file isEqual:@"manifest.json"]) continue;
        NSString *mapped = nil;
        if (manifest) {
            if (![declared containsObject:file]) { ok = NO; break; }
            [seen addObject:file]; mapped = file;
        } else if ([file hasPrefix:@"插件配置备份/Library/"]) {
            mapped = [@"config" stringByAppendingPathComponent:[file substringFromIndex:[@"插件配置备份/Library/" length]]];
        } else if ([file hasPrefix:@"源地址备份/"] && file.pathComponents.count == 2) {
            mapped = [@"sources/sources.list.d" stringByAppendingPathComponent:file.lastPathComponent];
        }
        // Old backups remain visible/shareable, but can never replace complete folders.
        if (!mapped || !BFolderForPath(mapped)) { if (complete) ok = NO; continue; }
        if (complete && ![directories containsObject:mapped.stringByDeletingLastPathComponent]) { ok = NO; break; }
        NSData *data = BRead(fd, file, NULL, NULL, error);
        if (!data || files[mapped]) { ok = NO; break; }
        readBytes += data.length;
        if (readBytes > BMaxTotal) { ok = NO; break; }
        files[mapped] = data;
    }
    if (ok && manifest && ![seen isEqual:declared]) ok = NO;
    if (ok && complete) {
        NSSet *dirs = [NSSet setWithArray:directories];
        if (![actualDirectories isEqual:dirs]) ok = NO;
        NSMutableSet *all = [NSMutableSet setWithArray:files.allKeys]; [all unionSet:dirs];
        if (![[NSSet setWithArray:metadata.allKeys] isEqual:all]) ok = NO;
        for (NSString *entry in all) {
            id attrs = metadata[entry];
            if (![attrs isKindOfClass:NSDictionary.class]) { ok = NO; break; }
            for (NSString *key in @[@"mode", @"uid", @"gid", @"seconds", @"nanoseconds"])
                if (![attrs[key] isKindOfClass:NSNumber.class]) ok = NO;
            if (!ok || [attrs[@"mode"] longLongValue] < 0 || [attrs[@"mode"] unsignedLongLongValue] > 0777 ||
                [attrs[@"uid"] longLongValue] < 0 || [attrs[@"uid"] unsignedLongLongValue] > UINT32_MAX ||
                [attrs[@"gid"] longLongValue] < 0 || [attrs[@"gid"] unsignedLongLongValue] > UINT32_MAX ||
                [attrs[@"nanoseconds"] longLongValue] < 0 || [attrs[@"nanoseconds"] longLongValue] >= 1000000000) { ok = NO; break; }
            NSString *folder = BFolderForPath(entry);
            if (![dirs containsObject:folder]) { ok = NO; break; }
        }
    }
    if (ok && !manifest && !files.count) ok = NO;
    close(fd);
    if (!ok) { BFail(error, @"Invalid, incomplete or unsafe backup folder"); return nil; }
    return @{@"version":complete ? @2 : @1, @"files":files, @"directories":[directories sortedArrayUsingSelector:@selector(compare:)], @"metadata":metadata};
}
- (BOOL)restoreBackupAtURL:(NSURL *)backupURL restorePreferences:(BOOL)preferences restoreSources:(BOOL)sources error:(NSError **)error {
    if (!preferences && !sources) return BFail(error, @"Select at least one restore category");
    [BLock lock];
    __block int configFD = -1, aptFD = -1;
    @try {
        __block NSDictionary *archive = nil, *snapshot = nil; __block NSString *root = nil;
        if (![self coordinate:backupURL writing:NO block:^BOOL(NSURL *url, NSError **e) { archive = [self loadArchive:url error:e]; return archive != nil; } error:error]) return NO;
        if (![archive[@"version"] isEqual:@2]) return BFail(error, @"Folder backups require version 2. Create a new complete backup before restoring.");
        NSMutableArray *folders = [NSMutableArray array];
        for (NSString *folder in BBackupFolders())
            if ([archive[@"directories"] containsObject:folder] && ([folder hasPrefix:@"config/"] ? preferences : sources)) [folders addObject:folder];
        if (!folders.count) return BFail(error, @"The backup contains no selected folders");
        if (![self protected:^BOOL(NSError **e) { root = [self runtimeRoot:e]; if (root) snapshot = [self snapshot:root error:e]; return snapshot != nil; } error:error]) return NO;
        // Publish the safety backup before making any change to the live directories.
        __block NSURL *safety = nil;
        if (![self coordinate:backupURL.URLByDeletingLastPathComponent writing:YES block:^BOOL(NSURL *url, NSError **e) { safety = [self writeSnapshot:snapshot directory:url safety:YES error:e]; return safety != nil; } error:error]) return NO;
        return [self protected:^BOOL(NSError **e) {
            if (![[self runtimeRoot:e] isEqual:root]) return BFail(e, @"Jailbreak root changed during restore");
            configFD = BOpenDirectory([self anchor:@"config" root:root error:e]);
            aptFD = BOpenDirectory([self anchor:@"sources" root:root error:e]);
            if (configFD < 0 || aptFD < 0) return BFail(e, @"Cannot pin restore parents");
            NSMutableArray<NSMutableDictionary *> *journal = [NSMutableArray array]; BOOL ok = YES;
            @try {
                for (NSString *folder in folders) {
                    int base = [folder hasPrefix:@"config/"] ? configFD : aptFD;
                    NSString *stage = [@".restore-" stringByAppendingString:NSUUID.UUID.UUIDString];
                    NSString *old = [stage stringByAppendingString:@".old"];
                    struct stat st = {0}, occupied;
                    BOOL exists = fstatat(base, folder.lastPathComponent.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) == 0;
                    if ((!exists && errno != ENOENT) || (exists && !S_ISDIR(st.st_mode)) ||
                        fstatat(base, old.fileSystemRepresentation, &occupied, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT ||
                        mkdirat(base, stage.fileSystemRepresentation, 0700)) { ok = BFail(e, @"Cannot stage a folder replacement"); break; }
                    NSMutableDictionary *entry = [@{@"base":@(base), @"name":folder.lastPathComponent, @"stage":stage, @"old":old,
                        @"original":@(exists), @"moved":@NO, @"installed":@NO, @"inode":@(st.st_ino), @"device":@(st.st_dev)} mutableCopy];
                    [journal addObject:entry];
                    int stageFD = openat(base, stage.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
                    if (stageFD < 0) { ok = BFail(e, @"Cannot open staged folder"); break; }
                    @try {
                        for (NSString *directory in archive[@"directories"]) {
                            if (!BUnder(directory, folder) || [directory isEqual:folder]) continue;
                            NSString *relative = [directory substringFromIndex:folder.length + 1];
                            int fd = BParent(stageFD, [relative stringByAppendingPathComponent:@".entry"], YES, getuid(), getgid(), nil);
                            if (fd < 0) { ok = BFail(e, @"Cannot stage backup subdirectory"); break; }
                            close(fd);
                        }
                        NSDictionary *files = archive[@"files"];
                        for (NSString *path in files) {
                            if (!ok) break;
                            if (!BUnder(path, folder)) continue;
                            ok = BWrite(stageFD, [path substringFromIndex:folder.length + 1], files[path], BStat(archive[@"metadata"][path]), -1, nil, e);
                        }
                        for (NSString *directory in [archive[@"directories"] reverseObjectEnumerator]) {
                            if (!ok) break;
                            if (!BUnder(directory, folder)) continue;
                            NSString *relative = [directory isEqual:folder] ? nil : [directory substringFromIndex:folder.length + 1];
                            int fd = relative ? BParent(stageFD, [relative stringByAppendingPathComponent:@".entry"], NO, 0, 0, nil) : dup(stageFD);
                            struct stat mode = BStat(archive[@"metadata"][directory]);
                            struct timespec times[2] = {mode.st_atimespec, mode.st_mtimespec};
                            ok = fd >= 0 && !fchown(fd, mode.st_uid, mode.st_gid) && !fchmod(fd, mode.st_mode) && !futimens(fd, times) && !fsync(fd);
                            if (fd >= 0) close(fd);
                            if (!ok) BFail(e, @"Cannot restore directory permissions");
                        }
                    } @finally { close(stageFD); }
                    if (!ok) break;
                }
                // Re-read after staging: a changing daemon must not lose newer configuration.
                if (ok) {
                    NSDictionary *now = [self snapshot:root error:e];
                    if (!now || ![now isEqual:snapshot]) ok = BFail(e, @"Destination changed after safety backup; no restore applied");
                }
                NSUInteger swapped = 0;
                for (NSMutableDictionary *entry in journal) {
                    if (!ok) break;
#ifdef DO_BACKUP_TESTING
                    if (self.failAfterWrites >= 0 && swapped >= (NSUInteger)self.failAfterWrites) { ok = BFail(e, @"Injected folder replacement failure"); break; }
#endif
                    int base = [entry[@"base"] intValue]; struct stat st;
                    BOOL exists = fstatat(base, [entry[@"name"] fileSystemRepresentation], &st, AT_SYMLINK_NOFOLLOW) == 0;
                    if ((!exists && errno != ENOENT) || exists != [entry[@"original"] boolValue] || (exists && (!S_ISDIR(st.st_mode) || st.st_ino != [entry[@"inode"] unsignedLongLongValue] || st.st_dev != [entry[@"device"] unsignedLongLongValue]))) {
                        ok = BFail(e, @"Destination folder changed during replacement"); break;
                    }
                    if (exists) {
                        if (renameat(base, [entry[@"name"] fileSystemRepresentation], base, [entry[@"old"] fileSystemRepresentation])) { ok = BFail(e, @"Cannot retain original folder"); break; }
                        entry[@"moved"] = @YES;
                    }
                    if (renameat(base, [entry[@"stage"] fileSystemRepresentation], base, [entry[@"name"] fileSystemRepresentation])) { ok = BFail(e, @"Cannot publish restored folder"); break; }
                    entry[@"installed"] = @YES; swapped++;
                    if (fsync(base)) { ok = BFail(e, @"Cannot sync restored folder"); break; }
                }
            } @catch (NSException *exception) { ok = BFail(e, @"Folder replacement raised an exception"); }
            BOOL rollbackOK = YES;
            if (!ok) for (NSMutableDictionary *entry in journal.reverseObjectEnumerator) {
                int base = [entry[@"base"] intValue];
                if ([entry[@"installed"] boolValue] && renameat(base, [entry[@"name"] fileSystemRepresentation], base, [entry[@"stage"] fileSystemRepresentation])) { rollbackOK = NO; continue; }
                if ([entry[@"moved"] boolValue] && renameat(base, [entry[@"old"] fileSystemRepresentation], base, [entry[@"name"] fileSystemRepresentation])) rollbackOK = NO;
                if (fsync(base)) rollbackOK = NO;
            }
            // Retain all transaction folders if rollback was incomplete.
            BOOL cleaned = YES;
            if (ok || rollbackOK) for (NSDictionary *entry in journal) {
                int base = [entry[@"base"] intValue];
                if (ok && [entry[@"moved"] boolValue] && !BRemoveVerifiedTree(base, entry[@"old"], NULL)) cleaned = NO;
                if (!ok && !BRemoveVerifiedTree(base, entry[@"stage"], NULL)) cleaned = NO;
            }
            if (!rollbackOK) return BFail(e, [NSString stringWithFormat:@"Rollback incomplete; originals retained in .restore folders. Safety backup: %@", safety.lastPathComponent]);
            if (!cleaned) return BFail(e, ok ? @"Folders restored, but old .restore folders could not be removed." : @"Original folders restored; temporary .restore folders could not be removed.");
            return ok;
        } error:error];
    } @finally { if (configFD >= 0) close(configFD); if (aptFD >= 0) close(aptFD); [BLock unlock]; }
}

- (NSArray<NSURL *> *)backupsInDirectory:(NSURL *)directory error:(NSError **)error {
    NSArray<NSDictionary<NSString *, id> *> *rows = [self backupSummariesInDirectory:directory error:error];
    return [rows valueForKey:@"url"] ?: @[];
}
// Only a folder carrying our own manifest counts as an archive. The returned
// value is the manifest creation epoch (folder mtime only if that key is absent).
- (NSNumber *)archiveCreatedNamed:(NSString *)name base:(int)base {
    int fd = openat(base, name.fileSystemRepresentation, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return nil;
    BOOL absent = NO;
    NSData *data = BRead(fd, @"manifest.json", NULL, &absent, NULL);
    close(fd);
    struct stat st = {0};
    BOOL statted = fstatat(base, name.fileSystemRepresentation, &st, AT_SYMLINK_NOFOLLOW) == 0;
    if (!data) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![object isKindOfClass:NSDictionary.class] || ![object[@"format"] isEqual:@"org.roothide.configuration-backup"] ||
        (![object[@"version"] isEqual:@1] && ![object[@"version"] isEqual:@2]) || ![object[@"files"] isKindOfClass:NSArray.class]) return nil;
    NSNumber *created = [object[@"created"] isKindOfClass:NSNumber.class] ? object[@"created"] : nil;
    if (!created && statted) created = @((double)st.st_mtimespec.tv_sec + (double)st.st_mtimespec.tv_nsec / 1e9);
    return created ?: @0;
}
- (BOOL)archiveIsOurs:(NSString *)name base:(int)base {
    return [self archiveCreatedNamed:name base:base] != nil;
}
- (NSDictionary<NSString *, id> *)summaryForBackupAtURL:(NSURL *)url error:(NSError **)error {
    [BLock lock]; @try {
        if (!url.isFileURL) { BFail(error, @"Backup must be a local folder"); return nil; }
        NSDictionary *archive = [self loadArchive:url error:error];
        if (!archive) return nil;
        NSUInteger size = 0;
        NSDictionary *files = archive[@"files"];
        for (NSData *data in files.allValues) size += data.length;
        // Only regular files are counted; walk rejects links and special files.
        NSMutableArray *entries = [NSMutableArray array]; NSUInteger walked = 0;
        if (![self walk:BCanonical(url.path) prefix:@"" files:entries bytes:&walked error:error]) return nil;
        NSUInteger regular = 0;
        for (NSDictionary *entry in entries) if (entry[@"file"]) regular++;
        NSDictionary *manifest = nil;
        int fd = BOpenDirectory(BCanonical(url.path));
        if (fd >= 0) {
            BOOL absent = NO;
            NSData *data = BRead(fd, @"manifest.json", NULL, &absent, NULL);
            close(fd);
            if (data) {
                id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                if ([object isKindOfClass:NSDictionary.class]) manifest = object;
            }
        }
        NSDate *created = nil;
        if ([manifest[@"created"] isKindOfClass:NSNumber.class]) created = [NSDate dateWithTimeIntervalSince1970:[manifest[@"created"] doubleValue]];
        if (!created) created = [[NSFileManager defaultManager] attributesOfItemAtPath:url.path error:nil][NSFileModificationDate];
        NSNumber *reported = [manifest[@"report"] isKindOfClass:NSDictionary.class] ? manifest[@"report"][@"skippedCount"] : nil;
        NSUInteger skipped = [reported isKindOfClass:NSNumber.class] ? reported.unsignedIntegerValue : (regular > files.count ? regular - files.count : 0);
        return @{@"url":url, @"files":@(files.count), @"size":@(size), @"created":created ?: [NSDate dateWithTimeIntervalSince1970:0],
                 @"skipped":@(skipped), @"safety":@([url.lastPathComponent hasPrefix:@"恢复前备份_"] || [url.lastPathComponent hasPrefix:@"SafetyBackup-"]), @"legacy":@(manifest == nil)};
    } @finally { [BLock unlock]; }
}
- (NSArray<NSDictionary<NSString *, id> *> *)backupSummariesInDirectory:(NSURL *)directory error:(NSError **)error {
    [BLock lock]; @try {
        __block NSMutableArray *results = [NSMutableArray array];
        BOOL ok = [self coordinate:directory writing:NO block:^BOOL(NSURL *actual, NSError **e) {
            if (![self validateStorageDirectory:actual error:e]) return NO;
            NSArray *children = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:actual includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:e];
            if (!children) return NO;
            for (NSURL *child in children) {
                if (results.count >= BMaxFiles) return BFail(e, @"Too many backups in selected folder");
                struct stat st;
                if (lstat(child.path.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode)) continue;
                NSError *archiveError = nil;
                NSDictionary *summary = [self summaryForBackupAtURL:child error:&archiveError];
                if (summary) [results addObject:summary];
#ifdef DO_BACKUP_TESTING
                else NSLog(@"Skipped backup %@: %@", child, archiveError);
#endif
            }
            [results sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
                return [((NSURL *)a[@"url"]).lastPathComponent compare:((NSURL *)b[@"url"]).lastPathComponent options:NSNumericSearch];
            }];
            return YES;
        } error:error];
        return ok ? results : @[];
    } @finally { [BLock unlock]; }
}
- (NSDictionary<NSString *, id> *)retentionPlanUncoordinated:(NSURL *)directory error:(NSError **)error {
    if (![self validateStorageDirectory:directory error:error]) return nil;
    int base = BOpenDirectory(BCanonical(directory.path));
    if (base < 0) { BFail(error, @"Storage folder became unavailable"); return nil; }
    int listFD = dup(base);
    DIR *stream = listFD >= 0 ? fdopendir(listFD) : NULL;
    if (!stream) { if (listFD >= 0) close(listFD); close(base); BFail(error, @"Cannot enumerate the storage folder"); return nil; }
    NSMutableArray *manual = [NSMutableArray array], *safety = [NSMutableArray array];
    BOOL ok = YES; struct dirent *entry;
    while ((entry = readdir(stream))) {
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if (!name || [name isEqual:@"."] || [name isEqual:@".."]) continue;
        BOOL isSafety = NO;
        if (!BGeneratedName(name, &isSafety) && !BLegacyName(name, &isSafety)) continue;
        struct stat st;
        if (fstatat(base, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { ok = BFail(error, @"Cannot inspect a backup folder"); break; }
        // Symlinks, files and folders that are not ours are never candidates.
        if (!S_ISDIR(st.st_mode)) continue;
        NSNumber *created = [self archiveCreatedNamed:name base:base];
        if (!created) continue;
        [(isSafety ? safety : manual) addObject:@{@"name":name, @"created":created}];
    }
    struct stat marker = {0};
    BOOL marked = fstatat(base, BRetentionMarker.fileSystemRepresentation, &marker, AT_SYMLINK_NOFOLLOW) == 0 && S_ISREG(marker.st_mode);
    closedir(stream); close(base);
    if (!ok) return nil;
    // Legacy names carry no time, so the manifest decides; the name is only a tiebreak.
    NSComparator newestFirst = ^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSComparisonResult byTime = [b[@"created"] compare:a[@"created"]];
        if (byTime != NSOrderedSame) return byTime;
        return [b[@"name"] compare:a[@"name"] options:NSNumericSearch];
    };
    [manual sortUsingComparator:newestFirst]; [safety sortUsingComparator:newestFirst];
    NSUInteger manualDrop = manual.count > BRetentionManualKeep ? manual.count - BRetentionManualKeep : 0;
    NSUInteger safetyDrop = safety.count > BRetentionSafetyKeep ? safety.count - BRetentionSafetyKeep : 0;
    NSMutableArray *candidates = [NSMutableArray array], *kept = [NSMutableArray array];
    for (NSUInteger i = 0; i < manual.count; i++) [(i < manual.count - manualDrop ? kept : candidates) addObject:manual[i][@"name"]];
    for (NSUInteger i = 0; i < safety.count; i++) [(i < safety.count - safetyDrop ? kept : candidates) addObject:safety[i][@"name"]];
    NSMutableArray *urls = [NSMutableArray array];
    for (NSString *name in candidates) [urls addObject:[directory URLByAppendingPathComponent:name isDirectory:YES]];
    return @{@"candidates":urls, @"count":@(urls.count), @"kept":@(kept.count), @"manualKept":@(manual.count - manualDrop),
             @"safetyKept":@(safety.count - safetyDrop), @"needsConfirmation":@(urls.count > 0 && !marked), @"marked":@(marked)};
}
- (NSArray<NSURL *> *)retentionApplyUncoordinated:(NSURL *)directory confirmed:(BOOL)confirmed error:(NSError **)error {
    NSDictionary *plan = [self retentionPlanUncoordinated:directory error:error];
    if (!plan) return nil;
    if ([plan[@"needsConfirmation"] boolValue] && !confirmed) { BFail(error, @"The first old backup cleanup needs one confirmation"); return nil; }
    NSArray<NSURL *> *targets = plan[@"candidates"];
    int base = BOpenDirectory(BCanonical(directory.path));
    if (base < 0) { BFail(error, @"Storage folder became unavailable"); return nil; }
    BOOL ok = YES;
    // Verify every target before the first deletion so nothing is removed half way.
    for (NSURL *url in targets) {
        BOOL isSafety = NO; NSMutableArray *entries = [NSMutableArray array]; NSUInteger bytes = 0;
        // Resolve only the fixed system aliases (/var -> /private/var); no archive path is followed.
        if (!(BGeneratedName(url.lastPathComponent, &isSafety) || BLegacyName(url.lastPathComponent, &isSafety)) || ![self archiveIsOurs:url.lastPathComponent base:base] ||
            ![self walk:BCanonical(url.path) prefix:@"" files:entries bytes:&bytes error:error]) {
            if (error && !*error) BFail(error, @"A backup folder is not safe to delete");
            ok = NO; break;
        }
    }
    NSMutableArray *deleted = [NSMutableArray array];
    for (NSURL *url in targets) {
        if (!ok) break;
        if (!BRemoveVerifiedTree(base, url.lastPathComponent, error)) { ok = NO; break; }
        fsync(base);
        [deleted addObject:url];
    }
    if (ok && ![plan[@"marked"] boolValue]) ok = BWriteRetentionMarker(base, error);
    close(base);
    return ok ? deleted : nil;
}
- (NSDictionary<NSString *, id> *)retentionPlanInDirectory:(NSURL *)directory error:(NSError **)error {
    [BLock lock]; @try {
        __block NSDictionary *plan = nil;
        [self coordinate:directory writing:NO block:^BOOL(NSURL *actual, NSError **e) {
            plan = [self retentionPlanUncoordinated:actual error:e];
            return plan != nil;
        } error:error];
        return plan;
    } @finally { [BLock unlock]; }
}
- (NSArray<NSURL *> *)applyRetentionInDirectory:(NSURL *)directory confirmed:(BOOL)confirmed error:(NSError **)error {
    [BLock lock]; @try {
        __block NSArray *deleted = nil;
        [self coordinate:directory writing:YES block:^BOOL(NSURL *actual, NSError **e) {
            deleted = [self retentionApplyUncoordinated:actual confirmed:confirmed error:e];
            return deleted != nil;
        } error:error];
        return deleted;
    } @finally { [BLock unlock]; }
}
@end
