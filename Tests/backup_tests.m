#import <Foundation/Foundation.h>
#import "DOConfigurationBackupManager.h"
#import <sys/stat.h>
#import <unistd.h>
@interface DOConfigurationBackupManager (ArchiveValidationTests)
- (NSDictionary *)loadArchive:(NSURL *)url error:(NSError **)error;
- (NSDictionary *)snapshot:(NSString *)root error:(NSError **)error;
@end
static unsigned checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static void Put(NSString *p, NSData *d) { CHECK([NSFileManager.defaultManager createDirectoryAtPath:p.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]); CHECK([d writeToFile:p atomically:YES]); }
static NSData *Plist(NSString *v) { return [NSPropertyListSerialization dataWithPropertyList:@{@"value":v} format:NSPropertyListXMLFormat_v1_0 options:0 error:nil]; }
static NSData *Text(NSString *s) { return [s dataUsingEncoding:NSUTF8StringEncoding]; }
#include "backup_extension_tests.inc"
#include "backup_retention_tests.inc"
int main(void) { @autoreleasepool {
    ExtendedBackupTests();
    RetentionTests();
    LegacyRetentionTests();
    RestoreSummaryTests();
    printf("Backup engine: %u checks passed\n", checks);
} return 0; }
