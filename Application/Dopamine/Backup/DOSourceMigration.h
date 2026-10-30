#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface DOSourceMigration : NSObject
+ (nullable NSString *)sanitizedSourceText:(NSString *)text deb822:(BOOL)deb822 error:(NSError **)error;
// Called with the active JBROOT and root privileges. Runs once, never enforces sources on every boot.
+ (BOOL)migrateSourcesAtRoot:(NSString *)root error:(NSError **)error;
@end
NS_ASSUME_NONNULL_END
