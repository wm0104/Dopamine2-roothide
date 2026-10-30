#import <Foundation/Foundation.h>
#if defined(DO_BACKUP_TESTING) && !DEBUG
#error DO_BACKUP_TESTING requires a DEBUG test build
#endif

NS_ASSUME_NONNULL_BEGIN
/// Synchronous. Call from a background queue; caller owns security-scoped access.
@interface DOConfigurationBackupManager : NSObject
+ (instancetype)sharedManager;
/// Read on the caller's serial queue. Also embedded in manifest.json; never contains config values.
@property(nonatomic, copy, readonly) NSDictionary<NSString *, id> *lastBackupReport;
- (nullable NSURL *)createBackupInDirectory:(NSURL *)directory error:(NSError **)error;
- (BOOL)restoreBackupAtURL:(NSURL *)backupURL restorePreferences:(BOOL)preferences restoreSources:(BOOL)sources error:(NSError **)error;
- (NSArray<NSURL *> *)backupsInDirectory:(NSURL *)directory error:(NSError **)error;
- (BOOL)validateStorageDirectory:(NSURL *)directory error:(NSError **)error;
#ifdef DO_BACKUP_TESTING
/// Test builds only: never linked into the app.
- (instancetype)initWithTestRoot:(NSString *)root;
@property(nonatomic) NSInteger failAfterWrites;
#endif
@end
NS_ASSUME_NONNULL_END
