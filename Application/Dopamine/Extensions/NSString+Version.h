//
//  NSString+Version.h
//  Dopamine
//
//  Created by Lars Fröder on 12.06.24.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSString (Version)

/// RootHide environment version carried by a bundle's Info.plist, independent of
/// any custom revision suffix in CFBundleShortVersionString. Nil when unknown.
+ (nullable NSString *)environmentVersionFromInfoDictionary:(NSDictionary *)info;
- (NSInteger)numericalVersionRepresentation;

@end

NS_ASSUME_NONNULL_END
