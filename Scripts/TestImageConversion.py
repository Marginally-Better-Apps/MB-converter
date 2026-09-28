#!/usr/bin/env python3
"""Run image regressions on macOS, without a simulator.

Uses vendored production libwebp with -O2 and threading in both configurations.
--debug only disables Swift optimization, as in the app. System ImageIO encoders
and Swift macros require execution outside a restrictive sandbox.
"""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
WEBP_SOURCE = ROOT / "Native/WebP/libwebp"


def build_driver(work, *, source=WEBP_SOURCE, debug=False, converter=None,
                 driver=None, original_codec=False, ffmpeg_frameworks=None):
    """Compile production conversion code; benchmark-only variants are explicit."""
    work.mkdir(parents=True, exist_ok=True)
    (work / "module.modulemap").write_text(
        f'module libwebp {{ header "{source}/src/webp/encode.h" '
        f'header "{source}/src/webp/decode.h" export * }}\n'
    )
    formatter = (ROOT / "DesignSystem/Components/MetadataCard.swift").read_text()
    (work / "MetadataFormatter.swift").write_text(
        "import Foundation\nimport CoreGraphics\n" + formatter[formatter.index("struct MetadataRow:"):]
    )
    (work / "DiagnosticsLog.swift").write_text("""
import Foundation
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    func record(error: Error, context: String, metadata: [String: String] = [:]) {}
    func record(message: String, context: String, metadata: [String: String], details: String) {
        print(message)
    }
}
""")
    codec_files = sorted((source / "src").rglob("*.c")) + sorted((source / "sharpyuv").glob("*.c"))
    # Keep these equal to Native/WebP/Package.swift. Original Release used -Os,
    # without WEBP_USE_THREAD; it exists only as the benchmark baseline.
    flags = ["-Os"] if original_codec else ["-O2", "-DWEBP_USE_THREAD"]
    subprocess.run(["xcrun", "clang", "-dynamiclib", *flags, "-I", str(source),
                    *map(str, codec_files), "-o", str(work / "libwebp.dylib")], check=True)
    sources = [ROOT / path for path in [
        "Core/Models/VideoColorInfo.swift", "Core/Models/MediaModels.swift",
        "Core/Conversion/FFmpegEncodingStats.swift", "Core/Conversion/ConversionCore.swift",
        "Core/Conversion/AudioExportParameters.swift", "Core/Compatibility/CodecCapability.swift",
        "Core/Compatibility/FormatMatrix.swift", "Core/Compatibility/FFmpegRuntimeInfo.swift",
        "Core/Inspection/FFmpegMediaProbe.swift", "Core/Inspection/MediaTagDiscovery.swift",
        "Core/Inspection/FFprobeVideoMetadata.swift", "Core/Inspection/MediaInspector.swift",
        "Core/Conversion/FFmpegCommandRunner.swift", "Core/Conversion/MediaPreviewRenderer.swift",
        "Features/OutputConfig/OutputConfigViewModel.swift",
        "Tests/PNGDimensionsTests.swift", "Tests/PNGViewModelTests.swift",
        "Tests/WebPFixtures.swift", "Tests/WebPRegressionTests.swift"
    ]]
    sources += [converter or ROOT / "Core/Conversion/ImageConverter.swift",
                driver or ROOT / "Tests/ImageConversionTests.swift", work / "MetadataFormatter.swift",
                work / "DiagnosticsLog.swift"]
    bridge_flags = (["-F", str(ffmpeg_frameworks), "-framework", "MBFFmpegBridge",
                     "-Xlinker", "-rpath", "-Xlinker", str(ffmpeg_frameworks)]
                    if ffmpeg_frameworks else [])
    executable = work / "image-tests"
    subprocess.run([
        "xcrun", "swiftc", "-Onone" if debug else "-O", "-swift-version", "5",
        "-module-cache-path", str(work / "module-cache"), "-I", str(work), "-L", str(work),
        "-lwebp", "-Xlinker", "-rpath", "-Xlinker", str(work),
        *bridge_flags, *map(str, sources), "-o", str(executable)
    ], check=True)
    return executable


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--libwebp-source", type=Path, default=WEBP_SOURCE)
    parser.add_argument("--large", action="store_true")
    parser.add_argument("--debug", action="store_true")
    parser.add_argument("--ffmpeg", action="store_true",
                        help="Also verify native decode fallback using build/ffmpeg/macos-arm64")
    args = parser.parse_args()
    source = args.libwebp_source.resolve()
    if not (source / "src/webp/encode.h").is_file():
        parser.error("Missing vendored libwebp; restore Native/WebP or pass --libwebp-source")
    with tempfile.TemporaryDirectory(prefix="mb-image-tests-") as directory:
        print("Building libwebp and the production image converter…", flush=True)
        frameworks = ROOT / "build/ffmpeg/macos-arm64" if args.ffmpeg else None
        executable = build_driver(Path(directory), source=source, debug=args.debug,
                                  ffmpeg_frameworks=frameworks)
        environment = dict(os.environ, MB_IMAGE_TEST_LARGE="1" if args.large else "0")
        if args.ffmpeg:
            ffmpeg = shutil.which("ffmpeg")
            if not ffmpeg:
                parser.error("--ffmpeg requires ffmpeg to generate the unsupported JPEG-LS fixture")
            fixture = Path(directory) / "lossless.jpg"
            subprocess.run([ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                            "testsrc=size=48x32", "-frames:v", "1", "-c:v", "jpegls", "-f", "image2",
                            str(fixture)], check=True)
            environment["MB_IMAGE_TEST_FALLBACK"] = str(fixture)
        subprocess.run([str(executable)], env=environment, check=True, timeout=1200 if args.large else 600)


if __name__ == "__main__":
    main()
