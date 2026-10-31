#import "DOConfigurationBackupManager.h"
#import "DOSourceMigration.h"
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
static BOOL BPreferenceName(NSString *name) {
    if (!BPath(name) || name.pathComponents.count != 1 || ![name.pathExtension isEqual:@"plist"] || [name hasPrefix:@"."]) return NO;
    NSString *lower = name.lowercaseString;
    for (NSString *prefix in @[@"com.apple.", @"cn.zqbb.doparh", @"apple", @"global", @"system", @"com.opa334.dopamine", @"com.roothide.dopamine", @"cn.roothide.dopamine", @"com.xina."])
        if ([lower hasPrefix:prefix]) return NO;
    for (NSString *word in @[@"keychain", @"credential", @"password", @"token", @"device", @"activation", @"networkidentification", @"bluetooth", @"wifi", @"mobilegestalt"])
        if ([lower containsString:word]) return NO;
    return YES;
}
static NSArray<NSString *> *BRootHideNames(void) {
    // Never include cn.zqbb.inject.system.plist or arbitrary RootHide databases.
    return @[@"RootHideConfig.plist", @"cn.zqbb.inject.plist", @"cn.zqbb.inject.wantsblacklist.plist", @"cn.zqbb.jetsam.addend.plist"];
}
static BOOL BSecret(id object) {
    if ([object isKindOfClass:NSDictionary.class]) {
        for (id key in object) {
            if (![key isKindOfClass:NSString.class]) return YES;
            NSString *s = [key lowercaseString];
            for (NSString *word in @[@"token", @"password", @"secret", @"credential", @"apikey", @"api_key", @"privatekey", @"authorization", @"cookie", @"deviceid", @"udid", @"serialnumber"])
                if ([s containsString:word]) return YES;
            if (BSecret(object[key])) return YES;
        }
    } else if ([object isKindOfClass:NSArray.class]) { for (id value in object) if (BSecret(value)) return YES; }
    return NO;
}
static NSArray<NSString *> *BAdditionalConfigPaths(void) {
    return @[@"ControlCenter/ModuleConfiguration_CCSupport.plist", @"CallAssistActivation/Activation.plist", @"Snapper3/license"];
}
static BOOL BConfigPath(NSString *path) {
    if (!BPath(path)) return NO;
    NSArray *parts = path.pathComponents;
    return [BAdditionalConfigPaths() containsObject:path] || (parts.count == 2 && (([parts[0] isEqual:@"Preferences"] && BPreferenceName(parts[1])) || ([parts[0] isEqual:@"RootHide"] && [BRootHideNames() containsObject:parts[1]])));
}
static BOOL BConfig(NSString *path, NSData *data, NSError **error) {
    if (!BConfigPath(path)) return BFail(error, @"Configuration is not on the explicit allowlist");
    // Only these exact, user-authorized license paths may carry device/authorization data.
    if ([path isEqual:@"Snapper3/license"])
        return (data.length > 0 && data.length <= 64 * 1024) || BFail(error, @"Snapper3 license must contain 1 to 65536 bytes");
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    BOOL authorized = [path isEqual:@"CallAssistActivation/Activation.plist"];
    return ([plist isKindOfClass:NSDictionary.class] && (authorized || !BSecret(plist))) || BFail(error, @"Configuration must be a dictionary plist without credential/device keys except the explicitly authorized activation file");
}
static NSArray<NSString *> *BSourceUnits(NSString *text, BOOL deb822) {
    NSMutableArray *units = [NSMutableArray array];
    if (deb822) {
        NSMutableArray *block = [NSMutableArray array];
        for (NSString *line in [[text stringByAppendingString:@"\n"] componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (!trim.length) { if (block.count) { [units addObject:[block componentsJoinedByString:@"\n"]]; [block removeAllObjects]; } }
            else if (![trim hasPrefix:@"#"]) [block addObject:line];
        }
    } else {
        for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *trim = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (trim.length && ![trim hasPrefix:@"#"]) [units addObject:trim];
        }
    }
    return units;
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
        if (!name || !BPath(relative) || relative.pathComponents.count > 8 || fstatat(fd, entry->d_name, &st, AT_SYMLINK_NOFOLLOW)) { ok = BFail(error, @"Invalid archive path"); break; }
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
- (NSArray<NSString *> *)namesAt:(int)base directory:(NSString *)relative error:(NSError **)error {
    int fd = BParent(base, [relative stringByAppendingPathComponent:@".entry"], NO, 0, 0, nil);
    if (fd < 0) { if (errno == ENOENT) return @[]; BFail(error, @"Unsafe configuration directory"); return nil; }
    DIR *stream = fdopendir(fd);
    if (!stream) { close(fd); BFail(error, @"Cannot enumerate configuration directory"); return nil; }
    NSMutableArray *names = [NSMutableArray array]; struct dirent *entry; BOOL ok = YES;
    while ((entry = readdir(stream))) {
        NSString *name = [NSString stringWithUTF8String:entry->d_name];
        if ([name isEqual:@"."] || [name isEqual:@".."]) continue;
        if (!name || !BPath(name) || names.count >= BMaxFiles) { ok = BFail(error, @"Configuration directory entry limit or invalid filename"); break; }
        [names addObject:name];
    }
    closedir(stream);
    return ok ? [names sortedArrayUsingSelector:@selector(compare:)] : nil;
}
- (NSDictionary<NSString *, NSData *> *)snapshot:(NSString *)root error:(NSError **)error {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    NSString *library = [self anchor:@"config" root:root error:error], *apt = [self anchor:@"sources" root:root error:error];
    if (!library || !apt) return nil;
    int lfd = BOpenDirectory(library), afd = BOpenDirectory(apt);
    if (lfd < 0 || afd < 0) { if (lfd >= 0) close(lfd); if (afd >= 0) close(afd); BFail(error, @"Cannot open runtime anchors"); return nil; }
    NSArray *preferences = [self namesAt:lfd directory:@"Preferences" error:error];
    NSArray *rootHide = [self namesAt:lfd directory:@"RootHide" error:error];
    BOOL ok = preferences != nil && rootHide != nil;
    NSMutableArray *skipped = [NSMutableArray array];
    NSMutableArray *configPaths = [NSMutableArray arrayWithArray:BAdditionalConfigPaths()];
    for (NSString *name in preferences) {
        NSString *path = [@"Preferences" stringByAppendingPathComponent:name];
        if (BPreferenceName(name)) [configPaths addObject:path];
        else [skipped addObject:@{@"path":path, @"reason":@"excluded-system-control-credential-or-unsupported-name"}];
    }
    for (NSString *name in BRootHideNames()) [configPaths addObject:[@"RootHide" stringByAppendingPathComponent:name]];
    for (NSString *path in configPaths) {
        if (!ok) break;
        BOOL missing; NSError *readError = nil;
        NSData *data = BRead(lfd, path, NULL, &missing, &readError);
        if (missing) continue;
        NSError *configError = nil;
        if (!data || !BConfig(path, data, &configError)) {
            [skipped addObject:@{@"path":path, @"reason":data ? @"invalid-format-size-or-sensitive-content" : @"unsafe-link-unreadable-special-or-oversized"}]; continue;
        }
        result[[@"config" stringByAppendingPathComponent:path]] = data;
    }
    NSMutableArray *sourcePaths = [NSMutableArray arrayWithObject:@"sources.list"];
    NSString *listDir = [apt stringByAppendingPathComponent:@"sources.list.d"];
    struct stat listStat;
    if (ok && !lstat(listDir.fileSystemRepresentation, &listStat)) {
        NSMutableArray *entries = [NSMutableArray array]; NSUInteger bytes = 0;
        ok = [self walk:listDir prefix:@"sources.list.d" files:entries bytes:&bytes error:error];
        for (NSDictionary *entry in entries) if (entry[@"file"] && [entry[@"file"] pathComponents].count == 2) [sourcePaths addObject:entry[@"file"]];
    }
    for (NSString *path in sourcePaths) {
        if (!ok) break;
        NSString *ext = path.pathExtension;
        if (![ext isEqual:@"list"] && ![ext isEqual:@"sources"]) continue;
        BOOL missing; NSData *data = BRead(afd, path, NULL, &missing, error);
        if (!data && !missing) { ok = NO; break; }
        if (!data) continue;
        NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *clean = text ? [DOSourceMigration sanitizedSourceText:text deb822:[ext isEqual:@"sources"] error:error] : nil;
        if (!clean) { ok = BFail(error, @"Invalid UTF-8/APT source text"); break; }
        result[[@"sources" stringByAppendingPathComponent:path]] = [clean dataUsingEncoding:NSUTF8StringEncoding];
    }
    close(lfd); close(afd);
    NSUInteger total = 0; for (NSData *data in result.allValues) total += data.length;
    if (result.count > BMaxFiles || total > BMaxTotal) { BFail(error, @"Snapshot exceeds backup limits"); return nil; }
    for (NSString *name in rootHide) if (![BRootHideNames() containsObject:name])
        [skipped addObject:@{@"path":[@"RootHide" stringByAppendingPathComponent:name], @"reason":@"generated-or-unsupported-roothide-data"}];
    self.lastBackupReport = @{@"included":@(result.count), @"skippedCount":@(skipped.count), @"skipped":skipped};
    return ok ? result : nil;
}
- (NSURL *)writeSnapshot:(NSDictionary<NSString *, NSData *> *)snapshot directory:(NSURL *)directory safety:(BOOL)safety error:(NSError **)error {
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
    NSArray *paths = [snapshot.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *path in paths) if (ok) ok = BWrite(fd, path, snapshot[path], mode, -1, created, error);
    NSDictionary *manifest = @{@"format":@"org.roothide.configuration-backup", @"version":@1, @"files":paths,
                              @"created":@([[NSDate date] timeIntervalSince1970]), @"safety":@(safety), @"report":self.lastBackupReport ?: @{}};
    NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted error:error];
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
        __block NSURL *result = nil;
        [self coordinate:directory writing:YES block:^BOOL(NSURL *actual, NSError **e) { result = [self writeSnapshot:snapshot directory:actual safety:NO error:e]; return result != nil; } error:error];
        return result;
    } @finally { [BLock unlock]; }
}
- (NSDictionary<NSString *, NSData *> *)loadArchive:(NSURL *)url error:(NSError **)error {
    if (![self validateStorageDirectory:url.URLByDeletingLastPathComponent error:error]) return nil;
    NSString *path = url.path;
    if (!url.isFileURL || ![BCanonical(path) isEqual:[BCanonical(url.URLByDeletingLastPathComponent.path) stringByAppendingPathComponent:url.lastPathComponent]]) { BFail(error, @"Archive folder symlink rejected"); return nil; }
    NSMutableArray *entries = [NSMutableArray array]; NSUInteger bytes = 0;
    if (![self walk:BCanonical(path) prefix:@"" files:entries bytes:&bytes error:error]) return nil;
    int fd = BOpenDirectory(BCanonical(path)); if (fd < 0) return nil;
    BOOL absent; NSData *manifestData = BRead(fd, @"manifest.json", NULL, &absent, error);
    NSDictionary *manifest = nil; NSSet *declared = nil;
    BOOL ok = absent || manifestData != nil;
    if (manifestData) {
        id object = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:error];
        if (![object isKindOfClass:NSDictionary.class] || ![object[@"format"] isEqual:@"org.roothide.configuration-backup"] || ![object[@"version"] isEqual:@1] || ![object[@"files"] isKindOfClass:NSArray.class]) ok = BFail(error, @"Unsupported backup manifest");
        else {
            manifest = object;
            for (id file in manifest[@"files"]) if (!BPath(file)) { ok = BFail(error, @"Invalid manifest filename"); break; }
            if (ok) { declared = [NSSet setWithArray:manifest[@"files"]]; if (declared.count != [manifest[@"files"] count]) ok = BFail(error, @"Duplicate manifest paths"); }
        }
    }
    NSMutableDictionary *result = [NSMutableDictionary dictionary]; NSMutableSet *seen = [NSMutableSet set];
    for (NSDictionary *entry in entries) {
        if (!ok) break;
        NSString *file = entry[@"file"]; if (!file || [file isEqual:@"manifest.json"]) continue;
        NSString *mapped = nil;
        if (manifest) {
            if (![declared containsObject:file]) { ok = BFail(error, @"Unlisted archive file"); break; }
            [seen addObject:file]; mapped = file;
        } else if ([file hasPrefix:@"插件配置备份/Library/"]) {
            NSString *config = [file substringFromIndex:[@"插件配置备份/Library/" length]];
            if (BConfigPath(config)) mapped = [@"config" stringByAppendingPathComponent:config];
            // Legacy scripts copied whole Library: unallowlisted data is never restored.
        } else if ([file hasPrefix:@"源地址备份/"] && ( [file.pathExtension isEqual:@"list"] || [file.pathExtension isEqual:@"sources"])) {
            mapped = [@"sources/sources.list.d" stringByAppendingPathComponent:file.lastPathComponent];
        } else if (manifest) { ok = NO; }
        if (!mapped) continue;
        NSData *data = BRead(fd, file, NULL, NULL, error); if (!data) { ok = NO; break; }
        if ([mapped hasPrefix:@"config/"]) ok = BConfig([mapped substringFromIndex:7], data, error);
        else if ([mapped hasPrefix:@"sources/"]) {
            NSString *relative = [mapped substringFromIndex:8]; NSArray *parts = relative.pathComponents;
            BOOL valid = [relative isEqual:@"sources.list"] || (parts.count == 2 && [parts[0] isEqual:@"sources.list.d"] && ([relative.pathExtension isEqual:@"list"] || [relative.pathExtension isEqual:@"sources"]));
            NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSString *clean = valid && text ? [DOSourceMigration sanitizedSourceText:text deb822:[relative.pathExtension isEqual:@"sources"] error:error] : nil;
            ok = clean != nil; if (ok) data = [clean dataUsingEncoding:NSUTF8StringEncoding]; else BFail(error, @"Invalid source entry");
        } else ok = BFail(error, @"Unexpected archive destination");
        if (ok && result[mapped]) ok = BFail(error, @"Duplicate legacy archive destination");
        if (ok) result[mapped] = data;
    }
    if (ok && manifest && ![seen isEqual:declared]) ok = BFail(error, @"Manifest references missing files");
    if (ok && !manifest && !result.count) ok = BFail(error, @"Unrecognized or empty legacy backup");
    close(fd); return ok ? result : nil;
}
- (NSString *)sourceKey:(NSString *)unit deb822:(BOOL)deb822 {
    NSMutableDictionary *fields = [NSMutableDictionary dictionary];
    NSString *(^words)(NSString *) = ^NSString *(NSString *value) {
        return [[[value componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    };
    if (deb822) {
        NSString *last = nil;
        for (NSString *line in [unit componentsSeparatedByString:@"\n"]) {
            if ([line hasPrefix:@" "] || [line hasPrefix:@"\t"]) { if (last) fields[last] = words([fields[last] stringByAppendingFormat:@" %@", line]); continue; }
            NSRange colon = [line rangeOfString:@":"];
            if (colon.location == NSNotFound) continue;
            last = [[line substringToIndex:colon.location] lowercaseString];
            fields[last] = words([line substringFromIndex:colon.location + 1]);
        }
    } else {
        NSString *normalized = words(unit);
        NSArray *parts = [normalized componentsSeparatedByString:@" "];
        if (parts.count < 3 || [parts[1] hasPrefix:@"["]) return [@"list:" stringByAppendingString:normalized];
        fields[@"types"] = parts[0]; fields[@"uris"] = parts[1]; fields[@"suites"] = parts[2];
        if (parts.count > 3) fields[@"components"] = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)] componentsJoinedByString:@" "];
    }
    BOOL simple = fields.count <= 4 && fields[@"types"] && fields[@"uris"] && fields[@"suites"];
    for (NSString *key in fields) if (![@[@"types", @"uris", @"suites", @"components"] containsObject:key]) simple = NO;
    for (NSString *key in @[@"types", @"uris", @"suites"]) if ([fields[key] containsString:@" "]) simple = NO;
    if (simple) {
        NSArray *components = [fields[@"components"] ?: @"" componentsSeparatedByString:@" "];
        return [NSString stringWithFormat:@"repo:%@|%@|%@|%@", fields[@"types"], fields[@"uris"], fields[@"suites"], [[components sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]];
    }
    NSMutableArray *canonical = [NSMutableArray array];
    for (NSString *key in [fields.allKeys sortedArrayUsingSelector:@selector(compare:)]) [canonical addObject:[NSString stringWithFormat:@"%@:%@", key, fields[key]]];
    return [@"deb822:" stringByAppendingString:[canonical componentsJoinedByString:@"\n"]];
}
- (NSDictionary *)restorePlan:(NSDictionary *)archive snapshot:(NSDictionary *)snapshot preferences:(BOOL)preferences sources:(BOOL)sources error:(NSError **)error {
    NSMutableDictionary *plan = [NSMutableDictionary dictionary];
    if (preferences) for (NSString *path in archive) if ([path hasPrefix:@"config/"]) plan[path] = archive[path];
    if (!sources) return plan;
    NSMutableSet *existing = [NSMutableSet set];
    for (NSString *path in snapshot) {
        if (![path hasPrefix:@"sources/"]) continue;
        BOOL deb822 = [path.pathExtension isEqual:@"sources"];
        NSString *text = [[NSString alloc] initWithData:snapshot[path] encoding:NSUTF8StringEncoding];
        for (NSString *unit in BSourceUnits(text, deb822)) [existing addObject:[self sourceKey:unit deb822:deb822]];
    }
    for (NSString *ext in @[@"list", @"sources"]) {
        NSMutableArray *additions = [NSMutableArray array];
        for (NSString *path in [archive.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if (![path hasPrefix:@"sources/"] || ![path.pathExtension isEqual:ext]) continue;
            NSString *text = [[NSString alloc] initWithData:archive[path] encoding:NSUTF8StringEncoding];
            for (NSString *unit in BSourceUnits(text, [ext isEqual:@"sources"])) {
                NSString *key = [self sourceKey:unit deb822:[ext isEqual:@"sources"]];
                if (![existing containsObject:key]) { [existing addObject:key]; [additions addObject:unit]; }
            }
        }
        if (additions.count) {
            NSString *filename = [NSString stringWithFormat:@"sources/sources.list.d/imported-%@.%@", NSUUID.UUID.UUIDString, ext];
            NSString *text = [[additions componentsJoinedByString:[ext isEqual:@"sources"] ? @"\n\n" : @"\n"] stringByAppendingString:@"\n"];
            NSData *data = [text dataUsingEncoding:NSUTF8StringEncoding];
            if (data.length > (off_t)BMaxFile) { BFail(error, @"Merged imported sources exceed file limit"); return nil; }
            plan[filename] = data;
        }
    }
    return plan;
}
- (BOOL)restoreBackupAtURL:(NSURL *)backupURL restorePreferences:(BOOL)preferences restoreSources:(BOOL)sources error:(NSError **)error {
    if (!preferences && !sources) return BFail(error, @"Select at least one restore category");
    [BLock lock];
    NSMutableArray *journal = [NSMutableArray array];
    __block int configFD = -1, aptFD = -1;
    @try {
        __block NSDictionary *archive = nil;
        if (![self coordinate:backupURL writing:NO block:^BOOL(NSURL *actual, NSError **e) { archive = [self loadArchive:actual error:e]; return archive != nil; } error:error]) return NO;
        __block NSDictionary *snapshot = nil, *plan = nil;
        __block NSString *root = nil;
        BOOL prepared = [self protected:^BOOL(NSError **e) {
            root = [self runtimeRoot:e]; if (!root) return NO;
            snapshot = [self snapshot:root error:e]; if (!snapshot) return NO;
            plan = [self restorePlan:archive snapshot:snapshot preferences:preferences sources:sources error:e]; if (!plan) return NO;
            NSString *library = [self anchor:@"config" root:root error:e], *apt = [self anchor:@"sources" root:root error:e];
            configFD = BOpenDirectory(library); aptFD = BOpenDirectory(apt);
            if (configFD < 0 || aptFD < 0) return BFail(e, @"Cannot pin restore directories");
            for (NSString *path in [plan.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
                BOOL config = [path hasPrefix:@"config/"]; NSString *relative = [path substringFromIndex:config ? 7 : 8];
                int fd = config ? configFD : aptFD; BOOL missing; struct stat st = {0};
                NSData *old = BRead(fd, relative, &st, &missing, e);
                if (!old && !missing) return NO;
                // Never overwrite a secret-bearing existing plist that cannot enter the safety backup.
                if (old && config && !BConfig(relative, old, e)) return NO;
                int originalFD = -1;
                if (old) {
                    int parent = BParent(fd, relative, NO, 0, 0, nil);
                    if (parent >= 0) { originalFD = openat(parent, relative.lastPathComponent.fileSystemRepresentation, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); close(parent); }
                    struct stat pinned;
                    if (originalFD < 0 || fstat(originalFD, &pinned) || pinned.st_ino != st.st_ino || pinned.st_dev != st.st_dev || pinned.st_nlink != 1) { if (originalFD >= 0) close(originalFD); return BFail(e, @"Destination changed during preflight"); }
                } else { st.st_mode = 0644; st.st_uid = config ? 501 : 0; st.st_gid = config ? 501 : 0;
#ifdef DO_BACKUP_TESTING
                    st.st_uid = getuid(); st.st_gid = getgid();
#endif
                }
                [journal addObject:@{@"path":path, @"relative":relative, @"base":@(fd), @"old":old ?: (id)NSNull.null, @"stat":[NSData dataWithBytes:&st length:sizeof(st)], @"originalFD":@(originalFD)}];
            }
            return YES;
        } error:error];
        if (!prepared) return NO;
        if (!plan.count) return YES;
        // Export before overwriting, outside root scope and outside the jailbreak tree.
        __block NSURL *safety = nil;
        NSURL *parent = backupURL.URLByDeletingLastPathComponent;
        if (![self coordinate:parent writing:YES block:^BOOL(NSURL *actual, NSError **e) { safety = [self writeSnapshot:snapshot directory:actual safety:YES error:e]; return safety != nil; } error:error]) return NO;
        return [self protected:^BOOL(NSError **e) {
            if (![[self runtimeRoot:e] isEqual:root]) return BFail(e, @"Jailbreak root changed during restore");
            // Recheck all targets before the first write, not interleaved with mutation.
            for (NSDictionary *entry in journal) {
                BOOL missing; struct stat st;
                NSData *now = BRead([entry[@"base"] intValue], entry[@"relative"], &st, &missing, e);
                NSData *old = entry[@"old"] == NSNull.null ? nil : entry[@"old"];
                struct stat before; [entry[@"stat"] getBytes:&before length:sizeof(before)];
                if ((old && (!now || ![old isEqual:now] || st.st_ino != before.st_ino || st.st_mode != before.st_mode || st.st_uid != before.st_uid || st.st_gid != before.st_gid)) || (!old && !missing)) return BFail(e, @"Destination changed after safety backup; no restore applied");
            }
            NSMutableArray *applied = [NSMutableArray array], *createdConfig = [NSMutableArray array], *createdApt = [NSMutableArray array];
            __block BOOL ok = YES; NSError *writeError = nil;
            @try {
                for (NSDictionary *entry in journal) {
#ifdef DO_BACKUP_TESTING
                    if (self.failAfterWrites >= 0 && applied.count >= (NSUInteger)self.failAfterWrites) { ok = BFail(&writeError, @"Injected write failure"); break; }
#endif
                    struct stat st; [entry[@"stat"] getBytes:&st length:sizeof(st)];
                    int base = [entry[@"base"] intValue];
                    [applied addObject:entry];
                    ok = BWrite(base, entry[@"relative"], plan[entry[@"path"]], st, [entry[@"originalFD"] intValue], base == configFD ? createdConfig : createdApt, &writeError);
                    if (!ok) break;
                }
            } @catch (NSException *exception) { ok = BFail(&writeError, @"Restore write raised an exception"); }
            if (ok) return YES;
            BOOL rollbackOK = YES;
            for (NSDictionary *entry in applied.reverseObjectEnumerator) {
                int base = [entry[@"base"] intValue]; NSString *relative = entry[@"relative"];
                if (entry[@"old"] != NSNull.null) {
                    struct stat st; [entry[@"stat"] getBytes:&st length:sizeof(st)];
                    if (!BWrite(base, relative, entry[@"old"], st, [entry[@"originalFD"] intValue], nil, nil)) rollbackOK = NO;
                } else {
                    int pfd = BParent(base, relative, NO, 0, 0, nil);
                    if (pfd < 0) { if (errno != ENOENT) rollbackOK = NO; }
                    else if (unlinkat(pfd, relative.lastPathComponent.fileSystemRepresentation, 0) && errno != ENOENT) rollbackOK = NO;
                    if (pfd >= 0) { fsync(pfd); close(pfd); }
                }
            }
            for (NSArray *pair in @[@[@(configFD), createdConfig], @[@(aptFD), createdApt]]) {
                for (NSString *dir in [pair[1] reverseObjectEnumerator]) {
                    int pfd = BParent([pair[0] intValue], dir, NO, 0, 0, nil);
                    if (pfd >= 0) { if (unlinkat(pfd, dir.lastPathComponent.fileSystemRepresentation, AT_REMOVEDIR)) rollbackOK = NO; close(pfd); }
                }
            }
            NSString *message = [NSString stringWithFormat:@"%@. %@ Safety backup: %@", writeError.localizedDescription ?: @"Restore failed", rollbackOK ? @"Original contents and metadata restored." : @"Rollback incomplete; use the safety backup.", safety.lastPathComponent];
            return BFail(e, message);
        } error:error];
    } @finally {
        for (NSDictionary *entry in journal) { int fd = [entry[@"originalFD"] intValue]; if (fd >= 0) close(fd); }
        if (configFD >= 0) close(configFD); if (aptFD >= 0) close(aptFD);
        [BLock unlock];
    }
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
        ![object[@"version"] isEqual:@1] || ![object[@"files"] isKindOfClass:NSArray.class]) return nil;
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
        for (NSData *data in archive.allValues) size += data.length;
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
        NSUInteger skipped = [reported isKindOfClass:NSNumber.class] ? reported.unsignedIntegerValue : (regular > archive.count ? regular - archive.count : 0);
        return @{@"url":url, @"files":@(archive.count), @"size":@(size), @"created":created ?: [NSDate dateWithTimeIntervalSince1970:0],
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
