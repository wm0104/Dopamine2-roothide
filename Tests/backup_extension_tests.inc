// Synthetic fixtures only. No device roots or real authorization material.
static void ExtendedBackupTests(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *temp = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSString *root = [temp stringByAppendingPathComponent:@"root"], *store = [temp stringByAppendingPathComponent:@"storage"];
    NSString *library = [root stringByAppendingPathComponent:@"var/mobile/Library"];
    NSString *apt = [root stringByAppendingPathComponent:@"etc/apt/sources.list.d"];
    NSDictionary *config = @{@"Preferences/com.apple.test.plist":Plist(@"system-pref"),
        @"Preferences/device-authorization.plist":Text(@"opaque credential/device config"),
        @"Preferences/nested/config.json":Text(@"{}"),
        @"ControlCenter/ModuleConfiguration_CCSupport.plist":Plist(@"layout"),
        @"CallAssist/ZSSMSblacklist.db":Text(@"synthetic database"),
        @"CallAssist/theme/nested/theme.bin":Text(@"theme"),
        @"RootHide/cn.zqbb.inject.plist":Plist(@"inject"),
        @"RootHide/cn.zqbb.inject.system.plist":Plist(@"system inject"),
        @"RootHide/.wm0104-source-migration-v1":Text(@"1\n"),
        @"RootHide/varCleanRules-custom.plist":Plist(@"rules"),
        @"CallAssistActivation/Activation.plist":Text(@"synthetic license"),
        @"Filza/test.txt":Text(@"fixture"),
        @"Snapper3/license":Text(@"synthetic binary"),
        @"Snapper3/Images/image.bin":[NSMutableData dataWithLength:3 * 1024 * 1024]};
    for (NSString *path in config) Put([library stringByAppendingPathComponent:path], config[path]);
    NSString *empty = [library stringByAppendingPathComponent:@"CallAssist/theme/empty"];
    CHECK([fm createDirectoryAtPath:empty withIntermediateDirectories:YES attributes:nil error:nil]);
    NSDictionary *sources = @{@"default.sources":Text(@"# keep exact bytes\nTypes: deb\nURIs: https://fixture.example/\nSuites: ./\n"),
        @"procursus.sources":Text(@"fixture bootstrap bytes\n"), @"sileo.sources":[NSData data],
        @"imported-SYNTHETIC.sources":Text(@"fixture user sources\n")};
    for (NSString *name in sources) Put([apt stringByAppendingPathComponent:name], sources[name]);
    Put([root stringByAppendingPathComponent:@"etc/apt/sources.list"], Text(@"outside selected folder"));
    Put([library stringByAppendingPathComponent:@"Unrelated/keep"], Text(@"untouched"));
    NSString *pref = [library stringByAppendingPathComponent:@"Preferences/com.apple.test.plist"];
    CHECK(chmod(pref.fileSystemRepresentation, 0640) == 0);
    CHECK([fm createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil]);
    DOConfigurationBackupManager *m = [[DOConfigurationBackupManager alloc] initWithTestRoot:root];
    NSError *e = nil; NSURL *folder = [NSURL fileURLWithPath:store];
    NSURL *backup = [m createBackupInDirectory:folder error:&e];
    if (!backup) NSLog(@"Folder backup: %@", e); CHECK(backup);
    NSDictionary *archive = [m loadArchive:backup error:&e]; CHECK(archive);
    CHECK([archive[@"version"] isEqual:@2]);
    CHECK([archive[@"directories"] containsObject:@"config/CallAssist/theme/empty"]);
    for (NSString *path in config) CHECK([archive[@"files"][[ @"config/" stringByAppendingString:path]] isEqual:config[path]]);
    for (NSString *name in sources) CHECK([archive[@"files"][[ @"sources/sources.list.d/" stringByAppendingString:name]] isEqual:sources[name]]);
    CHECK([m.lastBackupReport[@"skippedCount"] unsignedIntegerValue] == 0);
    NSArray *roots = @[@"Preferences", @"ControlCenter", @"CallAssist", @"RootHide", @"CallAssistActivation", @"Snapper3", @"Filza"];
    for (NSString *name in roots) Put([[library stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"extra-after-backup"], Text(@"remove"));
    Put([apt stringByAppendingPathComponent:@"extra.list"], Text(@"remove")); Put(pref, Plist(@"changed"));
    CHECK([m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
    CHECK([fm fileExistsAtPath:[apt stringByAppendingPathComponent:@"extra.list"]]);
    for (NSString *name in roots) CHECK(![fm fileExistsAtPath:[[library stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"extra-after-backup"]]);
    for (NSString *path in config) CHECK([[NSData dataWithContentsOfFile:[library stringByAppendingPathComponent:path]] isEqual:config[path]]);
    struct stat st; CHECK(stat(pref.fileSystemRepresentation, &st) == 0 && (st.st_mode & 0777) == 0640);
    CHECK([fm fileExistsAtPath:empty]);
    Put(pref, Plist(@"keep unchecked category"));
    CHECK([m restoreBackupAtURL:backup restorePreferences:NO restoreSources:YES error:&e]);
    CHECK([[NSData dataWithContentsOfFile:pref] isEqual:Plist(@"keep unchecked category")]);
    CHECK([[fm contentsOfDirectoryAtPath:apt error:nil] count] == sources.count);
    for (NSString *name in sources) CHECK([[NSData dataWithContentsOfFile:[apt stringByAppendingPathComponent:name]] isEqual:sources[name]]);
    CHECK([[NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"etc/apt/sources.list"]] isEqual:Text(@"outside selected folder")]);
    CHECK([[NSData dataWithContentsOfFile:[library stringByAppendingPathComponent:@"Unrelated/keep"]] isEqual:Text(@"untouched")]);
    // Fail after the first directory swap; all original trees and their metadata survive.
    for (NSString *name in roots) Put([[library stringByAppendingPathComponent:name] stringByAppendingPathComponent:@"before-failure"], Text(name));
    NSDictionary *before = [m snapshot:root error:&e]; CHECK(before);
    m.failAfterWrites = 1;
    CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:YES error:&e]);
    NSDictionary *after = [m snapshot:root error:&e]; CHECK(after);
    CHECK([before[@"files"] isEqual:after[@"files"]]); CHECK([before[@"metadata"] isEqual:after[@"metadata"]]);
    CHECK([before[@"directories"] isEqual:after[@"directories"]]); m.failAfterWrites = -1;
    // Missing live directories are recreated; a saved empty directory removes stale contents.
    CHECK([fm removeItemAtPath:[library stringByAppendingPathComponent:@"Snapper3"] error:nil]);
    CHECK([m restoreBackupAtURL:backup restorePreferences:YES restoreSources:YES error:&e]);
    CHECK([[NSData dataWithContentsOfFile:[library stringByAppendingPathComponent:@"Snapper3/license"]] isEqual:config[@"Snapper3/license"]]);
    // Directory absence is not an empty-directory instruction.
    CHECK([fm removeItemAtPath:[library stringByAppendingPathComponent:@"ControlCenter"] error:nil]);
    NSURL *missing = [m createBackupInDirectory:folder error:&e]; CHECK(missing);
    Put([library stringByAppendingPathComponent:@"ControlCenter/keep"], Text(@"not in backup"));
    CHECK([m restoreBackupAtURL:missing restorePreferences:YES restoreSources:NO error:&e]);
    CHECK([fm fileExistsAtPath:[library stringByAppendingPathComponent:@"ControlCenter/keep"]]);
    CHECK([fm removeItemAtPath:[library stringByAppendingPathComponent:@"ControlCenter"] error:nil]);
    CHECK([fm createDirectoryAtPath:[library stringByAppendingPathComponent:@"ControlCenter"] withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *emptyBackup = [m createBackupInDirectory:folder error:&e]; CHECK(emptyBackup);
    Put([library stringByAppendingPathComponent:@"ControlCenter/remove"], Text(@"stale"));
    CHECK([m restoreBackupAtURL:emptyBackup restorePreferences:YES restoreSources:NO error:&e]);
    CHECK([[fm contentsOfDirectoryAtPath:[library stringByAppendingPathComponent:@"ControlCenter"] error:nil] count] == 0);
    // A version-1 partial backup must never wipe a complete live directory.
    NSString *manifestPath = [backup.path stringByAppendingPathComponent:@"manifest.json"];
    NSData *manifest = [NSData dataWithContentsOfFile:manifestPath];
    NSMutableDictionary *json = [[NSJSONSerialization JSONObjectWithData:manifest options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    json[@"version"] = @1; Put(manifestPath, [NSJSONSerialization dataWithJSONObject:json options:0 error:nil]);
    CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:YES error:&e]);
    CHECK([e.localizedDescription containsString:@"version 2"]); Put(manifestPath, manifest);
    // Links/traversal and unlisted files fail before touching any live folder.
    NSString *archived = [backup.path stringByAppendingPathComponent:@"config/Preferences/com.apple.test.plist"];
    NSData *saved = [NSData dataWithContentsOfFile:archived];
    CHECK([fm removeItemAtPath:archived error:nil]); CHECK(symlink(pref.fileSystemRepresentation, archived.fileSystemRepresentation) == 0);
    CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:YES error:&e]);
    CHECK([fm removeItemAtPath:archived error:nil]); Put(archived, saved);
    CHECK([fm removeItemAtPath:archived error:nil]); CHECK(link(pref.fileSystemRepresentation, archived.fileSystemRepresentation) == 0);
    CHECK(![m loadArchive:backup error:&e]);
    CHECK([fm removeItemAtPath:archived error:nil]); Put(archived, saved);
    json = [[NSJSONSerialization JSONObjectWithData:manifest options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    json[@"files"] = @[@"../outside"]; Put(manifestPath, [NSJSONSerialization dataWithJSONObject:json options:0 error:nil]);
    CHECK(![m loadArchive:backup error:&e]); Put(manifestPath, manifest);
    json = [[NSJSONSerialization JSONObjectWithData:manifest options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    [json[@"metadata"] removeObjectForKey:@"config/Preferences"];
    Put(manifestPath, [NSJSONSerialization dataWithJSONObject:json options:0 error:nil]);
    CHECK(![m loadArchive:backup error:&e]); Put(manifestPath, manifest);
    json = [[NSJSONSerialization JSONObjectWithData:manifest options:NSJSONReadingMutableContainers error:nil] mutableCopy];
    json[@"directories"] = @[@"config/Preferences/../Other"];
    Put(manifestPath, [NSJSONSerialization dataWithJSONObject:json options:0 error:nil]);
    CHECK(![m loadArchive:backup error:&e]); Put(manifestPath, manifest);
    NSString *extra = [backup.path stringByAppendingPathComponent:@"config/Preferences/unlisted"];
    Put(extra, Text(@"unexpected")); CHECK(![m loadArchive:backup error:&e]); CHECK([fm removeItemAtPath:extra error:nil]);
    CHECK([fm removeItemAtPath:pref error:nil]); CHECK(symlink(archived.fileSystemRepresentation, pref.fileSystemRepresentation) == 0);
    CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:YES error:&e]);
    CHECK([fm removeItemAtPath:pref error:nil]); Put(pref, saved);
    CHECK(![m restoreBackupAtURL:backup restorePreferences:NO restoreSources:NO error:&e]);
    // Only the fixed runtime /var anchor may resolve through RootHide's secondary root.
    NSString *secondary = [temp stringByAppendingPathComponent:@"secondary"];
    CHECK([fm createDirectoryAtPath:secondary withIntermediateDirectories:YES attributes:nil error:nil]);
    CHECK([fm moveItemAtPath:[root stringByAppendingPathComponent:@"var"] toPath:[secondary stringByAppendingPathComponent:@"var"] error:&e]);
    CHECK(symlink([secondary stringByAppendingPathComponent:@"var"].fileSystemRepresentation, [root stringByAppendingPathComponent:@"var"].fileSystemRepresentation) == 0);
    CHECK([m createBackupInDirectory:folder error:&e]);
    NSString *blank = [temp stringByAppendingPathComponent:@"blank-root"];
    CHECK([fm createDirectoryAtPath:[blank stringByAppendingPathComponent:@"var/mobile/Library"] withIntermediateDirectories:YES attributes:nil error:nil]);
    CHECK([fm createDirectoryAtPath:[blank stringByAppendingPathComponent:@"etc/apt"] withIntermediateDirectories:YES attributes:nil error:nil]);
    DOConfigurationBackupManager *emptyManager = [[DOConfigurationBackupManager alloc] initWithTestRoot:blank];
    CHECK(![emptyManager createBackupInDirectory:folder error:&e]);
    CHECK([fm removeItemAtPath:temp error:nil]);
}
