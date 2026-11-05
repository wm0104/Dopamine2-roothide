"""The upstream port must not overwrite the existing custom backup implementation."""
from pathlib import Path
import hashlib
import json
import unittest

ROOT = Path(__file__).resolve().parents[1]

class CustomPreservationTests(unittest.TestCase):
    def test_backup_restore_sources_and_version_code_are_identical(self):
        manifest = json.loads((ROOT / 'Tests/custom_preservation_manifest.json').read_text())
        self.assertEqual(manifest['baseline'], 'a04b04151b37c54a8be29806b6c5da73fe4eeb00')
        for name, expected in manifest['sha256'].items():
            with self.subTest(path=name):
                self.assertEqual(hashlib.sha256((ROOT / name).read_bytes()).hexdigest(), expected)

    def test_custom_guards_still_run(self):
        import runpy
        runpy.run_path(str(ROOT / 'Tests/custom_checks.py'), run_name='__main__')

    def test_environment_upgrade_is_detectable_without_custom_suffix(self):
        base = ROOT / 'BaseBin/_external/basebin'
        self.assertEqual((base / '.version').read_text().strip(), '3.0.13')
        # Old installations advertise revision 29; copied binaries need a real update.
        self.assertGreater(int((base / '.version-roothide').read_text().strip()), 29)
        recipe = (ROOT / 'Application/Makefile').read_text()
        self.assertIn('DORootHideVersion', recipe)
        version = next(line for line in recipe.splitlines() if 'CFBundleShortVersionString' in line)
        self.assertNotIn('wm0104', version)
        self.assertNotIn('CUSTOM_REVISION', version)

    def test_removed_injection_modules_are_not_restored(self):
        paths = ('BaseBin/launchdhook/src/jailFools.m',
                 'BaseBin/launchdhook/src/trollstore_lite_bundle.m',
                 'BaseBin/launchdhook/src/trollstore_lite_txm.m',
                 'BaseBin/libjailbreak/src/txm_trust.c')
        for name in paths:
            with self.subTest(path=name):
                self.assertFalse((ROOT / name).exists())

if __name__ == '__main__':
    unittest.main()
