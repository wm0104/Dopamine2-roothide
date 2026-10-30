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
        self.assertIn("pushViewController:list animated:YES", SOURCE)
        self.assertNotIn("setNavigationControllerDelegate", SOURCE)

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

    def test_local_path_and_bilingual_keys(self):
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
