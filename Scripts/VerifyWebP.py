#!/usr/bin/env python3
"""Verify vendored hashes, ARM64 SIMD/threading, and optional Xcode build flags."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--derived-data", type=Path)
    args = parser.parse_args()
    package = ROOT / "Native/WebP"
    provenance = json.loads((package / "provenance.json").read_text())
    for name, expected in provenance["files"].items():
        actual = hashlib.sha256((package / name).read_bytes()).hexdigest()
        assert actual == expected, f"Vendored file changed: {name}"
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    macros = subprocess.check_output(["xcrun", "clang", "-target", "arm64-apple-ios17.0",
        "-isysroot", sdk, "-O2", "-DWEBP_USE_THREAD", "-I", str(package / "libwebp"),
        "-dM", "-E", "-x", "c", "-"], input='#include "src/dsp/cpu.h"\n', text=True)
    assert "#define WEBP_USE_NEON" in macros and "#define WEBP_USE_THREAD" in macros
    print(f"libwebp {provenance['version']}: source hashes verified; ARM64 NEON and threading enabled")
    if args.derived_data:
        for configuration in ["Debug", "Release"]:
            directory = args.derived_data / f"Build/Intermediates.noindex/MBWebP.build/{configuration}-iphoneos/libwebp-t.build/Objects-normal/arm64"
            responses = list(directory.glob("*common-args.resp"))
            assert responses, f"Missing {configuration} build; build generic iOS first"
            for response in responses:
                flags = shlex.split(response.read_text())
                assert [f for f in flags if f.startswith("-O")][-1] == "-O2", flags
                assert "-DWEBP_USE_THREAD" in flags
            symbols = subprocess.check_output(["xcrun", "nm", str(directory / "enc_neon.o"),
                                               str(directory / "thread_utils.o")], text=True)
            assert "_VP8EncDspInitNEON" in symbols and "_pthread_create" in symbols
            notice = args.derived_data / f"Build/Products/{configuration}-iphoneos/Converter.app/WebP-NOTICE.txt"
            assert notice.read_bytes() == (package / "WebP-NOTICE.txt").read_bytes()
            print(f"{configuration}: effective -O2, threading flag, NEON and pthread symbols, bundled notices verified")


if __name__ == "__main__":
    main()
