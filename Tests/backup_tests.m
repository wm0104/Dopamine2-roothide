#import <Foundation/Foundation.h>
#import "DOConfigurationBackupManager.h"
#import <sys/stat.h>
#import <unistd.h>
@interface DOConfigurationBackupManager (ArchiveValidationTests)
- (NSDictionary *)loadArchive:(NSURL *)url error:(NSError **)error;
@end
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static void Put(NSString *p, NSData *d) { CHECK([NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]); CHECK([d writeToFile:p atomically:YES]); }
static NSData *Plist(NSString *v) { return [NSPropertyListSerialization dataWithPropertyList:@{@"value":v} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]; }
static NSData *Text(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
int main(void) { @autoreleasepool {
 NSString *temp=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
 NSString *root=[temp stringByAppendingPathComponent:@"root"], *store=[temp stringByAppendingPathComponent:@"storage"];
 NSString *prefs=[root stringByAppendingPathComponent:@"var/mobile/Library/Preferences"];
 NSString *a=[prefs stringByAppendingPathComponent:@"org.example.anytweak.plist"], *b=[prefs stringByAppendingPathComponent:@"org.example.second.plist"];
 NSString *apt=[root stringByAppendingPathComponent:@"etc/apt/sources.list.d/user.list"];
 Put(a,Plist(@"original")); Put(b,Plist(@"second"));
 Put([prefs stringByAppendingPathComponent:@"com.apple.test.plist"],Plist(@"excluded"));
 Put([prefs stringByAppendingPathComponent:@"cn.zqbb.dopaRH.plist"],Plist(@"excluded"));
 Put([prefs stringByAppendingPathComponent:@"org.example.secret.plist"],Text(@"<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>password</key><string>test</string></dict></plist>"));
 Put(apt,Text(@"deb https://keep.example/ ./\ndeb https://apt.002599.xyz/ ./\n"));
 CHECK([NSFileManager.defaultManager createDirectoryAtPath:store withIntermediateDirectories:YES attributes:nil error:nil]);
 DOConfigurationBackupManager *m=[[DOConfigurationBackupManager alloc] initWithTestRoot:root]; NSError *e=nil;
 NSURL *backup=[m createBackupInDirectory:[NSURL fileURLWithPath:store] error:&e];
 if (!backup) NSLog(@"%@",e); CHECK(backup);
 CHECK([m.lastBackupReport[@"skippedCount"] unsignedIntegerValue]>=3);
 CHECK(![NSFileManager.defaultManager fileExistsAtPath:[backup.path stringByAppendingPathComponent:@"config/Preferences/com.apple.test.plist"]]);
 NSDictionary *loaded = [m loadArchive:backup error:&e];
 if (!loaded) NSLog(@"Archive validation: %@ (%@)", e, backup.path); CHECK(loaded);
 NSArray *listed = [m backupsInDirectory:[NSURL fileURLWithPath:store] error:&e];
 if (listed.count != 1) NSLog(@"Backup enumeration: %@, error: %@", listed, e);
 CHECK(listed.count==1);
 // Names are readable in Files/Filza and must never overwrite an existing backup.
 CHECK([backup.lastPathComponent hasPrefix:@"配置备份_"]);
 NSRegularExpression *stampRule=[NSRegularExpression regularExpressionWithPattern:@"^配置备份_[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}(-[0-9]+)?$" options:0 error:nil];
 CHECK([stampRule numberOfMatchesInString:backup.lastPathComponent options:0 range:NSMakeRange(0,backup.lastPathComponent.length)]==1);
 NSURL *again=[m createBackupInDirectory:[NSURL fileURLWithPath:store] error:&e];
 if (!again) NSLog(@"Second backup: %@",e); CHECK(again && ![again.path isEqualToString:backup.path]);
 CHECK([NSFileManager.defaultManager removeItemAtURL:again error:nil]);
 NSString *edited=[backup.path stringByAppendingPathComponent:@"config/Preferences/org.example.anytweak.plist"];
 Put(edited,Plist(@"manual-edit")); Put(a,Plist(@"current")); chmod(a.fileSystemRepresentation,0600);
 CHECK([m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
 CHECK([[NSData dataWithContentsOfFile:a] isEqual:Plist(@"manual-edit")]);
 struct stat st; CHECK(stat(a.fileSystemRepresentation,&st)==0 && (st.st_mode&0777)==0600);
 Put(a,Plist(@"before-failure")); Put(b,Plist(@"before-second")); m.failAfterWrites=1;
 CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
 CHECK([[NSData dataWithContentsOfFile:a] isEqual:Plist(@"before-failure")]);
 CHECK([[NSData dataWithContentsOfFile:b] isEqual:Plist(@"before-second")]); m.failAfterWrites=-1;
 CHECK([m restoreBackupAtURL:backup restorePreferences:NO restoreSources:YES error:&e]);
 CHECK([[NSData dataWithContentsOfFile:apt] isEqual:Text(@"deb https://keep.example/ ./\ndeb https://apt.002599.xyz/ ./\n")]);
 NSString *legacy=[store stringByAppendingPathComponent:@"legacy"];
 Put([legacy stringByAppendingPathComponent:@"插件配置备份/Library/Preferences/org.example.anytweak.plist"],Plist(@"legacy"));
 Put([legacy stringByAppendingPathComponent:@"插件配置备份/Library/Preferences/com.apple.test.plist"],Plist(@"never"));
 Put([legacy stringByAppendingPathComponent:@"源地址备份/import.list"],Text(@"deb https://new.example/ ./\ndeb https://keep.example/ ./\ndeb https://apt.002599.xyz/ ./\n"));
 CHECK([m restoreBackupAtURL:[NSURL fileURLWithPath:legacy] restorePreferences:YES restoreSources:YES error:&e]);
 CHECK([[NSData dataWithContentsOfFile:a] isEqual:Plist(@"legacy")]);
 NSArray *files=[NSFileManager.defaultManager contentsOfDirectoryAtPath:apt.stringByDeletingLastPathComponent error:nil]; CHECK(files.count==2);
 CHECK([m restoreBackupAtURL:[NSURL fileURLWithPath:legacy] restorePreferences:NO restoreSources:YES error:&e]);
 CHECK([NSFileManager.defaultManager contentsOfDirectoryAtPath:apt.stringByDeletingLastPathComponent error:nil].count==2);
 CHECK([NSFileManager.defaultManager removeItemAtPath:edited error:nil]); CHECK(symlink(a.fileSystemRepresentation,edited.fileSystemRepresentation)==0);
 CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
 CHECK([NSFileManager.defaultManager removeItemAtPath:edited error:nil]); Put(edited,Plist(@"safe"));
 CHECK([NSFileManager.defaultManager removeItemAtPath:a error:nil]); CHECK(symlink(b.fileSystemRepresentation,a.fileSystemRepresentation)==0);
 CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:NO error:&e]);
 NSString *manifest=[backup.path stringByAppendingPathComponent:@"manifest.json"];
 NSMutableDictionary *json=[[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:manifest] options:NSJSONReadingMutableContainers error:nil] mutableCopy]; json[@"files"]=@[@"../escape"];
 Put(manifest,[NSJSONSerialization dataWithJSONObject:json options:0 error:nil]);
 CHECK(![m restoreBackupAtURL:backup restorePreferences:YES restoreSources:YES error:&e]);
 CHECK(![m restoreBackupAtURL:backup restorePreferences:NO restoreSources:NO error:&e]);
 CHECK([NSFileManager.defaultManager removeItemAtPath:temp error:nil]);
 printf("Backup engine: %u checks passed\n",checks);
 } return 0; }
