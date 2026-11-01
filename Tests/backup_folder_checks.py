"""Portable contract guards; filesystem behavior is exercised by backup_tests.m on macOS."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ENGINE = (ROOT / "Application/Dopamine/Backup/DOConfigurationBackupManager.m").read_text()
UI = (ROOT / "Application/Dopamine/Backup/DOBackupController.m").read_text()


class FolderBackupGuards(unittest.TestCase):
    def test_exact_folder_scope(self):
        for folder in ("Preferences", "ControlCenter", "CallAssist", "RootHide", "CallAssistActivation", "Snapper3"):
            self.assertIn(f'@"config/{folder}"', ENGINE)
        self.assertIn('@"sources/sources.list.d"', ENGINE)

    def test_no_content_filtering_or_source_merging(self):
        for obsolete in ("BPreferenceName", "BSecret", "BSourceUnits", "sourceKey:", "imported-%@", "sanitizedSourceText:"):
            self.assertNotIn(obsolete, ENGINE)

    def test_complete_folder_format(self):
        self.assertIn('@"version":@2', ENGINE)
        self.assertIn('@"directories"', ENGINE)
        self.assertIn('@"metadata"', ENGINE)
        self.assertIn("Folder backups require version 2", ENGINE)

    def test_replacement_retains_rollback(self):
        self.assertIn("renameat(", ENGINE)
        self.assertIn('@".restore-', ENGINE)
        self.assertIn('@"installed"', ENGINE)
        self.assertIn("reverseObjectEnumerator", ENGINE)
        self.assertIn("writeSnapshot:snapshot", ENGINE)
        self.assertIn("Destination changed after safety backup", ENGINE)

    def test_ui_describes_directory_replacement(self):
        self.assertIn("整目录替换", UI)
        self.assertIn("备份中没有的现有文件", UI)
        self.assertNotIn("只恢复勾选的内容，覆盖对应配置", UI)


if __name__ == "__main__":
    unittest.main()
