#import <sys/xattr.h>
// Synthetic data only. Never access device roots or real authorization material.
static void ExtendedBackupTests(void) {
 NSString *temp=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString *root=[temp stringByAppendingPathComponent:@"root"], *store=[temp stringByAppendingPathComponent:@"storage"];
 NSString *library=[root stringByAppendingPathComponent:@"var/mobile/Library"];
 NSArray *paths=@[@"ControlCenter/ModuleConfiguration_CCSupport.plist", @"CallAssistActivation/Activation.plist", @"Snapper3/license"];
 unsigned char bytes[256]; for (NSUInteger i=0;i<sizeof(bytes);i++) bytes[i]=(unsigned char)i;
 NSData *binary=[NSData dataWithBytes:bytes length:sizeof(bytes)];
 NSData *activation=[NSPropertyListSerialization dataWithPropertyList:@{@"deviceid":@"synthetic-device", @"authorization":@"synthetic-authorization"} format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
 NSArray *values=@[Plist(@"layout"),activation,binary];
 Put([root stringByAppendingPathComponent:@"etc/apt/sources.list"],Text(@"deb https://fixture.example/ ./\n"));
 CHECK([NSFileManager.defaultManager createDirectoryAtPath:library withIntermediateDirectories:YES attributes:nil error:nil]);
 CHECK([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil]);
 DOConfigurationBackupManager *m=[[DOConfigurationBackupManager alloc] initWithTestRoot:root]; NSError *e=nil;
 NSURL *folder=[NSURL fileURLWithPath:store];
 NSURL *old=[m createBackupInDirectory:folder error:&e]; CHECK(old);
 CHECK([m restoreBackupAtURL:old restorePreferences:YES restoreSources:NO error:&e]);
 for (NSUInteger i=0;i<paths.count;i++) Put([library stringByAppendingPathComponent:paths[i]],values[i]);
 NSArray *excluded=@[@"Snapper3/statistics.plist",@"Snapper3/Plugins/file.plist",@"Snapper3/Images/image",@"Snapper3/ImagesThumbnails/thumb",@"CallAssistActivation/other.plist",@"ControlCenter/other.plist",@"Preferences/org.example.authorization.plist"];
 for (NSString *path in excluded) Put([library stringByAppendingPathComponent:path],activation);
 NSURL *backup=[m createBackupInDirectory:folder error:&e]; CHECK(backup);
 NSDictionary *loaded=[m loadArchive:backup error:&e]; CHECK(loaded);
 for (NSUInteger i=0;i<paths.count;i++) CHECK([loaded[[@"config/" stringByAppendingString:paths[i]]] isEqual:values[i]]);
 for (NSString *path in excluded) CHECK(!loaded[[@"config/" stringByAppendingString:path]]);
 // Category isolation and lossless binary restore; preserve destination metadata.
 struct stat before[3];
 for (NSUInteger i=0;i<paths.count;i++) {
  NSString *p=[library stringByAppendingPathComponent:paths[i]]; Put(p,i==2?Text(@"changed-binary"):Plist(@"changed"));
  CHECK(chmod(p.fileSystemRepresentation,0600+i*4)==0); CHECK(stat(p.fileSystemRepresentation,&before[i])==0);
  CHECK(setxattr(p.fileSystemRepresentation,"org.dopamine.synthetic",bytes,1,0,0)==0);
 }
 CHECK([m restoreBackupAtURL:backup restorePreferences:NO restoreSources:YES error:&e]);
 CHECK([[NSData dataWithContentsOfFile:[library stringByAppendingPathComponent:paths[2]]] isEqual:Text(@"changed-binary")]);
 CHECK([m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
 for (NSUInteger i=0;i<paths.count;i++) {
  NSString *p=[library stringByAppendingPathComponent:paths[i]]; struct stat after;
  CHECK([[NSData dataWithContentsOfFile:p] isEqual:values[i]]); CHECK(stat(p.fileSystemRepresentation,&after)==0);
  CHECK((after.st_mode&0777)==(before[i].st_mode&0777) && after.st_uid==before[i].st_uid && after.st_gid==before[i].st_gid);
  CHECK(after.st_mtimespec.tv_sec==before[i].st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec==before[i].st_mtimespec.tv_nsec);
  unsigned char attribute=255; CHECK(getxattr(p.fileSystemRepresentation,"org.dopamine.synthetic",&attribute,1,0,0)==1 && attribute==bytes[0]);
 }
 // A source sorted after the three new config paths forces failure after all three writes.
 NSString *legacy=[store stringByAppendingPathComponent:@"legacy-extended"];
 for (NSUInteger i=0;i<paths.count;i++) Put([[legacy stringByAppendingPathComponent:@"插件配置备份/Library"] stringByAppendingPathComponent:paths[i]],values[i]);
 for (NSString *p in excluded) Put([[legacy stringByAppendingPathComponent:@"插件配置备份/Library"] stringByAppendingPathComponent:p],activation);
 Put([legacy stringByAppendingPathComponent:@"源地址备份/new.list"],Text(@"deb https://other-fixture.example/ ./\n"));
 NSURL *legacyURL=[NSURL fileURLWithPath:legacy];
 // Eligible Preferences containing secrets fail closed; unsupported siblings are ignored.
 CHECK(![m loadArchive:legacyURL error:&e]);
 CHECK([NSFileManager.defaultManager removeItemAtPath:[legacy stringByAppendingPathComponent:@"插件配置备份/Library/Preferences/org.example.authorization.plist"] error:nil]);
 CHECK([m loadArchive:legacyURL error:&e].count==4);
 for (NSUInteger i=0;i<paths.count;i++) {
  NSString *p=[library stringByAppendingPathComponent:paths[i]]; Put(p,i==2?Text(@"rollback-binary"):Plist(@"rollback-plist"));
  CHECK(chmod(p.fileSystemRepresentation,0600)==0); CHECK(stat(p.fileSystemRepresentation,&before[i])==0);
  CHECK(setxattr(p.fileSystemRepresentation,"org.dopamine.synthetic",bytes,1,0,0)==0);
 }
 m.failAfterWrites=3; CHECK(![m restoreBackupAtURL:legacyURL restorePreferences:YES restoreSources:YES error:&e]);
 for (NSUInteger i=0;i<paths.count;i++) {
  NSString *p=[library stringByAppendingPathComponent:paths[i]]; struct stat after;
  CHECK([[NSData dataWithContentsOfFile:p] isEqual:(i==2?Text(@"rollback-binary"):Plist(@"rollback-plist"))]);
  CHECK(stat(p.fileSystemRepresentation,&after)==0);
  CHECK((after.st_mode&0777)==(before[i].st_mode&0777) && after.st_uid==before[i].st_uid && after.st_gid==before[i].st_gid);
  CHECK(after.st_mtimespec.tv_sec==before[i].st_mtimespec.tv_sec && after.st_mtimespec.tv_nsec==before[i].st_mtimespec.tv_nsec);
  unsigned char attribute=255; CHECK(getxattr(p.fileSystemRepresentation,"org.dopamine.synthetic",&attribute,1,0,0)==1 && attribute==bytes[0]);
 }
 NSArray *archives=[m backupsInDirectory:folder error:&e]; BOOL safetyFound=NO;
 for (NSURL *url in archives) if ([url.lastPathComponent hasPrefix:@"恢复前备份_"]) {
  NSDictionary *safety=[m loadArchive:url error:&e];
  if ([safety[@"config/Snapper3/license"] isEqual:Text(@"rollback-binary")]) safetyFound=YES;
 }
 CHECK(safetyFound); m.failAfterWrites=-1;
 CHECK([m restoreBackupAtURL:legacyURL restorePreferences:YES restoreSources:NO error:&e]);
 for (NSUInteger i=0;i<paths.count;i++) CHECK([[NSData dataWithContentsOfFile:[library stringByAppendingPathComponent:paths[i]]] isEqual:values[i]]);
 // Missing directories are created only as needed, and removed again on rollback.
 for (NSString *dir in @[@"ControlCenter",@"CallAssistActivation",@"Snapper3"]) CHECK([NSFileManager.defaultManager removeItemAtPath:[library stringByAppendingPathComponent:dir] error:nil]);
 m.failAfterWrites=3; CHECK(![m restoreBackupAtURL:legacyURL restorePreferences:YES restoreSources:YES error:&e]);
 for (NSString *dir in @[@"ControlCenter",@"CallAssistActivation",@"Snapper3"]) CHECK(![NSFileManager.defaultManager fileExistsAtPath:[library stringByAppendingPathComponent:dir]]);
 m.failAfterWrites=-1; CHECK([m restoreBackupAtURL:legacyURL restorePreferences:YES restoreSources:NO error:&e]);
 for (NSUInteger i=0;i<paths.count;i++) CHECK([[NSData dataWithContentsOfFile:[library stringByAppendingPathComponent:paths[i]]] isEqual:values[i]]);
 // Tampered current archives reject siblings, traversal, symlinks and hardlinks.
 NSString *manifest=[backup.path stringByAppendingPathComponent:@"manifest.json"];
 NSData *originalManifest=[NSData dataWithContentsOfFile:manifest];
 for (NSString *relative in excluded) {
  NSString *file=[@"config/" stringByAppendingString:relative];
  NSMutableDictionary *json=[[NSJSONSerialization JSONObjectWithData:originalManifest options:NSJSONReadingMutableContainers error:nil] mutableCopy];
  json[@"files"]=[json[@"files"] arrayByAddingObject:file];
  Put([backup.path stringByAppendingPathComponent:file],activation); Put(manifest,[NSJSONSerialization dataWithJSONObject:json options:0 error:nil]);
  CHECK(![m loadArchive:backup error:&e]);
  CHECK([NSFileManager.defaultManager removeItemAtPath:[backup.path stringByAppendingPathComponent:file] error:nil]);
 }
 Put(manifest,originalManifest);
 for (NSString *relative in @[@"config/Snapper3/../license",@"config/CallAssistActivation/./Activation.plist",@"/config/Snapper3/license"]) {
  NSMutableDictionary *json=[[NSJSONSerialization JSONObjectWithData:originalManifest options:NSJSONReadingMutableContainers error:nil] mutableCopy]; json[@"files"]=@[relative];
  Put(manifest,[NSJSONSerialization dataWithJSONObject:json options:0 error:nil]); CHECK(![m loadArchive:backup error:&e]);
 }
 Put(manifest,originalManifest);
 for (NSUInteger i=0;i<paths.count;i++) {
  NSString *archived=[[backup.path stringByAppendingPathComponent:@"config"] stringByAppendingPathComponent:paths[i]];
  NSString *live=[library stringByAppendingPathComponent:paths[i]];
  CHECK([NSFileManager.defaultManager removeItemAtPath:archived error:nil]); CHECK(symlink(live.fileSystemRepresentation,archived.fileSystemRepresentation)==0);
  CHECK(![m loadArchive:backup error:&e]); CHECK([NSFileManager.defaultManager removeItemAtPath:archived error:nil]);
  CHECK(link(live.fileSystemRepresentation,archived.fileSystemRepresentation)==0); CHECK(![m loadArchive:backup error:&e]);
  CHECK([NSFileManager.defaultManager removeItemAtPath:archived error:nil]); Put(archived,values[i]);
  // Unsafe destination also refuses preflight without writes.
  CHECK([NSFileManager.defaultManager removeItemAtPath:live error:nil]); CHECK(symlink(archived.fileSystemRepresentation,live.fileSystemRepresentation)==0);
  CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
  CHECK([NSFileManager.defaultManager removeItemAtPath:live error:nil]);
  CHECK(link(archived.fileSystemRepresentation,live.fileSystemRepresentation)==0); CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
  CHECK([NSFileManager.defaultManager removeItemAtPath:live error:nil]); Put(live,values[i]);
 }
 // Parent symlinks are never trusted below the runtime Library anchor.
 NSString *snapper=[library stringByAppendingPathComponent:@"Snapper3"];
 CHECK([NSFileManager.defaultManager removeItemAtPath:snapper error:nil]);
 CHECK(symlink([backup.path stringByAppendingPathComponent:@"config/Snapper3"].fileSystemRepresentation,snapper.fileSystemRepresentation)==0);
 CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
 CHECK([NSFileManager.defaultManager removeItemAtPath:snapper error:nil]); Put([library stringByAppendingPathComponent:paths[2]],binary);
 // Dictionary validation applies to both plist paths, not just well-formed plist syntax.
 NSData *arrayPlist=[NSPropertyListSerialization dataWithPropertyList:@[@"synthetic"] format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
 for (NSUInteger i=0;i<2;i++) {
  NSString *archived=[[backup.path stringByAppendingPathComponent:@"config"] stringByAppendingPathComponent:paths[i]];
  Put(archived,arrayPlist); CHECK(![m loadArchive:backup error:&e]); Put(archived,values[i]);
 }
 // Exact license exception only: layout retains secret detection, activation requires a dictionary.
 NSArray *invalid=@[activation,Text(@"not-a-plist"),[NSMutableData dataWithLength:65537]];
 for (NSUInteger i=0;i<paths.count;i++) {
  NSString *live=[library stringByAppendingPathComponent:paths[i]]; Put(live,invalid[i]);
  NSURL *skipped=[m createBackupInDirectory:folder error:&e]; CHECK(skipped);
  CHECK(![m loadArchive:skipped error:&e][[@"config/" stringByAppendingString:paths[i]]]);
  CHECK([m.lastBackupReport[@"skippedCount"] unsignedIntegerValue]>0);
  // Invalid existing destination cannot be overwritten outside the safety snapshot.
  CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
  NSString *archived=[[backup.path stringByAppendingPathComponent:@"config"] stringByAppendingPathComponent:paths[i]];
  Put(archived,invalid[i]); CHECK(![m loadArchive:backup error:&e]); Put(archived,values[i]); Put(live,values[i]);
 }
 NSString *license=[library stringByAppendingPathComponent:paths[2]]; Put(license,[NSData data]);
 NSURL *empty=[m createBackupInDirectory:folder error:&e]; CHECK(empty); CHECK(![m loadArchive:empty error:&e][@"config/Snapper3/license"]);
 CHECK([NSFileManager.defaultManager removeItemAtPath:temp error:nil]);
}
