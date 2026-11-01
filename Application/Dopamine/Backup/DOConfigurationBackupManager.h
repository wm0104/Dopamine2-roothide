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
/// Version 2 archives replace saved folders, including empty directories. Version 1 is preview-only.
- (BOOL)restoreBackupAtURL:(NSURL *)backupURL restorePreferences:(BOOL)preferences restoreSources:(BOOL)sources error:(NSError **)error;
- (NSArray<NSURL *> *)backupsInDirectory:(NSURL *)directory error:(NSError **)error;
- (BOOL)validateStorageDirectory:(NSURL *)directory error:(NSError **)error;
/// Read-only. Reports the generated backups beyond the retention limit and whether
/// the one-time confirmation is still pending for this folder.
- (nullable NSDictionary<NSString *, id> *)retentionPlanInDirectory:(NSURL *)directory error:(NSError **)error;
/// Deletes only generated backups beyond the limit. `confirmed` must be YES while the
/// folder still needs its one-time confirmation; afterwards the marker allows silent runs.
- (nullable NSArray<NSURL *> *)applyRetentionInDirectory:(NSURL *)directory confirmed:(BOOL)confirmed error:(NSError **)error;
/// Restore-preview and row metadata. Never returns or lists archived file contents.
- (nullable NSDictionary<NSString *, id> *)summaryForBackupAtURL:(NSURL *)url error:(NSError **)error;
- (NSArray<NSDictionary<NSString *, id> *> *)backupSummariesInDirectory:(NSURL *)directory error:(NSError **)error;
#ifdef DO_BACKUP_TESTING
/// Test builds only: never linked into the app.
- (instancetype)initWithTestRoot:(NSString *)root;
/// Inject failure after this many directory replacements; negative disables injection.
@property(nonatomic) NSInteger failAfterWrites;
#endif
@end
NS_ASSUME_NONNULL_END
