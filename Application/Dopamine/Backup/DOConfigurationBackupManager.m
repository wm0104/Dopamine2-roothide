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
static BOOL BConfig(NSString *path, NSData *data, NSError **error) {
    NSArray *parts = path.pathComponents;
    BOOL allowed = parts.count == 2 && (([parts[0] isEqual:@"Preferences"] && BPreferenceName(parts[1])) || ([parts[0] isEqual:@"RootHide"] && [BRootHideNames() containsObject:parts[1]]));
    if (!allowed) return BFail(error, @"Configuration is not on the explicit allowlist");
    id plist = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:error];
    return ([plist isKindOfClass:NSDictionary.class] && !BSecret(plist)) || BFail(error, @"Configuration must be a dictionary plist without credential/device keys");
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
    if (![original isEqual:original.stringByStandardizingPath]) return BFail(error, @"Non-canonical folder path rejected");
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
    for (NSString *kind in @[@"Preferences", @"RootHide"]) {
        if (!ok) break;
        for (NSString *name in [kind isEqual:@"Preferences"] ? preferences : BRootHideNames()) {
            NSString *path = [kind stringByAppendingPathComponent:name];
            if ([kind isEqual:@"Preferences"] && !BPreferenceName(name)) {
                [skipped addObject:@{@"path":path, @"reason":@"excluded-system-control-credential-or-unsupported-name"}]; continue;
            }
            BOOL missing; NSError *readError = nil;
            NSData *data = BRead(lfd, path, NULL, &missing, &readError);
            if (missing) continue;
            NSError *configError = nil;
            if (!data || !BConfig(path, data, &configError)) {
                [skipped addObject:@{@"path":path, @"reason":data ? @"non-dictionary-malformed-or-sensitive-content" : @"unsafe-link-unreadable-special-or-oversized"}]; continue;
            }
            result[[@"config" stringByAppendingPathComponent:path]] = data;
        }
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
    NSString *name = [NSString stringWithFormat:@"%@-%@", safety ? @"SafetyBackup" : @"ConfigurationBackup", uuid];
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
            NSArray *p = config.pathComponents;
            if (p.count == 2 && (([p[0] isEqual:@"Preferences"] && BPreferenceName(p[1])) || ([p[0] isEqual:@"RootHide"] && [BRootHideNames() containsObject:p[1]]))) mapped = [@"config" stringByAppendingPathComponent:config];
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
                if ([self loadArchive:child error:&archiveError]) [results addObject:child];
#ifdef DO_BACKUP_TESTING
                else NSLog(@"Skipped backup %@: %@", child, archiveError);
#endif
            }
            [results sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) { return [a.lastPathComponent compare:b.lastPathComponent options:NSNumericSearch]; }];
            return YES;
        } error:error];
        return ok ? results : @[];
    } @finally { [BLock unlock]; }
}
@end
