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
