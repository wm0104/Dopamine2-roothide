"""Exercise the delivery entitlement reader without requiring macOS locally."""
import ast
from pathlib import Path
import plistlib
import subprocess
from unittest.mock import patch

source = Path(__file__).resolve().parents[1] / 'Tools/verify_delivery.py'
node = next(n for n in ast.parse(source.read_text()).body if isinstance(n, ast.FunctionDef) and n.name == 'read_entitlements')
namespace = {'subprocess': subprocess, 'plistlib': plistlib}
exec(compile(ast.Module(body=[node], type_ignores=[]), str(source), 'exec'), namespace)
read = namespace['read_entitlements']

def check(code, output, error, expected=None, failure=None):
    result = subprocess.CompletedProcess([], code, output, error)
    with patch.object(subprocess, 'run', return_value=result):
        if failure:
            try:
                read('fixture')
            except failure:
                return
            raise AssertionError('Invalid signature input was accepted')
        assert read('fixture') == expected

check(1, b'', b'fixture: code object is not signed at all', {})
check(0, b'', b'Executable=fixture', {})
check(0, plistlib.dumps({'platform-application': True}), b'Executable=fixture', {'platform-application': True})
check(1, b'', b'fixture: invalid signature', failure=RuntimeError)
check(0, b'broken plist', b'', failure=plistlib.InvalidFileException)
check(0, plistlib.dumps(['not a dictionary']), b'', failure=AssertionError)
print('Delivery entitlement reader: 6 checks passed')
