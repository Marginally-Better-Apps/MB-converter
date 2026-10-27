#!/usr/bin/env python3
"""Check the shipped Ghostscript framework: slices, exports, no process spawning, notices and pins."""
import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "Scripts"))
from BuildGhostscript import patches_digest  # noqa: E402
ARTIFACT = ROOT / "Native/Ghostscript/Artifacts/MBGhostscriptBridge.xcframework"
BRIDGE = ROOT / "Native/MBGhostscriptBridge"
EXPORTS = {"_mbgs_run", "_mbgs_version"}
# Ghostscript must not be able to start processes; the bridge replaces popen.
FORBIDDEN_IMPORTS = {"_popen", "_system", "_fork", "_vfork", "_posix_spawn", "_posix_spawnp", "_execv", "_execvp", "_execve", "_execl", "_execlp"}


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
    sources = json.loads((ROOT / "Native/Ghostscript/sources.json").read_text())
    for item in libraries:
        folder = ARTIFACT / item["LibraryIdentifier"] / item["LibraryPath"]
        binary = folder / "MBGhostscriptBridge"
        assert item["SupportedArchitectures"] == ["arm64"], "Unexpected architectures"
        assert "DYLIB" in output("otool", "-hv", binary), "Runtime must be a dynamic library"
        for line in output("otool", "-L", binary).splitlines()[1:]:
            path = line.strip().split(" (", 1)[0]
            assert path.startswith(("/System/Library/", "/usr/lib/", "@rpath/MBGhostscriptBridge.framework/")), path
        exported = {line.split()[-1] for line in output("nm", "-gU", binary).splitlines() if line.strip()}
        assert exported == EXPORTS, f"Unexpected exports (must stay private to avoid clashes): {exported ^ EXPORTS}"
        imported = {line.split()[-1] for line in output("nm", "-u", binary).splitlines() if line.strip()}
        assert not imported & FORBIDDEN_IMPORTS, f"Ghostscript can start processes: {imported & FORBIDDEN_IMPORTS}"
        manifest = json.loads((folder / "BuildManifest.json").read_text())
        assert manifest["sources"] == sources, "Stale pins; rebuild Ghostscript"
        assert manifest["recipe_sha256"] == digest(ROOT / "Scripts/BuildGhostscript.py"), "Stale recipe; rebuild Ghostscript"
        assert manifest["bridge_sha256"] == bridge_hash, "Stale bridge; rebuild Ghostscript"
        assert manifest["patches_sha256"] == patches_digest(), "Stale patches; rebuild Ghostscript"
        for notice in ("Ghostscript/LICENSE", "Ghostscript/COPYING (GNU AGPL 3.0)", "Ghostscript/freetype/FTL.TXT",
                       "Ghostscript/libpng/LICENSE", "Ghostscript/lcms2mt/COPYING", "MBGhostscriptBridge-GPL.txt"):
            assert (folder / "Licenses" / notice).exists(), f"Missing notice {notice}"
        assert "AFFERO" in (folder / "Licenses/Ghostscript/COPYING (GNU AGPL 3.0)").read_text(), "AGPL text missing"
        print(f"Verified {item['LibraryIdentifier']}: Ghostscript {sources['ghostscript']['version']}, private symbols, no process spawning, notices")


if __name__ == "__main__":
    main()
