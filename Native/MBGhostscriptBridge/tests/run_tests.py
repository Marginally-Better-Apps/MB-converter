#!/usr/bin/env python3
"""Compile and run the Ghostscript bridge tests against the macOS host framework.

Build it first: python3 Scripts/BuildGhostscript.py --platform macos
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
FRAMEWORKS = ROOT / "build/ghostscript/macos-arm64"


def main():
    if not (FRAMEWORKS / "MBGhostscriptBridge.framework/MBGhostscriptBridge").exists():
        raise SystemExit("Build the macOS Ghostscript framework before running these tests.")
    with tempfile.TemporaryDirectory(prefix="mbgs-tests-") as directory:
        executable = Path(directory) / "bridge_tests"
        command = ["cc", "-std=gnu11", "-Wall", "-Wextra", "-Werror", "-F", FRAMEWORKS, "-I", ROOT / "Native/MBGhostscriptBridge/include",
                   Path(__file__).with_name("bridge_tests.c"), "-framework", "MBGhostscriptBridge",
                   "-Wl,-rpath," + str(FRAMEWORKS), "-o", executable]
        subprocess.run([str(x) for x in command], check=True)
        subprocess.run([str(executable), directory], check=True)


if __name__ == "__main__":
    main()
