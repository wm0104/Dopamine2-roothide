#import "DOBackupController.h"
#import "DOConfigurationBackupManager.h"
#import "DOEnvironmentManager.h"
#import "DOButtonCell.h"
#import "DOHeaderCell.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <stdlib.h>

// The existing settings cells/appearance/transitions remain authoritative.
// No localization resources are changed; keys can be added to Localizable.strings later.
static NSString *BT(NSString *key, NSString *zh, NSString *en) {
    NSString *localized = [[NSBundle mainBundle] localizedStringForKey:key value:@"" table:nil];
    if (localized.length && ![localized isEqualToString:key]) return localized;
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"zh"] ? zh : en;
}
static NSString * const BookmarkKey = @"DOConfigurationBackup.StorageBookmark.v1";
static NSError *BUIError(NSString *message) {
    return [NSError errorWithDomain:@"DOBackupUI" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}
static dispatch_queue_t BackupUIQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.opa334.Dopamine.backup-ui", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

// A share sheet can be dismissed by its presenter; deallocation is a safety net.
@interface DOBackupShareAccess : NSObject
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) BOOL held;
- (void)finish;
@end
@implementation DOBackupShareAccess
- (void)finish { if (_held) { [_url stopAccessingSecurityScopedResource]; _held = NO; } }
- (void)dealloc { [self finish]; }
@end

@interface DOBackupController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) NSURL *storageDirectory;
@property(nonatomic, strong) NSURL *restoreDirectory;
@property(nonatomic, copy) NSArray<NSURL *> *backupFiles;
@property(nonatomic) BOOL restoreScopeHeld;
@property(nonatomic) BOOL preferences;
@property(nonatomic) BOOL sources;
@property(nonatomic) BOOL choosingRestore;
@property(nonatomic) BOOL backupAfterChoosing;
@property(nonatomic) BOOL busy;
@property(nonatomic, strong) UINavigationController *lockedNavigation;
@property(nonatomic) BOOL previousNavigationInteraction;
@property(nonatomic) BOOL previousPopEnabled;
@property(nonatomic) BOOL previousModalLock;
@property(nonatomic) BOOL previousNavigationModalLock;
@property(nonatomic, copy) NSString *statusText;
@property(nonatomic, strong) UIActivityIndicatorView *spinner;
@end

@implementation DOBackupController

- (instancetype)init {
    if ((self = [super init])) { _preferences = YES; _sources = YES; }
    return self;
}

- (void)dealloc {
    if (_restoreScopeHeld) [_restoreDirectory stopAccessingSecurityScopedResource];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = BT(@"Backup_Title", @"配置备份与恢复", @"Configuration Backup & Restore");
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.spinner.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.spinner];
    [NSLayoutConstraint activateConstraints:@[
        [self.spinner.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24],
        [self.spinner.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:20]
    ]];
    [self loadStoredDirectory];
}

- (BOOL)canPresent {
    return self.isViewLoaded && self.view.window && !self.presentedViewController &&
        (!self.navigationController || self.navigationController.topViewController == self);
}

- (void)refresh {
    _specifiers = nil;
    if (self.isViewLoaded) [self reloadSpecifiers];
}

- (PSSpecifier *)group:(NSString *)title footer:(NSString *)footer {
    PSSpecifier *group = [PSSpecifier emptyGroupSpecifier];
    if (title.length) {
        [group setProperty:NSStringFromClass(DOHeaderCell.class) forKey:@"headerCellClass"];
        [group setProperty:title forKey:@"title"];
    }
    if (footer.length) [group setProperty:footer forKey:@"footerText"];
    return group;
}

- (PSSpecifier *)button:(NSString *)title image:(NSString *)image action:(NSString *)action {
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"" target:self set:NULL get:NULL detail:nil cell:PSStaticTextCell edit:nil];
    [specifier setProperty:DOButtonCell.class forKey:@"cellClass"];
    [specifier setProperty:@44 forKey:@"height"];
    [specifier setProperty:title forKey:@"title"];
    [specifier setProperty:image forKey:@"image"];
    [specifier setProperty:action forKey:@"action"];
    return specifier;
}

- (NSArray *)specifiers {
    if (_specifiers) return _specifiers;
    NSMutableArray *items = [NSMutableArray array];
    NSString *privacy = BT(@"Backup_Privacy", @"仅备份配置，不安装或恢复插件。包含控制中心布局及 CallAssist、Snapper3 授权文件，授权可能绑定设备，不能保证跨设备使用。配置可能包含账户、令牌等私人信息，请妥善保管，不要公开分享。", @"Configuration only: this does not install or restore tweaks. Includes Control Center layout and CallAssist and Snapper3 licenses. Licenses may be device-specific; portability is not guaranteed. Configuration may contain accounts, tokens and other private data. Keep backups private.");
    NSString *location = self.storageDirectory.path;
    [items addObject:[self group:self.title ?: BT(@"Backup_Title", @"配置备份与恢复", @"Configuration Backup & Restore") footer:privacy]];
    [items addObject:[self group:BT(@"Backup_Location", @"备份位置", @"Backup Folder") footer:location ?: BT(@"Backup_NoFolder", @"首次备份时选择保存目录，之后自动记住。", @"Choose a folder for the first backup; it will be remembered.")]];
    [items addObject:[self button:BT(@"Backup_Create", @"备份配置", @"Back Up Configuration") image:@"archivebox" action:@"createPressed:"]];
    [items addObject:[self button:BT(@"Backup_BrowseSaved", @"恢复配置", @"Restore Configuration") image:@"clock.arrow.circlepath" action:@"browsePressed:"]];
    if (self.restoreDirectory) {
        [items addObject:[self group:BT(@"Backup_Files", @"选择备份", @"Choose Backup") footer:self.restoreDirectory.path]];
        for (NSURL *url in self.backupFiles) {
            PSSpecifier *file = [PSSpecifier preferenceSpecifierNamed:url.lastPathComponent target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
            file.buttonAction = @selector(backupPressed:);
            [file setProperty:url forKey:@"backupURL"];
            [items addObject:file];
        }
    }
    [items addObject:[self group:BT(@"Backup_RestoreScope", @"恢复内容", @"Restore Contents") footer:BT(@"Backup_ScopeHint", @"只恢复勾选的内容，覆盖对应配置。关闭的项目保持不变。操作仅在已越狱环境中可用，不会自动执行或自动注销。", @"Selected contents overwrite matching configuration; unselected contents stay unchanged. Requires an active jailbreak. Nothing runs or resprings automatically.")]];
    for (NSString *key in @[@"preferences", @"sources"]) {
        NSString *title = [key isEqualToString:@"preferences"] ? BT(@"Backup_Preferences", @"配置文件", @"Configuration Files") : BT(@"Backup_Sources", @"软件源", @"Package Sources");
        PSSpecifier *toggle = [PSSpecifier preferenceSpecifierNamed:title target:self set:@selector(setScope:specifier:) get:@selector(scopeValue:) detail:nil cell:PSSwitchCell edit:nil];
        [toggle setProperty:key forKey:@"key"];
        [items addObject:toggle];
    }
    PSSpecifier *more = [PSSpecifier preferenceSpecifierNamed:BT(@"Backup_More", @"更多选项", @"More Options") target:self set:NULL get:NULL detail:nil cell:PSButtonCell edit:nil];
    more.buttonAction = @selector(morePressed:);
    [items addObject:more];
    [items addObject:[self group:BT(@"Backup_Status", @"操作结果", @"Status") footer:self.statusText ?: BT(@"Backup_Ready", @"等待手动操作。", @"Waiting for a manual action.")]];
    _specifiers = items;
    return _specifiers;
}

- (id)scopeValue:(PSSpecifier *)specifier {
    return [[specifier propertyForKey:@"key"] isEqualToString:@"preferences"] ? @(self.preferences) : @(self.sources);
}
- (void)setScope:(NSNumber *)value specifier:(PSSpecifier *)specifier {
    if (self.busy) return;
    if ([[specifier propertyForKey:@"key"] isEqualToString:@"preferences"]) self.preferences = value.boolValue;
    else self.sources = value.boolValue;
}

- (void)setOperationBusy:(BOOL)busy {
    self.busy = busy;
    UINavigationController *nav = busy ? self.navigationController : self.lockedNavigation;
    if (busy) {
        self.lockedNavigation = nav;
        self.previousNavigationInteraction = nav.view.userInteractionEnabled;
        self.previousPopEnabled = nav.interactivePopGestureRecognizer.enabled;
        self.previousModalLock = self.modalInPresentation;
        self.previousNavigationModalLock = nav.modalInPresentation;
        // Includes DONavigationController's outside-tap DOModalBackAction.
        nav.view.userInteractionEnabled = NO;
        nav.interactivePopGestureRecognizer.enabled = NO;
        self.modalInPresentation = YES;
        nav.modalInPresentation = YES;
        self.view.userInteractionEnabled = NO;
        [self.spinner startAnimating];
    } else {
        nav.view.userInteractionEnabled = self.previousNavigationInteraction;
        nav.interactivePopGestureRecognizer.enabled = self.previousPopEnabled;
        nav.modalInPresentation = self.previousNavigationModalLock;
        self.modalInPresentation = self.previousModalLock;
        self.view.userInteractionEnabled = YES;
        [self.spinner stopAnimating];
        self.lockedNavigation = nil;
    }
}

// Work owns its scope until ALL synchronous manager/file work finishes.
- (void)performAtURL:(NSURL *)url work:(id (^)(NSError **error))work completion:(void (^)(id result, NSError *error))completion {
    if (self.busy) return;
    self.statusText = BT(@"Backup_Working", @"正在处理，请勿关闭应用…", @"Working. Please keep the app open…");
    [self refresh];
    [self setOperationBusy:YES];
    dispatch_async(BackupUIQueue(), ^{
        BOOL scoped = [url startAccessingSecurityScopedResource];
        NSError *error = nil;
        id result = nil;
        @try { result = work(&error); }
        @catch (NSException *exception) { error = BUIError(exception.reason ?: @"Operation failed"); }
        @finally { if (scoped) [url stopAccessingSecurityScopedResource]; }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setOperationBusy:NO];
            completion(result, error);
            [self refresh];
        });
    });
}

- (void)showError:(NSError *)error {
    self.statusText = error.localizedDescription ?: BT(@"Backup_Failed", @"操作失败。请检查目录权限和备份文件。", @"Operation failed. Check folder permission and backup files.");
    [self refresh];
    if (![self canPresent]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BT(@"Backup_Error", @"操作失败", @"Operation Failed") message:self.statusText preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_OK", @"好", @"OK") style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)requireJailbreak {
    if (self.busy) return NO;
    if ([DOEnvironmentManager sharedManager].isJailbroken) return YES;
    [self showError:BUIError(BT(@"Backup_JailbreakRequired", @"请先完成越狱，再执行备份或恢复。", @"Activate the jailbreak before backing up or restoring."))];
    return NO;
}

- (void)loadStoredDirectory {
    NSData *bookmark = [[NSUserDefaults standardUserDefaults] objectForKey:BookmarkKey];
    if (![bookmark isKindOfClass:NSData.class]) return;
    [self performAtURL:nil work:^id(NSError **error) {
        BOOL stale = NO;
        NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:NSURLBookmarkResolutionWithoutUI relativeToURL:nil bookmarkDataIsStale:&stale error:error];
        if (!url || stale) {
            *error = BUIError(BT(@"Backup_Reselect", @"目录权限已过期或不可用，请重新选择目录；不会改用其他路径。", @"Folder permission is stale or unavailable. Reselect the folder; no other location will be used."));
            return nil;
        }
        BOOL scoped = [url startAccessingSecurityScopedResource];
        @try {
            return [[DOConfigurationBackupManager sharedManager] validateStorageDirectory:url error:error] ? url : nil;
        } @finally {
            if (scoped) [url stopAccessingSecurityScopedResource];
        }
    } completion:^(id result, NSError *error) {
        self.storageDirectory = result;
        if (!result) {
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:BookmarkKey];
            [self showError:error];
        } else self.statusText = BT(@"Backup_FolderReady", @"目录已验证。", @"Folder verified.");
    }];
}

- (void)anchorPopover:(UIViewController *)controller {
    controller.popoverPresentationController.sourceView = self.view;
    controller.popoverPresentationController.sourceRect = CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds), 1, 1);
    controller.popoverPresentationController.permittedArrowDirections = 0;
}

- (void)chooseStoragePressed:(id)sender {
    self.backupAfterChoosing = NO;
    [self chooseDirectoryForRestore:NO];
}
- (void)chooseRestorePressed:(id)sender {
    self.backupAfterChoosing = NO;
    if ([self requireJailbreak]) [self chooseDirectoryForRestore:YES];
}

- (void)morePressed:(id)sender {
    if (self.busy || ![self canPresent]) return;
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:BT(@"Backup_More", @"更多选项", @"More Options") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakSheet = sheet;
    [sheet addAction:[UIAlertAction actionWithTitle:BT(@"Backup_ChooseFolder", @"更换备份目录", @"Change Backup Folder") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSheet dismissViewControllerAnimated:YES completion:^{ [self chooseStoragePressed:nil]; }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:BT(@"Backup_LocalPath", @"本地绝对路径", @"Local Absolute Path") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSheet dismissViewControllerAnimated:YES completion:^{
            self.backupAfterChoosing = NO;
            self.choosingRestore = NO;
            [self askLocalPath];
        }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:BT(@"Backup_RestoreOther", @"从其他目录恢复", @"Restore from Another Folder") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSheet dismissViewControllerAnimated:YES completion:^{ [self chooseRestorePressed:nil]; }];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Cancel", @"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [self anchorPopover:sheet];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)chooseDirectoryForRestore:(BOOL)restore {
    if (self.busy || ![self canPresent]) { self.backupAfterChoosing = NO; return; }
    self.choosingRestore = restore;
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    if (self.storageDirectory) picker.directoryURL = self.storageDirectory;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    self.backupAfterChoosing = NO;
    [controller dismissViewControllerAnimated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    // Wait for the provider UI's dismissal before reporting errors/pushing a list.
    [controller dismissViewControllerAnimated:YES completion:^{
        if (url.isFileURL && !self.busy) [self acceptDirectory:url restore:self.choosingRestore];
        else if (!url.isFileURL) [self showError:BUIError(BT(@"Backup_LocalRequired", @"请选择可访问的文件目录。", @"Choose an accessible file folder."))];
    }];
}

- (void)askLocalPath {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BT(@"Backup_LocalPath", @"本地绝对路径", @"Local Absolute Path") message:BT(@"Backup_PathHint", @"填写已存在的持久目录，仅允许 /var/mobile/Documents 下的子目录。不要填写越狱根目录或系统目录。将验证读写权限。", @"Enter an existing persistent subfolder under /var/mobile/Documents. Do not use the jailbreak root or system folders. Read/write access will be verified.") preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"/var/mobile/Documents/MyBackups";
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.spellCheckingType = UITextSpellCheckingTypeNo;
    }];
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Cancel", @"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_UseFolder", @"使用此目录", @"Use Folder") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = weakAlert.textFields.firstObject.text ?: @"";
        if (![path hasPrefix:@"/"]) { [self showError:BUIError(BT(@"Backup_AbsoluteRequired", @"必须填写绝对路径。", @"An absolute path is required."))]; return; }
        // Canonicalization and provider I/O belong to the worker, not UIKit.
        [self acceptDirectory:[NSURL fileURLWithPath:path isDirectory:YES] restore:self.choosingRestore local:YES];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_RestoreHere", @"从此目录恢复", @"Restore from This Folder") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *path = weakAlert.textFields.firstObject.text ?: @"";
        if (![path hasPrefix:@"/"]) { [self showError:BUIError(BT(@"Backup_AbsoluteRequired", @"必须填写绝对路径。", @"An absolute path is required."))]; return; }
        [self acceptDirectory:[NSURL fileURLWithPath:path isDirectory:YES] restore:YES local:YES];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)acceptDirectory:(NSURL *)url restore:(BOOL)restore {
    [self acceptDirectory:url restore:restore local:NO];
}

- (void)acceptDirectory:(NSURL *)url restore:(BOOL)restore local:(BOOL)local {
    BOOL createAfterSelection = self.backupAfterChoosing && !restore;
    self.backupAfterChoosing = NO;
    [self performAtURL:url work:^id(NSError **error) {
        NSURL *directory = url;
        if (local) {
            char *resolved = realpath(url.fileSystemRepresentation, NULL);
            NSString *path = resolved ? [NSString stringWithUTF8String:resolved] : nil;
            free(resolved);
            BOOL allowed = NO;
            for (NSString *base in @[@"/var/mobile/Documents/", @"/private/var/mobile/Documents/"]) {
                if ([path hasPrefix:base]) allowed = YES;
            }
            if (!allowed) {
                *error = BUIError(BT(@"Backup_UnsafePath", @"请选择 Documents 内已存在的子目录；系统目录、越狱根目录及不可用路径不被接受。", @"Choose an existing subfolder of Documents. System, jailbreak-root and unavailable paths are not accepted."));
                return nil;
            }
            directory = [NSURL fileURLWithPath:path isDirectory:YES];
        }
        // A false startAccessing result is normal for direct local URLs. Validation
        // (including the engine's write/unlink probe), not that BOOL, decides access.
        if (![[DOConfigurationBackupManager sharedManager] validateStorageDirectory:directory error:error]) return nil;
        if (restore) {
            NSArray *files = [[DOConfigurationBackupManager sharedManager] backupsInDirectory:directory error:error];
            return files && !*error ? @{@"directory":directory, @"files":files} : nil;
        }
        // iOS accepts options:0; macOS-only security-scope bookmark flags are NOT used.
        NSData *bookmark = [directory bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:error];
        return bookmark ? @{@"directory":directory, @"bookmark":bookmark} : nil;
    } completion:^(id result, NSError *error) {
        if (!result) {
            if ([url isEqual:self.storageDirectory]) {
                self.storageDirectory = nil;
                [[NSUserDefaults standardUserDefaults] removeObjectForKey:BookmarkKey];
            }
            [self showError:error];
            return;
        }
        if (restore) {
            [self showBackups:result[@"files"] directory:result[@"directory"]];
        } else {
            [self clearRestoreList];
            self.storageDirectory = result[@"directory"];
            [[NSUserDefaults standardUserDefaults] setObject:result[@"bookmark"] forKey:BookmarkKey];
            self.statusText = BT(@"Backup_FolderReady", @"目录已验证。", @"Folder verified.");
            if (createAfterSelection) [self createPressed:nil];
        }
    }];
}

- (void)clearRestoreList {
    if (self.restoreScopeHeld) [self.restoreDirectory stopAccessingSecurityScopedResource];
    self.restoreScopeHeld = NO;
    self.restoreDirectory = nil;
    self.backupFiles = nil;
}

- (void)showBackups:(NSArray<NSURL *> *)files directory:(NSURL *)directory {
    if (![directory isEqual:self.restoreDirectory]) {
        BOOL scoped = [directory startAccessingSecurityScopedResource];
        [self clearRestoreList];
        self.restoreDirectory = directory;
        self.restoreScopeHeld = scoped;
    }
    self.backupFiles = [[files reverseObjectEnumerator] allObjects];
    [self refresh];
    if (!files.count) [self showError:BUIError(BT(@"Backup_Empty", @"此目录没有可识别的备份。请在其他目录查找原有备份。", @"No supported backups in this folder. Choose another folder to find existing backups."))];
}

- (void)browsePressed:(id)sender {
    if (![self requireJailbreak]) return;
    NSURL *directory = self.restoreDirectory ?: self.storageDirectory;
    if (!directory) { [self chooseDirectoryForRestore:YES]; return; }
    [self acceptDirectory:directory restore:YES];
}

- (void)createPressed:(id)sender {
    if (![self requireJailbreak]) return;
    NSURL *directory = self.storageDirectory;
    if (!directory) {
        self.backupAfterChoosing = YES;
        [self chooseDirectoryForRestore:NO];
        return;
    }
    [self performAtURL:directory work:^id(NSError **error) {
        if (![DOEnvironmentManager sharedManager].isJailbroken) {
            *error = BUIError(BT(@"Backup_JailbreakRequired", @"请先完成越狱，再执行备份或恢复。", @"Activate the jailbreak before backing up or restoring."));
            return nil;
        }
        if (![[DOConfigurationBackupManager sharedManager] validateStorageDirectory:directory error:error]) return nil;
        return [[DOConfigurationBackupManager sharedManager] createBackupInDirectory:directory error:error];
    } completion:^(id value, NSError *error) {
        NSURL *result = value;
        if (!result) {
            // Never fall back to a hidden location or silently renew stale authority.
            self.storageDirectory = nil;
            [[NSUserDefaults standardUserDefaults] removeObjectForKey:BookmarkKey];
            [self showError:error];
            return;
        }
        NSDictionary *report = DOConfigurationBackupManager.sharedManager.lastBackupReport;
        self.statusText = [NSString stringWithFormat:@"%@\n%@\n%@\n%@ %@ / %@ %@\n%@", BT(@"Backup_Created", @"备份已完成", @"Backup Complete"), result.lastPathComponent, directory.path, BT(@"Backup_Included", @"已包含", @"Included"), report[@"included"] ?: @0, BT(@"Backup_Skipped", @"已跳过", @"Skipped"), report[@"skippedCount"] ?: @0, BT(@"Backup_Report", @"系统、敏感、生成及不支持配置的逐项跳过原因见 manifest.json 的 report。", @"Per-file skip reasons for system, sensitive, generated or unsupported data are in manifest.json report.")];
        if (![self canPresent]) return;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:BT(@"Backup_Created", @"备份已完成", @"Backup Complete") message:self.statusText preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Done", @"完成", @"Done") style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert = alert;
        [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Share", @"分享备份", @"Share Backup") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
            [weakAlert dismissViewControllerAnimated:YES completion:^{ [self shareURL:result directory:directory]; }];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    }];
}

- (void)backupPressed:(PSSpecifier *)specifier {
    if (self.busy || ![self canPresent]) return;
    NSURL *url = [specifier propertyForKey:@"backupURL"];
    if (url) [self confirmRestore:url];
}

- (void)confirmRestore:(NSURL *)url {
    if (![self requireJailbreak]) return;
    BOOL preferences = self.preferences, sources = self.sources;
    NSMutableArray *scope = [NSMutableArray array];
    if (!preferences && !sources) [scope addObject:BT(@"Backup_ChooseScope", @"至少选择一项恢复内容。", @"Select at least one restore category.")];
    if (preferences) [scope addObject:BT(@"Backup_Preferences", @"配置文件", @"Configuration Files")];
    if (sources) [scope addObject:BT(@"Backup_Sources", @"软件源", @"Package Sources")];
    NSString *message = [NSString stringWithFormat:@"%@\n%@\n\n%@\n%@", url.lastPathComponent, url.URLByDeletingLastPathComponent.path, [scope componentsJoinedByString:@", "], BT(@"Backup_OverwriteWarning", @"将覆盖上述现有配置，其余内容不变。不安装插件。请仅恢复可信的备份。继续？", @"This overwrites the existing configuration listed above; other contents stay unchanged. No tweaks are installed. Restore only trusted backups. Continue?")];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BT(@"Backup_ConfirmRestore", @"确认恢复", @"Confirm Restore") message:message preferredStyle:UIAlertControllerStyleAlert];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Share", @"分享备份", @"Share Backup") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakAlert dismissViewControllerAnimated:YES completion:^{ [self shareURL:url directory:self.restoreDirectory]; }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Cancel", @"取消", @"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    UIAlertAction *restoreAction = [UIAlertAction actionWithTitle:BT(@"Backup_Restore", @"恢复所选内容…", @"Restore Selected Contents…") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        if (![self requireJailbreak]) return;
        [self performAtURL:self.restoreDirectory work:^id(NSError **error) {
            if (![DOEnvironmentManager sharedManager].isJailbroken) {
                *error = BUIError(BT(@"Backup_JailbreakRequired", @"请先完成越狱，再执行备份或恢复。", @"Activate the jailbreak before backing up or restoring."));
                return nil;
            }
            return [[DOConfigurationBackupManager sharedManager] restoreBackupAtURL:url restorePreferences:preferences restoreSources:sources error:error] ? @YES : nil;
        } completion:^(id result, NSError *error) {
            if (!result) { [self showError:error]; return; }
            self.statusText = [NSString stringWithFormat:@"%@\n%@\n%@", BT(@"Backup_Restored", @"配置恢复成功，未自动注销。", @"Configuration restored. No automatic respring."), url.lastPathComponent, self.restoreDirectory.path];
            [self offerRespring];
        }];
    }];
    restoreAction.enabled = preferences || sources;
    [alert addAction:restoreAction];
    if ([self canPresent]) [self presentViewController:alert animated:YES completion:nil];
}

- (void)shareURL:(NSURL *)url directory:(NSURL *)directory {
    if (self.busy || ![self canPresent]) return;
    DOBackupShareAccess *access = [DOBackupShareAccess new];
    access.url = directory;
    access.held = [directory startAccessingSecurityScopedResource];
    UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
    // The share extension may read after presentation: retain scope until it finishes.
    activity.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray *items, NSError *error) {
        [access finish];
    };
    [self anchorPopover:activity];
    [self presentViewController:activity animated:YES completion:nil];
}

- (void)offerRespring {
    if (![self canPresent]) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:BT(@"Backup_RestoreComplete", @"恢复完成", @"Restore Complete") message:self.statusText preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Done", @"完成", @"Done") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:BT(@"Backup_Respring", @"现在注销", @"Respring Now") style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (![self requireJailbreak]) return;
        [self performAtURL:nil work:^id(NSError **error) {
            [[DOEnvironmentManager sharedManager] respring];
            return @YES;
        } completion:^(id result, NSError *error) {
            if (error) [self showError:error];
        }];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
