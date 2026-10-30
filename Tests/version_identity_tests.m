#import <Foundation/Foundation.h>
#import "NSString+Version.h"
static NSUInteger checks;
#define CHECK(x) do { checks++; if (!(x)) { fprintf(stderr,"FAIL %d: %s\n",__LINE__,#x); exit(1); } } while(0)

int main(void) { @autoreleasepool {
    NSDictionary *custom = @{@"CFBundleShortVersionString":@"3.0.12-29-wm0104.2", @"DORootHideVersion":@"29"};
    NSDictionary *legacy = @{@"CFBundleShortVersionString":@"3.0.12-29"};
    NSDictionary *malformed = @{@"CFBundleShortVersionString":@"3.0.12"};

    // The reported bug: the custom revision was compared as an environment version.
    NSString *customTag = [NSString environmentVersionFromInfoDictionary:custom];
    CHECK([customTag isEqualToString:@"29"]);
    NSInteger installed = [@"29" numericalVersionRepresentation];
    CHECK(!([customTag numericalVersionRepresentation] > installed)); // no phantom update

    // A genuinely older environment must still be detected.
    CHECK([customTag numericalVersionRepresentation] > [@"28" numericalVersionRepresentation]);
    CHECK([@"29" numericalVersionRepresentation] == [customTag numericalVersionRepresentation]);

    // Older bundles without the explicit key keep the upstream behaviour.
    CHECK([[NSString environmentVersionFromInfoDictionary:legacy] isEqualToString:@"29"]);
    CHECK([[NSString environmentVersionFromInfoDictionary:malformed] isEqualToString:@"3.0.12"]);
    CHECK([NSString environmentVersionFromInfoDictionary:@{}] == nil);
    CHECK([[NSString environmentVersionFromInfoDictionary:@{@"DORootHideVersion":@5, @"CFBundleShortVersionString":@"3.0.12-30"}] isEqualToString:@"30"]);

    // Oversized groups are truncated instead of tripping an assertion.
    CHECK([@"1.2.3.4.5" numericalVersionRepresentation] == [@"1.2.3" numericalVersionRepresentation]);
    CHECK([@"29rc1" numericalVersionRepresentation] == [@"29.1" numericalVersionRepresentation]);
    printf("Environment version identity: %lu checks passed\n", (unsigned long)checks);
} return 0; }
