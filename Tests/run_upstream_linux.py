#!/usr/bin/env python3
"""Run unchanged, portable upstream C harnesses on Linux (clang + Blocks + UUID).

Alpine prerequisites: apk add clang compiler-rt libdispatch util-linux-dev
No production source is rewritten. Only native Linux linker dependencies differ.
Every compiler/harness subprocess is bounded to 60 seconds.
"""
from pathlib import Path
import os
import platform
import runpy
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RUN = subprocess.run
TEMPORARY_DIRECTORY = tempfile.TemporaryDirectory


def executable_temporary_directory(*args, **kwargs):
    # Minis workspace is host-mapped; execute binaries on the Linux filesystem.
    if kwargs.get("dir") == ROOT / "worker":
        kwargs["dir"] = "/tmp"
    return TEMPORARY_DIRECTORY(*args, **kwargs)


def linux_run(command, *args, **kwargs):
    command = list(command)
    if Path(command[0]).name == "clang":
        # iSH cannot reserve ASan's shadow range; retain UBSan, never call this ASan coverage.
        command = [arg.replace("-fsanitize=address,undefined", "-fsanitize=undefined")
                   for arg in command]
    if Path(command[0]).name == "clang" and "-c" not in command:
        command += ["-lBlocksRuntime", "-luuid", "-lm"]
    kwargs.setdefault("timeout", 60)
    return RUN(command, *args, **kwargs)


def main():
    if platform.system() != "Linux":
        raise SystemExit("Use the worker harnesses directly on Darwin")
    subprocess.run = linux_run
    tempfile.TemporaryDirectory = executable_temporary_directory
    os.environ.setdefault("CC", "clang")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(ROOT / "worker"))
    cases = [
        ("trustcache_batch_regression.py", ["--check-regression"]),
        ("test_spawn_persona_guard.py", []),
        ("test_spawn_runtime.py", []),
        ("test_launchd_spawn_guard.py", []),
    ]
    for name, arguments in cases:
        print("=== " + name + " ===", flush=True)
        sys.argv = [name, *arguments]
        runpy.run_path(str(ROOT / "worker" / name), run_name="__main__")
    print("PASS: all four portable upstream harness suites")


if __name__ == "__main__":
    main()
