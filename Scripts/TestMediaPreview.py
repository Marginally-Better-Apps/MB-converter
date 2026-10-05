#!/usr/bin/env python3
"""Exercise production previews against the custom macOS FFmpeg bridge.

Build first: python3 Scripts/BuildFFmpeg.py --platform macos --offline
Requires host ffmpeg/ffprobe for independent fixture generation and decoding.
No simulator is launched. Playback checks require macOS media services.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = ROOT / "build/ffmpeg/macos-arm64"


def run(*arguments, capture=False, env=None, timeout=180):
    return subprocess.run(list(map(str, arguments)), cwd=ROOT, check=True,
                          stdout=subprocess.PIPE if capture else None,
                          env=env, timeout=timeout).stdout


def fixtures(work, ffmpeg):
    def generate(name, *arguments):
        run(ffmpeg, "-hide_banner", "-loglevel", "error", "-y", *arguments, work / name)

    video = ["-f", "lavfi", "-i", "testsrc2=size=320x180:rate=12:duration=1.5"]
    audio = ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1.5"]
    generate("source.webm", *video, *audio, "-c:v", "libvpx-vp9", "-deadline", "realtime",
             "-cpu-used", "8", "-c:a", "libopus")
    generate("source.avi", *video, "-c:v", "mpeg4", "-q:v", "4")
    generate("anamorphic.avi", *video, "-vf", "setsar=2/1", "-c:v", "mpeg4", "-q:v", "4")
    generate("source-av1.mkv", *video, "-c:v", "libaom-av1", "-cpu-used", "8", "-crf", "45")
    generate("source.mkv", *video, *audio, "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac")
    generate("native.mp4", "-i", work / "source.mkv", "-c", "copy")
    generate("source.bmp", "-f", "lavfi", "-i", "testsrc=size=321x203:rate=1", "-frames:v", "1")
    # Packed 16-bit RGBA -> planar lossless FFV1 catches alpha/depth loss when
    # the bridge has to choose a PNG encoder pixel format.
    pixels = b"".join(struct.pack("<HHHH", 4097 + x * 997, 15003 + y * 709,
                                   63001 - x * 503, (x + y) * 2001)
                      for y in range(16) for x in range(16))
    (work / "alpha.rgba64le").write_bytes(pixels)
    generate("alpha.mkv", "-f", "rawvideo", "-pixel_format", "rgba64le", "-video_size", "16x16",
             "-i", work / "alpha.rgba64le", "-frames:v", "1", "-c:v", "ffv1", "-pix_fmt", "gbrap16le")
    generate("source.opus", *audio, "-c:a", "libopus")
    generate("source.ogg", *audio, "-c:a", "libvorbis")
    generate("replacement.ogg", "-f", "lavfi", "-i",
             "sine=frequency=880:sample_rate=48000:duration=2.25", "-c:a", "libvorbis")
    generate("long.opus", "-f", "lavfi", "-i",
             "sine=frequency=440:sample_rate=48000:duration=60", "-c:a", "libopus")


SWIFT_TEST = r'''
import AVFoundation
import Foundation
import ImageIO

enum MediaCategory: String, Sendable { case video, audio, image, animatedImage }
enum ConversionError: LocalizedError {
    case engineFailed(String), invalidInput(String), cancelled
    var errorDescription: String? {
        switch self {
        case .engineFailed(let message), .invalidInput(let message): return message
        case .cancelled: return "Cancelled"
        }
    }
}
enum TempStorage {
    static func allowAccessWhileLocked(at url: URL) {}
    static func url(extension value: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(value)
    }
}
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    func record(message: String, context: String, metadata: [String: String], details: String) {
        print("Diagnostic: \(context): \(message)")
    }
    func record(error: Error, context: String) { print("Diagnostic: \(context): \(error)") }
}
final class CancellationHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<MediaPreviewResource, Error>?
    private var cancellationRequested = false
    func install(_ value: Task<MediaPreviewResource, Error>) {
        lock.lock()
        task = value
        let shouldCancel = cancellationRequested
        lock.unlock()
        if shouldCancel { value.cancel() }
    }
    func progress(_ value: Double) {
        guard value > 0 && value < 1 else { return }
        lock.lock()
        cancellationRequested = true
        let current = task
        lock.unlock()
        current?.cancel()
    }
    func clear() {
        lock.lock(); defer { lock.unlock() }
        task = nil
    }
    var didRequestCancellation: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancellationRequested
    }
}
final class ProgressValues: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Double] = []
    func append(_ value: Double) { lock.lock(); defer { lock.unlock() }; recorded.append(value) }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return recorded }
}
func require(_ condition: Bool, _ message: String) {
    guard condition else { fatalError(message) }
}
func imageDimensions(_ data: Data) throws -> (Int, Int) {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw ConversionError.engineFailed("Extracted frame is not a decodable image")
    }
    return (image.width, image.height)
}
func regularFiles(under root: URL) -> Set<String> {
    let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
    var result: Set<String> = []
    while let url = enumerator?.nextObject() as? URL {
        if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { result.insert(url.path) }
    }
    return result
}
@main struct Tests {
    static func main() async throws {
        if CommandLine.arguments[1] == "--temporary-directory" {
            print(FileManager.default.temporaryDirectory.path)
            return
        }
        let work = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let playback = CommandLine.arguments[2] == "playback"
        let temporary = FileManager.default.temporaryDirectory
        let cacheDirectory = temporary.appendingPathComponent("media-previews")
        func source(_ name: String) -> URL { work.appendingPathComponent(name) }
        func copy(_ input: URL, as name: String) throws {
            try FileManager.default.copyItem(at: input, to: source(name))
        }

        for name in ["source.webm", "source.avi", "source-av1.mkv", "source.bmp"] {
            let data = try await MediaPreviewRenderer.firstFrame(sourceURL: source(name), maximumDimension: 96)
            let (width, height) = try imageDimensions(data)
            require(width > 0 && height > 0 && max(width, height) <= 96, "Thumbnail bounds: \(name)")
            let cached = try await MediaPreviewRenderer.firstFrame(sourceURL: source(name), maximumDimension: 96)
            require(data == cached, "Repeated thumbnail request changed its image")
            try data.write(to: source(name + ".png"))
        }
        let anamorphic = try await MediaPreviewRenderer.firstFrame(sourceURL: source("anamorphic.avi"), maximumDimension: 96)
        let anamorphicSize = try imageDimensions(anamorphic)
        require(anamorphicSize.0 == 96 && anamorphicSize.1 == 27, "Anamorphic thumbnail lost its display aspect ratio")
        let full = try await MediaPreviewRenderer.renderFirstFrame(sourceURL: source("source.bmp"))
        let dimensions = try imageDimensions(Data(contentsOf: full))
        require(dimensions.0 == 321 && dimensions.1 == 203, "Full-resolution image fallback must preserve dimensions")
        try copy(full, as: "full-image.png")
        try FileManager.default.removeItem(at: full)

        let alphaPreview = try await MediaPreviewRenderer.firstFrame(sourceURL: source("alpha.mkv"), maximumDimension: 96)
        try alphaPreview.write(to: source("alpha-preview.png"))
        let alphaFull = try await MediaPreviewRenderer.renderFirstFrame(sourceURL: source("alpha.mkv"))
        try copy(alphaFull, as: "alpha-full.png")
        try FileManager.default.removeItem(at: alphaFull)
        let failedStart = regularFiles(under: cacheDirectory)
        do {
            _ = try await MediaPreviewRenderer.renderFirstFrame(sourceURL: source("source.opus"))
            fatalError("Audio-only input should fail first-frame extraction")
        } catch {}
        require(regularFiles(under: cacheDirectory) == failedStart, "Failed frame extraction left a partial output")

        // Verify metacharacters stay one file argument; no shell interprets input names.
        let quotedSource = source("O'Brien 日本語 $(never) `expand`.webm")
        try FileManager.default.copyItem(at: source("source.webm"), to: quotedSource)
        let quotedImage = try await MediaPreviewRenderer.firstFrame(sourceURL: quotedSource, maximumDimension: 96)
        require(try imageDimensions(quotedImage).0 > 0, "Quoted Unicode source failed")
        print("PASS: production frame extraction, full-resolution stills, failed-output cleanup, and Unicode paths")
        guard playback else { return }

        let native = try await MediaPreviewRenderer.playablePreview(sourceURL: source("native.mp4"), category: .video,
                                                                   progress: { _ in })
        require(native.url == source("native.mp4"), "Native-compatible media should use the original asset")
        // HEVC must use the Apple-compatible sample entry when only the container changes.
        let hevcCommand = try FFmpegCommandRunner.arguments(in: MediaPreviewRenderer.remuxCommand(
            sourceURL: source("hevc.mkv"), outputURL: source("hevc.mp4"), category: .video, videoCodec: "hevc"))
        require(hevcCommand.contains("hvc1"), "HEVC remux must retain Apple-compatible sample entry")
        let opusProgress = ProgressValues()
        let opus = try await MediaPreviewRenderer.playablePreview(sourceURL: source("source.opus"), category: .audio,
                                                                 forceFallback: true, progress: { opusProgress.append($0) })
        require(opus.url != source("source.opus"), "Opus must produce a native-compatible fallback")
        require(await MediaPreviewRenderer.isPlayable(opus.url), "Opus fallback is not playable")
        try copy(opus.url, as: "opus-preview.m4a")
        require(opusProgress.values.last == 1, "Preparation did not report completion")
        require(opusProgress.values.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }, "Invalid progress value")

        let oggURL = source("source.ogg")
        let ogg = try await MediaPreviewRenderer.playablePreview(sourceURL: oggURL, category: .audio, forceFallback: true, progress: { _ in })
        require(ogg.url != oggURL, "Ogg must produce a native-compatible fallback")
        try copy(ogg.url, as: "ogg-preview.m4a")
        let again = try await MediaPreviewRenderer.playablePreview(sourceURL: oggURL, category: .audio, progress: { _ in })
        require(again.url == ogg.url, "Unchanged source should reuse its cached playback file")
        try FileManager.default.removeItem(at: oggURL)
        try FileManager.default.copyItem(at: source("replacement.ogg"), to: oggURL)
        let replacement = try await MediaPreviewRenderer.playablePreview(sourceURL: oggURL, category: .audio, forceFallback: true, progress: { _ in })
        require(replacement.url != ogg.url, "Replacing a source must invalidate the cached playback file")
        require(FileManager.default.fileExists(atPath: ogg.url.path), "An active preview lease lost its old media file")
        try copy(replacement.url, as: "replacement-preview.m4a")
        withExtendedLifetime((ogg, again)) {}

        let remux = try await MediaPreviewRenderer.playablePreview(sourceURL: source("source.mkv"), category: .video,
                                                                  progress: { _ in })
        if remux.url == source("source.mkv") {
            // Native container support varies by macOS release. Exercise the
            // production remux command directly when this host can use MKV.
            try await FFmpegCommandRunner().run(MediaPreviewRenderer.remuxCommand(
                sourceURL: remux.url, outputURL: source("remux-preview.mp4"), category: .video, videoCodec: "h264"),
                duration: 1.5, progress: { _ in })
        } else {
            try copy(remux.url, as: "remux-preview.mp4")
        }
        require(await MediaPreviewRenderer.isPlayable(source("remux-preview.mp4")), "Remuxed preview is not playable")
        let transcoded = try await MediaPreviewRenderer.playablePreview(sourceURL: source("source.webm"), category: .video,
                                                                       forceFallback: true, progress: { _ in })
        require(await MediaPreviewRenderer.isPlayable(transcoded.url), "Transcoded preview is not playable")
        try copy(transcoded.url, as: "transcode-preview.mp4")

        // Exceed the cache entry limit with cheap stills while playback resources remain leased.
        for edge in 32...64 {
            _ = try await MediaPreviewRenderer.firstFrame(sourceURL: source("source.bmp"), maximumDimension: edge)
        }
        let cacheFiles = regularFiles(under: cacheDirectory)
        require(cacheFiles.count <= 24, "Unused previews exceeded the cache entry bound")
        for resource in [opus, ogg, again, replacement, remux, transcoded] {
            require(FileManager.default.fileExists(atPath: resource.url.path), "Eviction removed an active preview")
        }

        let cancellation = CancellationHandle()
        let before = regularFiles(under: cacheDirectory)
        let cancelled = Task {
            try await MediaPreviewRenderer.playablePreview(sourceURL: source("long.opus"), category: .audio,
                                                          forceFallback: true, progress: { cancellation.progress($0) })
        }
        cancellation.install(cancelled)
        defer { cancellation.clear() }
        do {
            _ = try await cancelled.value
            fatalError("Cancelled preview unexpectedly succeeded")
        } catch is CancellationError {
        } catch ConversionError.cancelled {}
        require(cancellation.didRequestCancellation, "Cancellation did not interrupt preparation in progress")
        require(regularFiles(under: cacheDirectory) == before, "Cancelled preparation left an uncached partial file")
        // A cancelled operation cannot poison later independent preparations.
        let resumed = try await MediaPreviewRenderer.playablePreview(sourceURL: source("long.opus"), category: .audio,
                                                                    progress: { _ in })
        require(await MediaPreviewRenderer.isPlayable(resumed.url), "Preparation could not recover after cancellation")
        withExtendedLifetime((opus, replacement, remux, transcoded, resumed)) {}
        print("PASS: audio/video fallback, playable assets, bounded cache, source replacement, active leases, and cancellation")
    }
}

'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--skip-playback", action="store_true",
                        help="only test extraction when macOS media services are unavailable")
    args = parser.parse_args()
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    assert ffmpeg and ffprobe, "ffmpeg and ffprobe are required"
    assert (FRAMEWORKS / "MBFFmpegBridge.framework/MBFFmpegBridge").is_file(), "Build the macOS bridge first"
    with tempfile.TemporaryDirectory(prefix="mb-media-preview-") as directory:
        work = Path(directory)
        (work / "Tests.swift").write_text(SWIFT_TEST)
        paths = ["Core/Conversion/MediaPreviewRenderer.swift", "Core/Conversion/FFmpegCommandRunner.swift",
                 "Core/Conversion/FFmpegEncodingStats.swift", "Core/Compatibility/FFmpegRuntimeInfo.swift",
                 "Core/Inspection/FFmpegMediaProbe.swift", "Core/Models/VideoColorInfo.swift"]
        run("xcrun", "swiftc", "-swift-version", "5", "-O", "-strict-concurrency=complete",
            "-module-cache-path", work / "modules", "-F", FRAMEWORKS, "-framework", "MBFFmpegBridge",
            "-Xlinker", "-rpath", "-Xlinker", FRAMEWORKS,
            *[ROOT / path for path in paths], work / "Tests.swift", "-o", work / "tests")
        fixtures(work, ffmpeg)
        isolated_tmp = work / "tmp"
        isolated_tmp.mkdir()
        env = dict(os.environ, TMPDIR=str(isolated_tmp))
        # On an unrestricted macOS process Foundation may ignore TMPDIR and
        # use confstr(_CS_DARWIN_USER_TEMP_DIR). Preserve that host-only cache;
        # the iOS app has its own sandbox. Run host media suites sequentially.
        foundation_tmp = Path(run(work / "tests", "--temporary-directory", capture=True, env=env).decode().strip())
        cache = foundation_tmp / "media-previews"
        saved_cache = work / "saved-preview-cache"
        if cache.exists():
            shutil.move(cache, saved_cache)
        try:
            run(work / "tests", work, "skip-playback" if args.skip_playback else "playback", env=env)
        finally:
            if cache.exists():
                shutil.rmtree(cache)
            if saved_cache.exists():
                shutil.move(saved_cache, cache)

        def probe(name):
            return json.loads(run(ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json",
                                  work / name, capture=True))

        for name in ["source.webm", "source.avi", "source-av1.mkv", "source.bmp"]:
            image = probe(name + ".png")["streams"][0]
            assert image["codec_name"] == "png"
            assert 0 < image["width"] <= 96 and 0 < image["height"] <= 96
        full = probe("full-image.png")["streams"][0]
        assert (full["width"], full["height"]) == (321, 203), "Image conversion fallback reduced source resolution"
        def rgba(name, pixel_format):
            return run(ffmpeg, "-v", "error", "-i", work / name, "-pix_fmt", pixel_format,
                       "-f", "rawvideo", "-", capture=True)
        full_pixels = rgba("alpha-full.png", "rgba64le")
        assert full_pixels == (work / "alpha.rgba64le").read_bytes(), "Full image fallback lost 16-bit color or alpha"
        preview_pixels = rgba("alpha-preview.png", "rgba")
        expected_pixels = rgba("alpha.mkv", "rgba")
        assert preview_pixels[3::4] == expected_pixels[3::4], "Preview PNG lost transparency"
        assert probe("alpha-full.png")["streams"][0]["pix_fmt"] == "rgba64be", "Full image fallback truncated color depth"
        if args.skip_playback:
            print("PASS: real FFmpeg extraction; playback intentionally skipped")
            return
        for name, duration in [("opus-preview.m4a", 1.5), ("ogg-preview.m4a", 1.5),
                               ("replacement-preview.m4a", 2.25)]:
            info = probe(name)
            audio_stream = next(stream for stream in info["streams"] if stream["codec_type"] == "audio")
            assert audio_stream["codec_name"] in ["aac", "pcm_s16le"], (name, audio_stream["codec_name"])
            assert abs(float(info["format"]["duration"]) - duration) < 0.12, (name, info["format"]["duration"])
            run(ffmpeg, "-v", "error", "-i", work / name, "-f", "null", "-")
        remux = probe("remux-preview.mp4")
        assert {stream["codec_name"] for stream in remux["streams"]} == {"h264", "aac"}
        def video_hash(name):
            return hashlib.sha256(run(ffmpeg, "-v", "error", "-i", work / name, "-map", "0:v:0",
                                      "-c:v", "copy", "-bsf:v", "h264_mp4toannexb", "-f", "h264", "-",
                                      capture=True)).hexdigest()
        assert video_hash("source.mkv") == video_hash("remux-preview.mp4"), "Compatible video was reencoded"
        transcoded = probe("transcode-preview.mp4")
        stream = next(stream for stream in transcoded["streams"] if stream["codec_type"] == "video")
        assert stream["codec_name"] == "h264"
        assert stream["width"] <= 1280 and stream["height"] <= 720
        assert abs(float(transcoded["format"]["duration"]) - 1.5) < 0.15, "Video fallback changed duration"
        run(ffmpeg, "-v", "error", "-i", work / "transcode-preview.mp4", "-f", "null", "-")
        print("PASS: thumbnails (VP9/AVI/AV1/BMP), anamorphic ratio, 16-bit alpha, full images, Opus/Ogg, MP4 remux/transcode, cache/invalidation/cancellation")


if __name__ == "__main__":
    main()
