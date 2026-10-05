#!/usr/bin/env python3
"""Run clipboard import regressions on macOS without touching the system clipboard.

--ffmpeg adds real unsupported-format thumbnails through direct URLs, expiring
providers and raw clipboard data using the built custom macOS framework.
"""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(*args, **kwargs):
    return subprocess.run(list(map(str, args)), cwd=ROOT, check=True, **kwargs)


def make_fixtures(work):
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise SystemExit("ffmpeg is required for --ffmpeg fixture generation")
    video = ["-f", "lavfi", "-i", "testsrc2=size=160x96:rate=10:duration=1"]
    for extension, codec in [("wmv", "wmv2"), ("webm", "libvpx-vp9"), ("avi", "mpeg4"),
                             ("mkv", "libaom-av1"), ("ts", "mpeg2video"), ("flv", "flv")]:
        run(ffmpeg, "-v", "error", "-y", *video, "-c:v", codec, "-threads", "1", work / f"video.{extension}")
    for extension, codec in [("jpg", "jpegls"), ("gif", "gif"), ("webp", "libwebp")]:
        run(ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x96:rate=1",
            "-frames:v", "1", "-c:v", codec, "-threads", "1", work / f"image.{extension}")
    for extension, codec in [("opus", "libopus"), ("ogg", "libvorbis"), ("flac", "flac")]:
        run(ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1.5",
            "-c:a", codec, work / f"audio.{extension}")
    run(ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=30",
        "-c:a", "libopus", work / "long.opus")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--ffmpeg", action="store_true")
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="mb-clipboard-tests-") as directory:
        work = Path(directory)
        sources = []
        for source in ["Core/IO/ImportService.swift", "Features/Home/HomeViewModel.swift"]:
            destination = work / Path(source).name
            destination.write_text((ROOT / source).read_text().replace("import UIKit\n", ""))
            sources.append(str(destination))
        flags = []
        if args.ffmpeg:
            framework = ROOT / "build/ffmpeg/macos-arm64/MBFFmpegBridge.framework"
            if not (framework / "MBFFmpegBridge").is_file():
                parser.error("Build the custom macOS FFmpeg framework first")
            flags = ["-F", framework.parent, "-framework", "MBFFmpegBridge",
                     "-Xlinker", "-rpath", "-Xlinker", framework.parent]
            make_fixtures(work)
        executable = work / "clipboard-tests"
        run("xcrun", "swiftc", "-swift-version", "5", "-module-cache-path", work / "cache",
            *flags, *sources, "Core/IO/ImportError.swift", "Core/IO/ImportStorage.swift",
            "Core/Compatibility/FormatMatrix.swift", "Core/Inspection/AudioWaveformThumbnail.swift",
            "Core/Conversion/MediaPreviewRenderer.swift", "Core/Conversion/FFmpegCommandRunner.swift",
            "Core/Conversion/FFmpegEncodingStats.swift", "Core/Inspection/FFmpegMediaProbe.swift",
            "Core/Models/VideoColorInfo.swift",
            "Tests/Fixtures/ClipboardHostSupport.swift", "Tests/ClipboardImportTests.swift", "-o", executable)
        # Foundation may ignore TMPDIR on macOS; preserve any cache belonging to other host tests.
        temp = Path(run(executable, "--temporary-directory", capture_output=True, text=True).stdout.strip())
        cache = temp / "media-previews"
        saved = work / "saved-cache"
        if cache.exists():
            shutil.move(cache, saved)
        try:
            run(executable, *([work] if args.ffmpeg else []), timeout=180)
        finally:
            if cache.exists():
                shutil.rmtree(cache)
            if saved.exists():
                shutil.move(saved, cache)


if __name__ == "__main__":
    main()
