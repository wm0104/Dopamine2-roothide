#import <Foundation/Foundation.h>
#import "DOSourceMigration.h"
#import <sys/stat.h>
#import <unistd.h>
static NSUInteger checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL line %d: %s\n",__LINE__,#x); exit(1); } } while(0)
static void Put(NSString *path, NSString *text) {
    NSError *e=nil;
    CHECK([NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:&e]);
    CHECK([text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&e]);
}
static NSString *Read(NSString *p) {return [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];}
int main(void) { @autoreleasepool {
    NSError *e=nil;
    NSString *old=@"deb https://apt.002599.xyz/ ./\n";
    CHECK([[DOSourceMigration sanitizedSourceText:old deb822:NO error:&e] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length==0);
    NSString *line=@"deb [arch=iphoneos-arm64e] https://example.com/repo stable main\n";
    CHECK([[DOSourceMigration sanitizedSourceText:line deb822:NO error:&e] isEqualToString:line]);
    CHECK([[DOSourceMigration sanitizedSourceText:@"deb https://apt.002599.xyz.evil/ ./\n" deb822:NO error:&e] containsString:@".evil"]);
    CHECK(![[DOSourceMigration sanitizedSourceText:@"deb HTTPS://APT.002599.XYZ:443/path ./\n" deb822:NO error:&e] containsString:@"APT.002599"]);
    CHECK([DOSourceMigration sanitizedSourceText:@"garbage\n" deb822:NO error:&e]==nil);
    CHECK([DOSourceMigration sanitizedSourceText:@"deb file:///private/ ./\n" deb822:NO error:&e]==nil);
    NSString *multi=@"# Keep me\nTypes: deb\nURIs: https://apt.002599.xyz/\n https://example.com/repo\nSuites: ./\nComponents:\nSigned-By: /etc/apt/keyrings/example.gpg\n\n";
    NSString *clean=[DOSourceMigration sanitizedSourceText:multi deb822:YES error:&e];
    CHECK(clean && ![clean containsString:@"apt.002599.xyz"] && [clean containsString:@"https://example.com/repo"] && [clean containsString:@"Signed-By:"]);
    CHECK([[DOSourceMigration sanitizedSourceText:clean deb822:YES error:&e] isEqualToString:clean]);
    CHECK([DOSourceMigration sanitizedSourceText:@"Types: deb\nURIs: https://example.com\nURIs: https://other.com\nSuites: ./\n" deb822:YES error:&e]==nil);
    CHECK([DOSourceMigration sanitizedSourceText:@"Types: deb\nURIs: https://example.com\n" deb822:YES error:&e]==nil);
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:[@"dopamine-source-test-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    NSString *apt=[root stringByAppendingPathComponent:@"etc/apt/sources.list.d"];
    NSString *a=[apt stringByAppendingPathComponent:@"default.sources"];
    NSString *b=[apt stringByAppendingPathComponent:@"user.list"];
    NSString *z=[root stringByAppendingPathComponent:@"var/mobile/Library/Application Support/xyz.willy.Zebra/sources.list"];
    Put(a,@"Types: deb\nURIs: https://apt.002599.xyz/ https://keep.example/\nSuites: ./\nComponents:\n");
    Put(b,line); Put(z,[old stringByAppendingString:line]);
    e=nil; CHECK([DOSourceMigration migrateSourcesAtRoot:root error:&e]);
    CHECK(![Read(a) containsString:@"apt.002599.xyz"] && [Read(a) containsString:@"keep.example"]);
    CHECK([Read(b) isEqualToString:line]);
    CHECK([Read([apt stringByAppendingPathComponent:@"wm0104-custom.sources"]) containsString:@"https://wm0104.github.io/repo/"]);
    CHECK(![Read(z) containsString:@"apt.002599.xyz"] && [Read(z) containsString:@"wm0104.github.io/repo"]);
    NSString *own=[apt stringByAppendingPathComponent:@"wm0104-custom.sources"];
    CHECK([NSFileManager.defaultManager removeItemAtPath:own error:nil]);
    CHECK([DOSourceMigration migrateSourcesAtRoot:root error:&e]);
    CHECK(![NSFileManager.defaultManager fileExistsAtPath:own]); // User removal is respected after migration.
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
    Put(a,@"Types: deb\nURIs: https://apt.002599.xyz/\nSuites: ./\nComponents:\n");
    Put(b,@"not a valid source"); NSString *before=Read(a);
    e=nil; CHECK(![DOSourceMigration migrateSourcesAtRoot:root error:&e]);
    CHECK([Read(a) isEqualToString:before]); // Preflight failure cannot partially rewrite sources.
    CHECK([NSFileManager.defaultManager removeItemAtPath:b error:nil]);
    CHECK(symlink(a.fileSystemRepresentation,b.fileSystemRepresentation)==0);
    e=nil; CHECK(![DOSourceMigration migrateSourcesAtRoot:root error:&e]);
    CHECK([Read(a) isEqualToString:before]);
    CHECK([NSFileManager.defaultManager removeItemAtPath:root error:nil]);
    printf("Source migration: %lu checks passed\n",(unsigned long)checks);
} return 0; }
