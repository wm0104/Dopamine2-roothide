//
//  NSString+Version.h
//  Dopamine
//
//  Created by Lars Fröder on 12.06.24.
//

#import <Foundation/Foundation.h>

@implementation NSString (Version)

+ (NSString *)environmentVersionFromInfoDictionary:(NSDictionary *)info
{
    // The RootHide environment version is a separate build input. Parsing the last
    // "-" component of CFBundleShortVersionString breaks once a custom revision
    // such as "3.0.12-29-wm0104.1" is appended.
    NSString *environmentVersion = info[@"DORootHideVersion"];
    if ([environmentVersion isKindOfClass:[NSString class]] && environmentVersion.length) return environmentVersion;
    NSString *bundleVersion = info[@"CFBundleShortVersionString"];
    if (![bundleVersion isKindOfClass:[NSString class]] || !bundleVersion.length) return nil;
    return [bundleVersion componentsSeparatedByString:@"-"].lastObject;
}

- (NSInteger)numericalVersionRepresentation
{
    NSInteger numericalRepresentation = 0;

    NSArray *components = [self componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]];
    
    components = [components filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"SELF != ''"]];
    // A version with more than three numeric groups is truncated instead of crashing.
    if (components.count > 3) components = [components subarrayWithRange:NSMakeRange(0, 3)];

    while (components.count < 3)
        components = [components arrayByAddingObject:@"0"];

    numericalRepresentation |= [components[0] integerValue] << 16;
    numericalRepresentation |= [components[1] integerValue] << 8;
    numericalRepresentation |= [components[2] integerValue];
    return numericalRepresentation;
}

@end
