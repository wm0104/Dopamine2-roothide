#!/usr/bin/env python3
"""Run only upstream suites whose production fixes are included in this port.

The upstream ChOma commit is unavailable. Parser/signature suites are deliberately
not claimed as covered; exact deferred revisions are listed in UPSTREAM_PORT.md.
"""
from pathlib import Path
import runpy
import sys

ROOT = Path(__file__).resolve().parents[1]
SUITES = (
    'trustcache_batch_regression.py',
    'test_spawn_persona_guard.py',
    'test_spawn_posthook.py',
    'test_spawn_runtime.py',
    'verify_jbctl_spawn.py',
    'test_configuration_cache.py',
    'test_ipc_hookd.py',
    'test_forkfix_handshake.py',
    'test_exec_patch_records.py',
    'test_job_info_cache.py',
    'test_runtime_utilities.py',
    'test_launchd_spawn_guard.py',
)
DEFERRED = (
    'macho_parser_regression.py',
    'test_signature_collection.py',
    'test_signature_status.py',
    'test_signature_recovery.py',
)

def main():
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / 'worker'))
    for name in SUITES:
        path = ROOT / 'worker' / name
        if not path.is_file(): raise RuntimeError('Missing required regression: ' + name)
        print('=== ' + name + ' ===', flush=True)
        sys.argv = [str(path)]
        runpy.run_path(str(path), run_name='__main__')
    print('PASS included upstream suites; NOT PORTED / NOT TESTED: ' + ', '.join(DEFERRED))

if __name__ == '__main__': main()
