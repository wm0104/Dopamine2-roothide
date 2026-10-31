#!/usr/bin/env python3
"""Portable source guards; run UIKit compilation/device scenarios in Apple CI."""
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
HEADER = (ROOT / "Application/Dopamine/Backup/DOBackupController.h").read_text()
SOURCE = (ROOT / "Application/Dopamine/Backup/DOBackupController.m").read_text()


class BackupUIGuards(unittest.TestCase):
    def test_original_settings_components(self):
        self.assertIn("DOBackupController : DOPSListController", HEADER)
        for token in ("DOButtonCell.class", "DOHeaderCell.class", "PSSwitchCell", "PSButtonCell"):
            self.assertIn(token, SOURCE)
        self.assertNotIn("UITableViewStyleInsetGrouped", SOURCE)
        settings = (ROOT / "Application/Dopamine/UI/Settings/DOSettingsController.m").read_text()
        self.assertIn("pushViewController:[[DOBackupController alloc] init] animated:YES", settings)
        self.assertNotIn("pushViewController:", SOURCE)
        self.assertNotIn("setNavigationControllerDelegate", SOURCE)

    def test_row_summary_shows_manifest_time_not_raw_name(self):
        title = SOURCE.split("- (NSString *)summaryTitle:", 1)[1].split("- (id)scopeValue:", 1)[0]
        self.assertIn('summary[@"created"]', title)
        self.assertIn('summary[@"files"]', title)
        self.assertIn('summary[@"size"]', title)
        self.assertNotIn("lastPathComponent", title)

    def test_two_primary_actions_and_inline_restore(self):
        specifiers = SOURCE.split("- (NSArray *)specifiers", 1)[1].split("- (id)scopeValue:", 1)[0]
        self.assertEqual(specifiers.count("[self button:"), 2)
        self.assertIn('action:@"createPressed:"', specifiers)
        self.assertIn('action:@"browsePressed:"', specifiers)
        self.assertIn('more.buttonAction = @selector(morePressed:)', specifiers)
        picker = SOURCE.split("- (void)chooseDirectoryForRestore:", 1)[1].split("- (void)documentPickerWasCancelled:", 1)[0]
        self.assertIn("UIDocumentPickerViewController", picker)
        self.assertNotIn("UIAlertController", picker)
        listing = SOURCE.split("- (void)showBackups:", 1)[1].split("- (void)browsePressed:", 1)[0]
        self.assertIn("self.backupFiles =", listing)
        self.assertIn("[self refresh]", listing)
        self.assertNotIn("pushViewController", listing)
        selected = SOURCE.split("- (void)backupPressed:", 1)[1].split("- (void)confirmRestore:", 1)[0]
        self.assertIn("[self confirmRestore:url]", selected)
        self.assertNotIn("UIAlertController", selected)

    def test_first_backup_continues_only_after_explicit_request(self):
        create = SOURCE.split("- (void)createPressed:", 1)[1].split("- (void)backupPressed:", 1)[0]
        self.assertIn("self.backupAfterChoosing = YES", create)
        self.assertIn("[self chooseDirectoryForRestore:NO]", create)
        accept = SOURCE.split("- (void)acceptDirectory:(NSURL *)url restore:(BOOL)restore local:", 1)[1].split("- (void)clearRestoreList", 1)[0]
        self.assertIn("self.backupAfterChoosing && !restore", accept)
        self.assertIn("if (createAfterSelection) [self createPressed:nil]", accept)
        cancel = SOURCE.split("- (void)documentPickerWasCancelled:", 1)[1].split("- (void)documentPicker:", 1)[0]
        self.assertIn("self.backupAfterChoosing = NO", cancel)
        load = SOURCE.split("- (void)loadStoredDirectory", 1)[1].split("- (void)anchorPopover:", 1)[0]
        self.assertNotIn("createPressed:", load)

    def test_optional_sharing_waits_for_alert_dismissal(self):
        self.assertIn("dismissViewControllerAnimated:YES completion:^{ [self shareURL:result directory:directory]", SOURCE)
        self.assertIn("dismissViewControllerAnimated:YES completion:^{ [self shareURL:url directory:self.restoreDirectory]", SOURCE)
        scope = SOURCE.split("- (void)clearRestoreList", 1)[1].split("- (void)showBackups:", 1)[0]
        self.assertIn("stopAccessingSecurityScopedResource", scope)
        self.assertIn("self.restoreScopeHeld = NO", scope)

    def test_empty_refresh_replaces_stale_rows_and_share_ignores_restore_scope(self):
        listing = SOURCE.split("- (void)showBackups:", 1)[1].split("- (void)browsePressed:", 1)[0]
        self.assertLess(listing.index("self.backupFiles ="), listing.index("if (!files.count)"))
        confirm = SOURCE.split("- (void)confirmRestore:", 1)[1].split("- (void)shareURL:", 1)[0]
        self.assertIn("restoreAction.enabled = preferences || sources", confirm)
        self.assertIn('BT(@"Backup_Share",', confirm)
        early_scope = confirm.split("NSMutableArray *scope", 1)[0]
        self.assertNotIn("if (!preferences && !sources)", early_scope)

    def test_added_copy_has_no_parenthetical_labels(self):
        translations = re.findall(r'BT\(@"([^"\n]+)", @"([^"\n]*)", @"([^"\n]*)"\)', SOURCE)
        for key, zh, en in translations:
            self.assertNotRegex(zh, r'[()（）]', key)
            self.assertNotRegex(en, r'[()（）]', key)
        for key, zh, en in (
            ("Backup_Share", "分享备份", "Share Backup"),
            ("Backup_Respring", "现在注销", "Respring Now"),
            ("Backup_LocalPath", "本地绝对路径", "Local Absolute Path"),
        ):
            self.assertIn((key, zh, en), translations)
        self.assertIn("请妥善保管，不要公开分享。", SOURCE)
        self.assertIn("请仅恢复可信的备份。继续？", SOURCE)

    def test_folder_selection_and_ios_bookmarks(self):
        self.assertIn("initForOpeningContentTypes:@[UTTypeFolder] asCopy:NO", SOURCE)
        self.assertIn("bookmarkDataWithOptions:0", SOURCE)
        self.assertIn("bookmarkDataIsStale:&stale", SOURCE)
        self.assertIn("if (!url || stale)", SOURCE)
        self.assertNotIn("NSURLBookmarkCreationWithSecurityScope", SOURCE)
        self.assertNotIn("NSURLBookmarkResolutionWithSecurityScope", SOURCE)
        self.assertIn("removeObjectForKey:BookmarkKey", SOURCE)
        self.assertNotIn("createDirectoryAt", SOURCE)

    def test_worker_and_scope_lifetime(self):
        self.assertIn("DISPATCH_QUEUE_SERIAL", SOURCE)
        self.assertIn("dispatch_async(BackupUIQueue()", SOURCE)
        self.assertIn("dispatch_async(dispatch_get_main_queue()", SOURCE)
        self.assertIn("@finally { if (scoped) [url stopAccessingSecurityScopedResource]; }", SOURCE)
        self.assertIn("if (_restoreScopeHeld) [_restoreDirectory stopAccessingSecurityScopedResource]", SOURCE)
        self.assertIn("DOBackupShareAccess", SOURCE)
        self.assertIn("- (void)dealloc { [self finish]; }", SOURCE)

    def test_restore_separate_and_confirmed(self):
        segment = SOURCE.split("- (void)confirmRestore:", 1)[1].split("- (void)shareURL:", 1)[0]
        self.assertIn("if (!preferences && !sources)", segment)
        self.assertIn("UIAlertActionStyleDestructive handler:", segment)
        self.assertIn("restorePreferences:preferences restoreSources:sources", segment)
        self.assertLess(segment.index("UIAlertActionStyleDestructive"), segment.index("restoreBackupAtURL:"))
        choose = SOURCE.split("if (restore) {", 2)[2].split("- (void)showBackups:", 1)[0]
        self.assertIn("showBackups:", choose)
        self.assertIn("} else {", choose)
        self.assertIn("setObject:result[@\"bookmark\"]", choose)

    def test_busy_blocks_original_outside_tap(self):
        for token in ("nav.view.userInteractionEnabled = NO", "nav.interactivePopGestureRecognizer.enabled = NO",
                      "nav.modalInPresentation = YES", "self.lockedNavigation = nil", "if (![self canPresent]) return"):
            self.assertIn(token, SOURCE)
        self.assertGreaterEqual(SOURCE.count("isJailbroken"), 3)
        self.assertEqual(SOURCE.count("] respring]"), 1)
        respring = SOURCE.split("- (void)offerRespring", 1)[1]
        self.assertLess(respring.index("handler:"), respring.index("] respring]"))

    def test_expanded_configuration_scope(self):
        self.assertIn('BT(@"Backup_Preferences", @"配置文件", @"Configuration Files")', SOURCE)
        for text in ('控制中心布局', 'CallAssist', 'Snapper3', '授权可能绑定设备', '不能保证跨设备使用'):
            self.assertIn(text, SOURCE)
        self.assertNotIn('@"偏好设置"', SOURCE)

    def test_retention_only_after_publish_and_confirmed_once(self):
        create = SOURCE.split("- (void)createPressed:", 1)[1].split("- (void)backupPressed:", 1)[0]
        self.assertLess(create.index("createBackupInDirectory:directory error:error"), create.index("retentionPlanInDirectory:directory"))
        self.assertIn("applyRetentionInDirectory:directory confirmed:NO", create)
        self.assertIn("needsConfirmation", create)
        self.assertEqual(SOURCE.count("[self confirmRetention:value"), 1)
        apply = SOURCE.split("- (void)deleteRetainedBackups:", 1)[1].split("- (void)presentBackupComplete:", 1)[0]
        self.assertIn("applyRetentionInDirectory:directory confirmed:YES", apply)
        self.assertIn("此确认只出现一次", SOURCE)
        self.assertIn("只删除本应用创建的备份文件夹", SOURCE)
        restore = SOURCE.split("restoreBackupAtURL:url restorePreferences:", 1)[1]
        self.assertIn("retentionPlanInDirectory:self.restoreDirectory", restore)

    def test_backup_message_reports_not_included(self):
        complete = SOURCE.split("- (void)presentBackupComplete:", 1)[1].split("- (void)backupPressed:", 1)[0]
        self.assertIn('BT(@"Backup_NotIncluded", @"未纳入", @"Not included")', complete)
        self.assertIn('snapshot[@"skippedCount"]', complete)
        self.assertIn('BT(@"Backup_Included"', complete)

    def test_rows_show_time_files_and_size(self):
        specifiers = SOURCE.split("- (NSArray *)specifiers", 1)[1].split("- (id)scopeValue:", 1)[0]
        self.assertIn("[self summaryTitle:summary]", specifiers)
        self.assertNotIn("preferenceSpecifierNamed:url.lastPathComponent", specifiers)
        title = SOURCE.split("- (NSString *)summaryTitle:", 1)[1].split("- (id)scopeValue:", 1)[0]
        for token in ('BTimeText(summary[@"created"])', 'BT(@"Backup_RowFiles"', 'BSizeText(bytes.unsignedLongLongValue)'):
            self.assertIn(token, title)
        self.assertIn(" · ", title)

    def test_new_ui_reuses_original_cells_and_appearance(self):
        # No custom cells, colors, fonts or layout: reuse the stock classes only.
        for token in ("UIColor", "UIFont", "UILabel", "UITableViewCell", "UIStackView", "cornerRadius", "backgroundColor"):
            self.assertNotIn(token, SOURCE)
        self.assertEqual(SOURCE.count('forKey:@"cellClass"'), 1)
        self.assertIn('setProperty:DOButtonCell.class forKey:@"cellClass"', SOURCE)
        self.assertIn('NSStringFromClass(DOHeaderCell.class) forKey:@"headerCellClass"', SOURCE)
        rows = SOURCE.split("if (self.restoreDirectory) {", 1)[1].split('[items addObject:[self group:BT(@"Backup_RestoreScope"', 1)[0]
        self.assertIn("cell:PSButtonCell", rows)
        for token in ("height", "image", "cellClass"):
            self.assertNotIn(token, rows)
        self.assertIn('forKey:@"backupURL"', rows)

    def test_restore_preview_shows_counts_not_contents(self):
        segment = SOURCE.split("- (void)presentRestoreConfirmation:", 1)[1].split("- (void)shareURL:", 1)[0]
        for key in ("Backup_Time", "Backup_FileCount", "Backup_Size", "Backup_NotIncluded"):
            self.assertIn(key, segment)
        self.assertIn("summaryForBackupAtURL:url error:error", SOURCE)
        self.assertNotIn("for (NSString *path in", segment)
        self.assertIn("url.lastPathComponent", segment)  # only the backup itself is named


        self.assertIn("realpath(url.fileSystemRepresentation", SOURCE)
        self.assertIn('@"/private/var/mobile/Documents/"', SOURCE)
        self.assertIn("validateStorageDirectory:directory", SOURCE)
        keys = re.findall(r'BT\(@"([^"\n]+)", @"([^"\n]*)", @"([^"\n]*)"\)', SOURCE)
        self.assertGreater(len(keys), 35)
        translations = {}
        for key, zh, en in keys:
            self.assertTrue(zh and en)
            self.assertEqual(translations.setdefault(key, (zh, en)), (zh, en), key)


if __name__ == "__main__":
    unittest.main()
