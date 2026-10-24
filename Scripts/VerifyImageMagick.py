#!/usr/bin/env python3
"""Check the shipped ImageMagick framework: slices, exports, delegates, licenses and pins."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ARTIFACT = ROOT / "Native/ImageMagick/Artifacts/MBImageMagickBridge.xcframework"
BRIDGE = ROOT / "Native/MBImageMagickBridge"
EXPORTS = {"_mbim_convert", "_mbim_formats", "_mbim_free_string", "_mbim_identify", "_mbim_initialize", "_mbim_version"}
DELEGATES = ["PNG", "JPEG", "TIFF", "WEBP", "OpenJP2", "JXL", "LCMS"]


def output(*args):
    return subprocess.check_output([str(x) for x in args], text=True)


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    info = plistlib.loads((ARTIFACT / "Info.plist").read_bytes())
    libraries = info["AvailableLibraries"]
    assert any(x["SupportedPlatform"] == "ios" and "SupportedPlatformVariant" not in x for x in libraries), "Missing iOS device slice"
    bridge_hash = hashlib.sha256(b"".join(digest(path).encode() for path in sorted(BRIDGE.rglob("*.[ch]")))).hexdigest()
    for item in libraries:
        folder = ARTIFACT / item["LibraryIdentifier"] / item["LibraryPath"]
        binary = folder / "MBImageMagickBridge"
        assert item["SupportedArchitectures"] == ["arm64"], "Unexpected architectures"
        assert "DYLIB" in output("otool", "-hv", binary), "Runtime must be a dynamic library"
        for line in output("otool", "-L", binary).splitlines()[1:]:
            path = line.strip().split(" (", 1)[0]
            assert path.startswith(("/System/Library/", "/usr/lib/", "@rpath/MBImageMagickBridge.framework/")), path
        exported = {line.split()[-1] for line in output("nm", "-gU", binary).splitlines() if line.strip()}
        assert exported == EXPORTS, f"Unexpected exports (must stay private to avoid clashes): {exported ^ EXPORTS}"
        strings = output("strings", binary)
        assert "gsapi_" not in strings, "Ghostscript (AGPL) must not be linked"
        manifest = json.loads((folder / "BuildManifest.json").read_text())
        assert manifest["sources"] == json.loads((ROOT / "Native/ImageMagick/sources.json").read_text()), "Stale pins; rebuild"
        assert manifest["recipe_sha256"] == digest(ROOT / "Scripts/BuildImageMagick.py"), "Stale recipe; rebuild ImageMagick"
        assert manifest["bridge_sha256"] == bridge_hash, "Stale bridge; rebuild ImageMagick"
        for notice in ("ImageMagick/LICENSE", "libjxl/LICENSE", "libpng/LICENSE", "libjpeg-turbo/LICENSE.md"):
            assert (folder / "Licenses" / notice).exists(), f"Missing notice {notice}"
        print(f"Verified {item['LibraryIdentifier']}: dynamic runtime, private symbols, permissive delegates, notices")


if __name__ == "__main__":
    main()
