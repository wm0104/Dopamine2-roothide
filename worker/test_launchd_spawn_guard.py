#!/usr/bin/env python3
"""Compile the actual launchd wrapper; reject invalid PID registration/errno loss."""
from pathlib import Path
import os
import subprocess
import tempfile
from test_spawn_persona_guard import extract_function

ROOT = Path(__file__).resolve().parents[1]
STUBS = r'''
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdio.h>
#include <sys/types.h>
typedef void *posix_spawnattr_t;
struct _posix_spawn_args_desc { posix_spawnattr_t attrp; };
static int result, child, registered, resumed, calls;
#define JBLogDebug(...) (errno = EINTR)
static int posix_spawnattr_getflags(posix_spawnattr_t *p, short *flags) { *flags = 0; return 0; }
static int crashreporter_pause(void) { return 42; }
static void crashreporter_resume(int key) { assert(key == 42); resumed++; errno = EIO; }
static void register_job(pid_t pid) { assert(pid > 0); registered++; errno = EBUSY; }
static int __posix_spawn_inline(pid_t *pid, const char *path, struct _posix_spawn_args_desc *desc,
                              char *const argv[], char *const envp[]) {
    calls++; *pid = child; errno = EACCES; return result;
}
'''
CASES = r'''
int main(void) {
    int count = 0;
    for (int nullpid = 0; nullpid < 2; nullpid++) {
        for (int r = 0; r >= -1; r--) {
            const pid_t children[] = {-1, 0, 123};
            for (unsigned n = 0; n < 3; n++) {
                result = r; child = children[n]; registered = resumed = calls = 0;
                pid_t pid = 999;
                int got = __posix_spawn_orig_wrapper(nullpid ? NULL : &pid, "/test", NULL, NULL, NULL);
                assert(got == r && errno == EACCES);
                assert(resumed == 1 && calls == 1);
                assert(registered == (r == 0 && child > 0));
                count++;
            }
        }
    }
    printf("PASS %d launchd result/PID/NULL pointer/errno cases\n", count);
}
'''


def main():
    actual = extract_function((ROOT / 'BaseBin/launchdhook/src/spawn_hook.c').read_text(),
                              'int __posix_spawn_orig_wrapper(')
    with tempfile.TemporaryDirectory(prefix='launchd-spawn-', dir=ROOT / 'worker') as temporary:
        directory = Path(temporary)
        for name, implementation in [
            ('current', actual),
            ('missing-errno', actual.replace('errno = spawnError;', '')),
            ('missing-pid-guard', actual.replace('r == 0 && *pid > 0', 'r == 0')),
        ]:
            source, binary = directory / (name + '.c'), directory / name
            source.write_text(STUBS + implementation + CASES)
            subprocess.run([os.environ.get('CC', 'clang'), '-std=gnu11', '-O1', '-g',
                            '-fsanitize=undefined', str(source), '-o', str(binary)],
                           check=True, timeout=60)
            result = subprocess.run([str(binary)], capture_output=True, text=True, timeout=15)
            if name == 'current':
                if result.returncode:
                    raise SystemExit(result.stderr)
                print(result.stdout, end='')
            elif result.returncode == 0:
                raise SystemExit('Mutation incorrectly accepted: ' + name)
            else:
                print('PASS mutation rejected: ' + name)


if __name__ == '__main__':
    main()
