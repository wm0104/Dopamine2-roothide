// Retention, restore-preview and backup-list metadata coverage.
// Synthetic fixtures only; no device paths and no real authorization material.
static NSString *RCopy(NSString *from, NSString *to) {
    CHECK([NSFileManager.defaultManager copyItemAtPath:from toPath:to error:nil]);
    return to;
}
static BOOL RExists(NSString *path) { return [NSFileManager.defaultManager fileExistsAtPath:path]; }

static void RetentionTests(void) {
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *root = [temp stringByAppendingPathComponent:@"root"], *store = [temp stringByAppendingPathComponent:@"store"];
    NSString *other = [temp stringByAppendingPathComponent:@"outside"];
    Put([root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/org.example.anytweak.plist"], Plist(@"v"));
    Put([root stringByAppendingPathComponent:@"etc/apt/sources.list"], Text(@"deb https://fixture.example/ ./\n"));
    Put([other stringByAppendingPathComponent:@"keep.txt"], Text(@"outside"));
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil]);
    DOConfigurationBackupManager *m = [[DOConfigurationBackupManager alloc] initWithTestRoot:root];
    NSError *e = nil;
    NSURL *folder = [NSURL fileURLWithPath:store];
    NSURL *seed = [m createBackupInDirectory:folder error:&e];
    CHECK(seed);
    // Four manual and three safety backups with distinct, older names.
    for (int i = 1; i <= 4; i++)
        RCopy(seed.path, [store stringByAppendingPathComponent:[NSString stringWithFormat:@"配置备份_2024-01-0%d_00-00-00", i]]);
    for (int i = 1; i <= 3; i++)
        RCopy(seed.path, [store stringByAppendingPathComponent:[NSString stringWithFormat:@"恢复前备份_2024-02-0%d_00-00-00", i]]);
    RCopy(seed.path, [store stringByAppendingPathComponent:@"A1B2C3D4-0000-4000-8000-000000000000"]);
    CHECK([NSFileManager.defaultManager removeItemAtURL:seed error:nil]);
    // Never touched: same-looking folder without our manifest, legacy UUID name,
    // foreign folder, a plain file and a symlinked archive.
    Put([store stringByAppendingPathComponent:@"配置备份_2024-01-09_00-00-00/插件配置备份/Library/Preferences/org.example.anytweak.plist"], Plist(@"legacy"));
    Put([store stringByAppendingPathComponent:@"SomeUserFolder/user.txt"], Text(@"user"));
    Put([store stringByAppendingPathComponent:@"配置备份_2023-01-01_00-00-00"], Text(@"not-a-folder"));
    NSString *linked = [store stringByAppendingPathComponent:@"配置备份_2023-02-01_00-00-00"];
    CHECK(symlink([store stringByAppendingPathComponent:@"A1B2C3D4-0000-4000-8000-000000000000"].fileSystemRepresentation, linked.fileSystemRepresentation) == 0);

    NSDictionary *plan = [m retentionPlanInDirectory:folder error:&e];
    if (!plan) NSLog(@"Retention plan: %@", e);
    CHECK(plan);
    if ([plan[@"count"] unsignedIntegerValue] != 4) NSLog(@"unexpected candidates: %@", plan[@"candidates"]);
    CHECK([plan[@"count"] unsignedIntegerValue] == 4);
    CHECK([plan[@"needsConfirmation"] boolValue]);
    CHECK(!RExists([store stringByAppendingPathComponent:@".dopamine-retention.v1"]));
    for (NSURL *url in plan[@"candidates"]) CHECK(![url.lastPathComponent hasPrefix:@"A1B2C3D4"] && ![url.lastPathComponent isEqual:@"SomeUserFolder"]);
    // The first cleanup refuses to act without the one-time confirmation.
    CHECK(![m applyRetentionInDirectory:folder confirmed:NO error:&e]);
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-01_00-00-00"]));
    CHECK(!RExists([store stringByAppendingPathComponent:@".dopamine-retention.v1"]));
    NSArray *deleted = [m applyRetentionInDirectory:folder confirmed:YES error:&e];
    if (!deleted) NSLog(@"Retention apply: %@", e);
    CHECK(deleted && deleted.count == 4);
    CHECK(RExists([store stringByAppendingPathComponent:@".dopamine-retention.v1"]));
    // Newest two manual and newest safety survive; only the oldest are removed.
    CHECK(!RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-01_00-00-00"]));
    CHECK(!RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-02_00-00-00"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-03_00-00-00"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-04_00-00-00"]));
    CHECK(!RExists([store stringByAppendingPathComponent:@"恢复前备份_2024-02-01_00-00-00"]));
    CHECK(!RExists([store stringByAppendingPathComponent:@"恢复前备份_2024-02-02_00-00-00"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"恢复前备份_2024-02-03_00-00-00"]));
    // Everything that was not created by this app still exists.
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-09_00-00-00/插件配置备份/Library/Preferences/org.example.anytweak.plist"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"A1B2C3D4-0000-4000-8000-000000000000/manifest.json"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"SomeUserFolder/user.txt"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2023-01-01_00-00-00"]));
    struct stat linkStat;
    CHECK(lstat(linked.fileSystemRepresentation, &linkStat) == 0 && S_ISLNK(linkStat.st_mode));
    CHECK(RExists([other stringByAppendingPathComponent:@"keep.txt"]));
    // The marker makes every later cleanup silent and confirmation free.
    plan = [m retentionPlanInDirectory:folder error:&e];
    CHECK(plan && [plan[@"count"] unsignedIntegerValue] == 0 && ![plan[@"needsConfirmation"] boolValue]);
    NSURL *fresh = [m createBackupInDirectory:folder error:&e];
    CHECK(fresh);
    plan = [m retentionPlanInDirectory:folder error:&e];
    CHECK(plan && [plan[@"count"] unsignedIntegerValue] == 1 && ![plan[@"needsConfirmation"] boolValue]);
    deleted = [m applyRetentionInDirectory:folder confirmed:NO error:&e];
    CHECK(deleted && deleted.count == 1);
    CHECK(!RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-03_00-00-00"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-04_00-00-00"]));
    // A tampered archive is ignored instead of used or half deleted.
    CHECK([NSFileManager.defaultManager removeItemAtPath:[store stringByAppendingPathComponent:@"配置备份_2024-01-04_00-00-00/manifest.json"] error:nil]);
    plan = [m retentionPlanInDirectory:folder error:&e];
    CHECK(plan && [plan[@"count"] unsignedIntegerValue] == 0);
    CHECK(RExists([store stringByAppendingPathComponent:@"配置备份_2024-01-04_00-00-00"]));
    CHECK(RExists([store stringByAppendingPathComponent:fresh.lastPathComponent]));
    CHECK([NSFileManager.defaultManager removeItemAtPath:temp error:nil]);
}

// Rewrites the manifest creation time so ordering can be checked independently of names.
static void RSetCreated(NSString *path, double epoch) {
    NSString *manifest = [path stringByAppendingPathComponent:@"manifest.json"];
    NSMutableDictionary *json = [[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifest] options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    CHECK(json);
    json[@"created"] = @(epoch);
    CHECK([[NSJSONSerialization dataWithJSONObject:json options:0 error:nil] writeToFile:manifest atomically:YES]);
}
static NSString *RLegacyArchive(NSString *store, NSString *name, NSString *seed, double epoch) {
    NSString *path = RCopy(seed, [store stringByAppendingPathComponent:name]);
    RSetCreated(path, epoch);
    return path;
}

// Older builds of this app named archives after a UUID. They must count toward
// the same three-backup limit, ordered by the manifest time instead of the name.
static void LegacyRetentionTests(void) {
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *root = [temp stringByAppendingPathComponent:@"root"], *store = [temp stringByAppendingPathComponent:@"store"];
    NSString *outside = [temp stringByAppendingPathComponent:@"outside"];
    Put([root stringByAppendingPathComponent:@"var/mobile/Library/Preferences/org.example.anytweak.plist"], Plist(@"v"));
    Put([root stringByAppendingPathComponent:@"etc/apt/sources.list"], Text(@"deb https://fixture.example/ ./\n"));
    Put([outside stringByAppendingPathComponent:@"keep.txt"], Text(@"outside"));
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil]);
    DOConfigurationBackupManager *m = [[DOConfigurationBackupManager alloc] initWithTestRoot:root];
    NSError *e = nil;
    NSURL *folder = [NSURL fileURLWithPath:store];
    NSURL *seed = [m createBackupInDirectory:folder error:&e];
    if (!seed) NSLog(@"Legacy seed: %@", e);
    CHECK(seed);
    // Four legacy manual backups whose names are ordered opposite to their manifests.
    NSString *newest = @"ConfigurationBackup-AAAAAAAA-1111-4111-8111-111111111111";
    NSString *second = @"ConfigurationBackup-BBBBBBBB-2222-4222-8222-222222222222";
    NSString *third = @"ConfigurationBackup-CCCCCCCC-3333-4333-8333-333333333333";
    NSString *oldest = @"ConfigurationBackup-DDDDDDDD-4444-4444-8444-444444444444";
    NSString *safe = @"SafetyBackup-EEEEEEEE-5555-4555-8555-555555555555";
    RLegacyArchive(store, newest, seed.path, 4000);
    RLegacyArchive(store, second, seed.path, 3000);
    RLegacyArchive(store, third, seed.path, 2000);
    RLegacyArchive(store, oldest, seed.path, 1000);
    RLegacyArchive(store, safe, seed.path, 500);
    // Not ours: a legacy-looking name without a manifest, one with a foreign
    // manifest, and a legacy name that is a symlink to a valid archive.
    Put([store stringByAppendingPathComponent:@"ConfigurationBackup-FFFFFFFF-6666-4666-8666-666666666666/notes.txt"], Text(@"user"));
    NSDictionary *foreign = @{@"format":@"com.example.other", @"version":@1, @"files":@[], @"created":@9999.0};
    Put([store stringByAppendingPathComponent:@"ConfigurationBackup-99999999-7777-4777-8777-777777777777/manifest.json"],
        [NSJSONSerialization dataWithJSONObject:foreign options:0 error:nil]);
    Put([store stringByAppendingPathComponent:@"ConfigurationBackup-99999999-7777-4777-8777-777777777777/data.bin"], Text(@"foreign"));
    NSString *linkedTarget = [outside stringByAppendingPathComponent:@"valid"];
    RCopy(seed.path, linkedTarget);
    NSString *linked = [store stringByAppendingPathComponent:@"ConfigurationBackup-12121212-8888-4888-8888-888888888888"];
    CHECK(symlink(linkedTarget.fileSystemRepresentation, linked.fileSystemRepresentation) == 0);
    CHECK([NSFileManager.defaultManager removeItemAtURL:seed error:nil]);

    // A legacy row still reports time, file count and size from its manifest.
    NSDictionary *row = [m summaryForBackupAtURL:[folder URLByAppendingPathComponent:newest isDirectory:YES] error:&e];
    if (!row) NSLog(@"Legacy summary: %@", e);
    CHECK(row && [row[@"files"] unsignedIntegerValue] > 0 && [row[@"size"] unsignedIntegerValue] > 0);
    CHECK(fabs([row[@"created"] timeIntervalSince1970] - 4000) < 1);

    NSDictionary *plan = [m retentionPlanInDirectory:folder error:&e];
    if (!plan) NSLog(@"Legacy plan: %@", e);
    CHECK(plan);
    NSMutableArray *names = [NSMutableArray array];
    for (NSURL *url in plan[@"candidates"]) [names addObject:url.lastPathComponent];
    if ([plan[@"count"] unsignedIntegerValue] != 2) NSLog(@"Legacy candidates: %@", names);
    CHECK([plan[@"count"] unsignedIntegerValue] == 2);
    CHECK([names containsObject:third] && [names containsObject:oldest]);
    CHECK(![names containsObject:newest] && ![names containsObject:second] && ![names containsObject:safe]);
    CHECK([plan[@"needsConfirmation"] boolValue]);
    CHECK(![m applyRetentionInDirectory:folder confirmed:NO error:&e]);
    CHECK(RExists([store stringByAppendingPathComponent:oldest]));
    NSArray *deleted = [m applyRetentionInDirectory:folder confirmed:YES error:&e];
    if (!deleted) NSLog(@"Legacy apply: %@", e);
    CHECK(deleted && deleted.count == 2);
    CHECK(RExists([store stringByAppendingPathComponent:newest]));
    CHECK(RExists([store stringByAppendingPathComponent:second]));
    CHECK(!RExists([store stringByAppendingPathComponent:third]));
    CHECK(!RExists([store stringByAppendingPathComponent:oldest]));
    CHECK(RExists([store stringByAppendingPathComponent:safe]));
    CHECK(RExists([store stringByAppendingPathComponent:@".dopamine-retention.v1"]));
    // Folders that merely look like ours are never removed.
    CHECK(RExists([store stringByAppendingPathComponent:@"ConfigurationBackup-FFFFFFFF-6666-4666-8666-666666666666/notes.txt"]));
    CHECK(RExists([store stringByAppendingPathComponent:@"ConfigurationBackup-99999999-7777-4777-8777-777777777777/data.bin"]));
    struct stat linkStat;
    CHECK(lstat(linked.fileSystemRepresentation, &linkStat) == 0 && S_ISLNK(linkStat.st_mode));
    CHECK(RExists([outside stringByAppendingPathComponent:@"valid/manifest.json"]));
    CHECK(RExists([outside stringByAppendingPathComponent:@"keep.txt"]));
    plan = [m retentionPlanInDirectory:folder error:&e];
    CHECK(plan && [plan[@"count"] unsignedIntegerValue] == 0);

    // Mixed legacy and current names: the manifest time orders both families.
    NSString *mixed = [temp stringByAppendingPathComponent:@"mixed"];
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:mixed withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *mixedFolder = [NSURL fileURLWithPath:mixed];
    NSURL *seed2 = [m createBackupInDirectory:mixedFolder error:&e];
    CHECK(seed2);
    NSString *mixedLegacy = @"ConfigurationBackup-23232323-9999-4999-8999-999999999999";
    NSString *mixedOld = @"ConfigurationBackup-34343434-AAAA-4AAA-8AAA-AAAAAAAAAAAA";
    NSString *mixedSafety = @"SafetyBackup-45454545-BBBB-4BBB-8BBB-BBBBBBBBBBBB";
    NSString *mixedNew = @"配置备份_2024-01-02_00-00-00";
    NSString *mixedNewOld = @"配置备份_2024-01-01_00-00-00";
    NSString *mixedNewSafety = @"恢复前备份_2024-01-05_00-00-00";
    RLegacyArchive(mixed, mixedLegacy, seed2.path, 5000);
    RCopy(seed2.path, [mixed stringByAppendingPathComponent:mixedNew]); RSetCreated([mixed stringByAppendingPathComponent:mixedNew], 4000);
    RLegacyArchive(mixed, mixedOld, seed2.path, 3000);
    RCopy(seed2.path, [mixed stringByAppendingPathComponent:mixedNewOld]); RSetCreated([mixed stringByAppendingPathComponent:mixedNewOld], 2000);
    RLegacyArchive(mixed, mixedSafety, seed2.path, 700);
    RCopy(seed2.path, [mixed stringByAppendingPathComponent:mixedNewSafety]); RSetCreated([mixed stringByAppendingPathComponent:mixedNewSafety], 6000);
    CHECK([NSFileManager.defaultManager removeItemAtURL:seed2 error:nil]);
    plan = [m retentionPlanInDirectory:mixedFolder error:&e];
    if (!plan) NSLog(@"Mixed plan: %@", e);
    CHECK(plan && [plan[@"count"] unsignedIntegerValue] == 3);
    names = [NSMutableArray array];
    for (NSURL *url in plan[@"candidates"]) [names addObject:url.lastPathComponent];
    CHECK([names containsObject:mixedOld] && [names containsObject:mixedNewOld] && [names containsObject:mixedSafety]);
    CHECK(![names containsObject:mixedLegacy] && ![names containsObject:mixedNew] && ![names containsObject:mixedNewSafety]);
    deleted = [m applyRetentionInDirectory:mixedFolder confirmed:YES error:&e];
    if (!deleted) NSLog(@"Mixed apply: %@", e);
    CHECK(deleted && deleted.count == 3);
    CHECK(RExists([mixed stringByAppendingPathComponent:mixedLegacy]));
    CHECK(RExists([mixed stringByAppendingPathComponent:mixedNew]));
    CHECK(RExists([mixed stringByAppendingPathComponent:mixedNewSafety]));
    CHECK(!RExists([mixed stringByAppendingPathComponent:mixedOld]));
    CHECK(!RExists([mixed stringByAppendingPathComponent:mixedNewOld]));
    CHECK(!RExists([mixed stringByAppendingPathComponent:mixedSafety]));
    plan = [m retentionPlanInDirectory:mixedFolder error:&e];
    CHECK(plan && [plan[@"count"] unsignedIntegerValue] == 0);
    CHECK([NSFileManager.defaultManager removeItemAtPath:temp error:nil]);
}

static void RestoreSummaryTests(void) {
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *root = [temp stringByAppendingPathComponent:@"root"], *store = [temp stringByAppendingPathComponent:@"store"];
    NSString *prefs = [root stringByAppendingPathComponent:@"var/mobile/Library/Preferences"];
    Put([prefs stringByAppendingPathComponent:@"org.example.anytweak.plist"], Plist(@"v"));
    Put([prefs stringByAppendingPathComponent:@"org.example.second.plist"], Plist(@"s"));
    Put([prefs stringByAppendingPathComponent:@"com.apple.excluded.plist"], Plist(@"x"));
    Put([root stringByAppendingPathComponent:@"etc/apt/sources.list"], Text(@"deb https://fixture.example/ ./\n"));
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil]);
    DOConfigurationBackupManager *m = [[DOConfigurationBackupManager alloc] initWithTestRoot:root];
    NSError *e = nil;
    NSURL *folder = [NSURL fileURLWithPath:store];
    NSURL *backup = [m createBackupInDirectory:folder error:&e];
    CHECK(backup);
    NSUInteger skipped = [m.lastBackupReport[@"skippedCount"] unsignedIntegerValue];
    CHECK(skipped >= 1);
    NSDictionary *archive = [m loadArchive:backup error:&e];
    CHECK(archive);
    NSUInteger bytes = 0;
    for (NSData *data in archive.allValues) bytes += data.length;
    NSDictionary *summary = [m summaryForBackupAtURL:backup error:&e];
    if (!summary) NSLog(@"Summary: %@", e);
    CHECK(summary);
    CHECK([summary[@"files"] unsignedIntegerValue] == archive.count);
    CHECK([summary[@"size"] unsignedIntegerValue] == bytes);
    CHECK([summary[@"skipped"] unsignedIntegerValue] == skipped);
    CHECK([summary[@"created"] isKindOfClass:NSDate.class]);
    CHECK(fabs([summary[@"created"] timeIntervalSinceNow]) < 600);
    CHECK(![summary[@"legacy"] boolValue] && ![summary[@"safety"] boolValue]);
    CHECK([[summary[@"url"] lastPathComponent] isEqual:backup.lastPathComponent]);
    // The list carries the same metadata and keeps name order.
    NSArray *rows = [m backupSummariesInDirectory:folder error:&e];
    CHECK(rows.count == 1);
    CHECK([[rows[0][@"url"] lastPathComponent] isEqual:backup.lastPathComponent]);
    CHECK([rows[0][@"files"] unsignedIntegerValue] == archive.count);
    CHECK([rows[0][@"size"] unsignedIntegerValue] == bytes);
    // Legacy archives report restorable files, their bytes and the ignored rest.
    NSString *legacy = [store stringByAppendingPathComponent:@"legacy"];
    NSData *kept = Plist(@"legacy");
    Put([legacy stringByAppendingPathComponent:@"插件配置备份/Library/Preferences/org.example.anytweak.plist"], kept);
    Put([legacy stringByAppendingPathComponent:@"插件配置备份/Library/Preferences/com.apple.excluded.plist"], Plist(@"never"));
    NSData *sources = Text(@"deb https://new.example/ ./\n");
    Put([legacy stringByAppendingPathComponent:@"源地址备份/import.list"], sources);
    NSURL *legacyURL = [NSURL fileURLWithPath:legacy];
    NSDictionary *legacySummary = [m summaryForBackupAtURL:legacyURL error:&e];
    if (!legacySummary) NSLog(@"Legacy summary: %@", e);
    CHECK(legacySummary);
    NSDictionary *legacyLoaded = [m loadArchive:legacyURL error:&e];
    CHECK(legacyLoaded);
    NSUInteger legacyBytes = 0;
    for (NSData *data in legacyLoaded.allValues) legacyBytes += data.length;
    CHECK([legacySummary[@"files"] unsignedIntegerValue] == legacyLoaded.count && legacyLoaded.count == 2);
    CHECK([legacySummary[@"size"] unsignedIntegerValue] == legacyBytes && legacyBytes == kept.length + sources.length);
    CHECK([legacySummary[@"skipped"] unsignedIntegerValue] == 1);
    CHECK([legacySummary[@"legacy"] boolValue]);
    CHECK([legacySummary[@"created"] isKindOfClass:NSDate.class]);
    rows = [m backupSummariesInDirectory:folder error:&e];
    CHECK(rows.count == 2);
    BOOL listed = NO;
    for (NSDictionary *row in rows) if ([[row[@"url"] lastPathComponent] isEqual:backup.lastPathComponent]) {
        listed = YES;
        CHECK([row[@"files"] unsignedIntegerValue] == archive.count && [row[@"size"] unsignedIntegerValue] == bytes);
    }
    CHECK(listed);
    // A folder that is not a backup has no summary at all.
    CHECK(![m summaryForBackupAtURL:[NSURL fileURLWithPath:root] error:&e]);
    CHECK([NSFileManager.defaultManager removeItemAtPath:temp error:nil]);
}
