#!/usr/bin/env python3
"""Test remote import validation on macOS, without a simulator or network.

Pass --ffmpeg-framework to also test real AVI/WebM inspection with the bundled
host engine. This optional integration check needs the ffmpeg CLI for fixtures.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg-framework", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mb-remote-import-tests-") as directory:
        work = Path(directory)
        flags = []
        fixtures = []
        if args.ffmpeg_framework:
            framework = args.ffmpeg_framework.resolve()
            if not (framework / "MBFFmpegBridge").is_file():
                parser.error("Missing host MBFFmpegBridge.framework")
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                parser.error("ffmpeg is required to generate video fixtures")
            flags = ["-F", str(framework.parent), "-framework", "MBFFmpegBridge",
                     "-Xlinker", "-rpath", "-Xlinker", str(framework.parent)]
            for extension, codec in [("avi", "mpeg4"), ("webm", "libvpx-vp9")]:
                fixture = work / f"valid.{extension}"
                subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
                                "-i", "color=c=red:s=64x48:r=10:d=1", "-c:v", codec,
                                str(fixture)], check=True)
                fixtures.append(str(fixture))
        sources = [
            "Core/IO/RemoteFileDownloader.swift", "Core/IO/ImportError.swift", "Core/IO/ImportStorage.swift",
            "Core/Models/MediaModels.swift", "Core/Models/VideoColorInfo.swift",
            "Core/Compatibility/FormatMatrix.swift", "Core/Compatibility/CodecCapability.swift",
            "Core/Compatibility/FFmpegRuntimeInfo.swift", "Core/Conversion/ConversionCore.swift",
            "Core/Conversion/AudioExportParameters.swift", "Core/Conversion/FFmpegEncodingStats.swift",
            "Core/Inspection/MediaInspector.swift", "Core/Inspection/FFprobeVideoMetadata.swift",
            "Core/Inspection/FFmpegMediaProbe.swift", "Tests/RemoteImportTests.swift"
        ]
        executable = work / "remote-import-tests"
        subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", str(work / "module-cache"),
                        *flags, *sources, "-o", str(executable)], cwd=ROOT, check=True)
        subprocess.run([str(executable), *fixtures], check=True, timeout=120)


if __name__ == "__main__":
    main()
