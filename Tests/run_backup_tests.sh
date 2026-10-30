#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
binary="$(mktemp -t dopamine-backup-tests)"
trap 'rm -f "$binary"' EXIT
clang -fobjc-arc -fmodules -DDEBUG=1 -DDO_BACKUP_TESTING=1 -framework Foundation -IApplication/Dopamine/Backup Tests/backup_tests.m Application/Dopamine/Backup/DOConfigurationBackupManager.m Application/Dopamine/Backup/DOSourceMigration.m -o "$binary"
"$binary"
