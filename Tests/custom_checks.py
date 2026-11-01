"""Guard requested removals and retained RootHide features."""
from pathlib import Path
r=Path(__file__).resolve().parents[1]
def text(p): return (r/p).read_text()
base='BaseBin/launchdhook/src/'
for name in ['jailFools.m','trollstore_lite_bundle.m','trollstore_lite_txm.m']:
    assert not (r/base/name).exists(), name
for name in ['trollStoreLiteFixEnabled','installMountAppPressed','HelloMntDaemon']:
    assert name not in text('Application/Dopamine/UI/Settings/DOSettingsController.m')
assert 'restoreCustomMounts' not in text('Application/Dopamine/Jailbreak/DOJailbreaker.m')
assert 'https://wm0104.github.io/repo/' in text('Application/Dopamine/Jailbreak/DOBootstrapper.m')
assert 'reinstallWhitelistManager' in text('Application/Dopamine/Jailbreak/DOEnvironmentManager.m')
assert 'installPackage:path' in text('Application/Dopamine/Jailbreak/DOEnvironmentManager.m')
assert '@"config/RootHide"' in text('Application/Dopamine/Backup/DOConfigurationBackupManager.m')
assert 'Settings_Jetsam_Multiplier' in text('Application/Dopamine/UI/Settings/DOSettingsController.m')
assert 'DO_BACKUP_TESTING requires a DEBUG test build' in text('Application/Dopamine/Backup/DOConfigurationBackupManager.h')
assert 'O_NOFOLLOW' in text('Application/Dopamine/Backup/DOBackupFileIO.h')
assert '"image": @"archivebox"' in text('Application/Dopamine/UI/Settings/DOSettingsController.m')
assert 'archivebox' in text('Application/Dopamine/Backup/DOBackupController.m')
assert 'environmentVersionFromInfoDictionary' in text('Application/Dopamine/UI/DOUIManager.m')
assert 'DORootHideVersion' in text('Application/Makefile')
assert '配置备份' in text('Application/Dopamine/Backup/DOConfigurationBackupManager.m')
version_recipe = next(line for line in text('Application/Makefile').splitlines() if 'CFBundleShortVersionString' in line)
assert 'wm0104' not in version_recipe
assert 'CUSTOM_REVISION' not in version_recipe
build_recipe = next(line for line in text('Application/Makefile').splitlines() if 'CFBundleVersion' in line)
assert '"$(CUSTOM_REVISION)"' in build_recipe
print('Custom regression guards passed')
