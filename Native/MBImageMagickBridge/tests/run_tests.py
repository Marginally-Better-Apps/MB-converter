#!/usr/bin/env python3
"""Compile and run the ImageMagick bridge tests against the macOS host libraries.

Build them first: python3 Scripts/BuildImageMagick.py --platform macos --libraries-only
"""
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[3]
PREFIX = ROOT / "build/imagemagick/macos-arm64/prefix"
sys.path.insert(0, str(ROOT / "Scripts"))
from BuildImageMagick import DELEGATE_LIBRARIES, MAGICK_LIBRARIES  # noqa: E402


def main():
    if not (PREFIX / "lib/libMagickCore-7.Q16HDRI.a").exists():
        raise SystemExit("Build the macOS ImageMagick libraries before running these tests.")
    bridge = ROOT / "Native/MBImageMagickBridge"
    with tempfile.TemporaryDirectory(prefix="mbim-tests-") as directory:
        executable = Path(directory) / "bridge_tests"
        command = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", "-DMAGICKCORE_HDRI_ENABLE=1",
                   "-DMAGICKCORE_QUANTUM_DEPTH=16", "-I", bridge / "include", "-I", PREFIX / "include/ImageMagick-7",
                   bridge / "MBImageMagickBridge.c", Path(__file__).with_name("bridge_tests.c")]
        command += [PREFIX / f"lib/lib{name}.a" for name in MAGICK_LIBRARIES + DELEGATE_LIBRARIES]
        command += ["-lz", "-lbz2", "-lm", "-lc++", "-liconv", "-o", executable]
        subprocess.run([str(x) for x in command], check=True)
        subprocess.run([str(executable), directory], check=True)


if __name__ == "__main__":
    main()
