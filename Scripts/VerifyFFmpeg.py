#!/usr/bin/env python3
"""Check shipped framework slices, license configuration and dependencies."""
import json
from pathlib import Path
import plistlib
import subprocess
from BuildFFmpeg import digest, tree_digest

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "Native/FFmpeg/Artifacts/MBFFmpegBridge.xcframework"
REQUIRED = ["libmp3lame", "libopus", "libvorbis", "libvpx", "libdav1d", "libzimg"]


def output(*args):
    return subprocess.check_output(args, text=True)


def main():
    info = plistlib.loads((ARTIFACT / "Info.plist").read_bytes())
    libraries = info["AvailableLibraries"]
    assert any(x["SupportedPlatform"] == "ios" and "SupportedPlatformVariant" not in x for x in libraries), "Missing iOS device slice"
    for item in libraries:
        folder = ARTIFACT / item["LibraryIdentifier"] / item["LibraryPath"]
        binary = folder / "MBFFmpegBridge"
        assert item["SupportedArchitectures"] == ["arm64"], "Unexpected architectures"
        assert "DYLIB" in output("otool", "-hv", str(binary)), "Runtime must be a dynamic library"
        target = output("xcrun", "vtool", "-show-build", str(binary))
        platform = (item["SupportedPlatform"], item.get("SupportedPlatformVariant"))
        expected = {("ios", None): "IOS", ("ios", "simulator"): "IOSSIMULATOR",
                    ("macos", None): "MACOS"}[platform]
        assert f"platform {expected}\n" in target, f"Wrong Mach-O platform: {target}"
        for line in output("otool", "-L", str(binary)).splitlines()[1:]:
            path = line.strip().split(" (", 1)[0]
            assert path.startswith(("/System/Library/", "/usr/lib/", "@rpath/MBFFmpegBridge.framework/")), path
        strings = output("strings", str(binary))
        configuration = next(line for line in strings.splitlines() if "--enable-libmp3lame" in line and "--prefix=" in line)
        for flag in ("gpl", "nonfree", "version3"):
            assert f"--disable-{flag}" in configuration and f"--enable-{flag}" not in configuration, configuration
        assert "LGPL version 2.1 or later" in strings, "Unexpected runtime license"
        assert "nonfree and unredistributable" not in strings, "Nonredistributable runtime"
        for library in REQUIRED:
            assert f"--enable-{library}" in configuration, f"Missing {library}"
        symbols = output("nm", "-gU", str(binary))
        for symbol in ("mbf_execute", "mbf_probe_json", "mbf_free_string", "mbf_license", "mbf_has_encoder", "mbf_has_muxer"):
            assert "_" + symbol in symbols, f"Missing exported bridge symbol: {symbol}"
        manifest = json.loads((folder / "BuildManifest.json").read_text())
        assert manifest["sources"] == json.loads((ROOT / "Native/FFmpeg/sources.json").read_text()), "Stale source pins; rebuild FFmpeg"
        assert manifest["recipe_sha256"] == digest(ROOT / "Scripts/BuildFFmpeg.py"), "Stale recipe; rebuild FFmpeg"
        assert manifest["bridge_sha256"] == tree_digest(ROOT / "Native/MBFFmpegBridge"), "Stale adapter; rebuild FFmpeg"
        assert manifest["patches_sha256"] == tree_digest(ROOT / "Native/FFmpeg/patches"), "Stale patches; rebuild FFmpeg"
        assert manifest["license"] == "LGPL-2.1-or-later"
        assert (folder / "Licenses/ffmpeg/COPYING.LGPLv2.1").exists()
        assert (folder / "Licenses/zimg/COPYING").exists(), "Missing zimg notice"
        assert manifest.get("patches_sha256"), "Missing decoder hardware policy patch identity"
        for name in ("scale_vt", "transpose_vt", "zscale", "tonemap"):
            assert name in strings.splitlines(), f"Missing video filter: {name}"
        print(f"Verified {item['LibraryIdentifier']}: dynamic runtime, LGPL2.1, required codecs, Apple system dependencies")


if __name__ == "__main__":
    main()
