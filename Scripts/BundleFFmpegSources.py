#!/usr/bin/env python3
"""Create corresponding source/rebuild materials for the current working tree.

Run after building the matching XCFramework and before publishing a release.
This writes a local archive only; it never uploads or uses signing credentials.
"""
import hashlib
import json
from pathlib import Path
import subprocess
import tarfile
from BuildFFmpeg import tree_digest

ROOT = Path(__file__).resolve().parents[1]
CACHE = ROOT / "build/ffmpeg"
SOURCES = json.loads((ROOT / "Native/FFmpeg/sources.json").read_text())


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main():
    artifact = ROOT / "Native/FFmpeg/Artifacts/MBFFmpegBridge.xcframework"
    manifests = sorted(artifact.glob("*/MBFFmpegBridge.framework/BuildManifest.json"))
    if not manifests:
        raise SystemExit("Build the iOS XCFramework before bundling matching source.")
    for path in manifests:
        manifest = json.loads(path.read_text())
        if (manifest["sources"] != SOURCES
                or manifest["recipe_sha256"] != sha256(ROOT / "Scripts/BuildFFmpeg.py")
                or manifest.get("patches_sha256") != tree_digest(ROOT / "Native/FFmpeg/patches")
                or manifest["bridge_sha256"] != tree_digest(ROOT / "Native/MBFFmpegBridge")):
            raise SystemExit("Framework source/build recipe changed. Rebuild before bundling source.")
    entries = {}
    for name, spec in SOURCES.items():
        source = CACHE / "downloads" / spec["archive"]
        if not source.exists() or sha256(source) != spec["sha256"]:
            raise SystemExit(f"Missing or changed source archive: {name}")
        entries["dependencies/" + source.name] = source
    # Include actual uncommitted application/adapter changes; git archive HEAD
    # would silently package the wrong sources during a local implementation.
    paths = subprocess.check_output(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd=ROOT)
    for raw in paths.split(b"\0"):
        if not raw:
            continue
        relative = Path(raw.decode())
        if relative.parts[0] in (".git", "build", "DerivedData"):
            continue
        source = ROOT / relative
        # WebP's public headers are relative symlinks into its vendored sources.
        # Preserve them so the extracted Swift package can actually be rebuilt.
        if source.is_file() or source.is_symlink():
            entries["app/" + relative.as_posix()] = source
    for manifest in manifests:
        entries["build-manifests/" + manifest.parent.parent.name + ".json"] = manifest
    for platform in ("ios", "ios-simulator"):
        for relative in ("ffmpeg/config.h", "ffmpeg/ffbuild/config.mak", "ffmpeg/ffbuild/config.log"):
            source = CACHE / f"{platform}-arm64" / relative
            if source.exists():
                entries[f"build-configuration/{platform}/{relative}"] = source
    output = CACHE / "MBConverter-corresponding-source.tar.gz"
    with tarfile.open(output, "w:gz") as archive:
        for name, source in sorted(entries.items()):
            archive.add(source, arcname="MBConverter-source/" + name, recursive=False)
    checksum = sha256(output)
    output.with_suffix(output.suffix + ".sha256").write_text(f"{checksum}  {output.name}\n")
    print(f"Created {output}\nSHA256 {checksum}")


if __name__ == "__main__":
    main()
