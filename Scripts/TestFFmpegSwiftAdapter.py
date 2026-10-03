#!/usr/bin/env python3
"""Host-only contract tests: compile production Swift against a deterministic C stub.

No FFmpeg downloads, Simulator, Xcode project changes, or installed frameworks needed.
The native-engine integration smoke test separately verifies real codec behavior.
"""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
C_STUB = r'''
#include "MBFFmpegBridge.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
int mbf_execute(int argc, const char *const *argv, mbf_log_callback log,
                mbf_progress_callback progress, mbf_cancel_callback cancel, void *ctx) {
    if (argc != 2 || strcmp(argv[0], "ffmpeg")) return -99;
    if (!strcmp(argv[1], "fail")) { log(ctx, "Could not open fixture input\n"); return -22; }
    if (!strcmp(argv[1], "backend")) {
        log(ctx, "Video pipeline: decode=VideoToolbox hardware required filter=VideoToolbox encoder=hevc_videotoolbox (hardware required) input=p010le output=p010le color=preserve HDR Main10\n");
        log(ctx, "MBF_RETRY software decoding/filtering; hardware failure=-1; color policy unchanged\n");
        log(ctx, "Video pipeline: decode=CPU filter=CPU encoder=hevc_videotoolbox (software fallback permitted) input=p010le output=p010le color=preserve HDR Main10\n");
    }
    for (int i = 0; i < 100; ++i) {
        if (cancel(ctx)) return -1;
        progress(ctx, i * 10000, i * 32, i);
        usleep(1000);
    }
    return 0;
}
char *mbf_probe_json(const char *path, int timeout_ms) {
    return strdup("{\"format\":{\"duration\":\"N/A\",\"bit_rate\":128000,\"tags\":{\"title\":\"Fixture\"}},\"streams\":[{\"index\":0,\"codec_type\":\"video\",\"codec_name\":\"vp9\",\"width\":640,\"height\":360,\"avg_frame_rate\":\"0/0\",\"r_frame_rate\":\"30000/1001\",\"nb_frames\":\"60\",\"tags\":{\"DURATION\":\"00:00:02.002\"}},{\"index\":1,\"codec_type\":\"audio\",\"codec_name\":\"mp3\",\"duration\":2.002,\"bit_rate\":\"128000\"}]} ");
}
void mbf_free_string(char *value) { free(value); }
int mbf_has_encoder(const char *name) { return !strcmp(name, "libmp3lame"); }
int mbf_has_decoder(const char *name) { return !strcmp(name, "mp3"); }
int mbf_has_muxer(const char *name) { return !strcmp(name, "mp3"); }
const char *mbf_version(void) { return "fixture"; }
const char *mbf_license(void) { return "LGPL version 2.1 or later"; }
const char *mbf_configuration(void) { return "--enable-libmp3lame --enable-libopus"; }
'''
SWIFT_TEST = r'''
import Foundation

enum ConversionError: Error { case engineFailed(String), cancelled }
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    func record(message: String, context: String, metadata: [String: String], details: String) {}
}
final class Observation: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Double] = []
    private var touchedMainThread = false
    private var backends: [String] = []
    func recordBackend(_ stats: FFmpegEncodingDisplayStats) {
        lock.lock(); defer { lock.unlock() }
        if let backend = stats.processingBackend { backends.append(backend) }
    }
    var backendSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return backends
    }
    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        values.append(value)
        touchedMainThread = touchedMainThread || Thread.isMainThread
    }
    var snapshot: ([Double], Bool) {
        lock.lock(); defer { lock.unlock() }
        return (values, touchedMainThread)
    }
}
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fatalError(label) }
}
func expectCancelled(_ operation: Task<Void, Error>) async throws {
    do { try await operation.value; fatalError("Expected cancellation") }
    catch ConversionError.cancelled {}
}
@main struct Tests {
    static func main() async throws {
        for value in ["", "space path", "O'Brien’s audio.mp3", "日本語🎵.wav", "a\\b", "\n", "$(never) `expand` ; | &", "double\"quote"] {
            let parsed = try FFmpegCommandRunner.arguments(in: FFmpegCommandRunner.quoted(value))
            require(parsed == [value], "Quoted argument must round-trip: \(value)")
        }
        let parsed = try FFmpegCommandRunner.arguments(in: #"-i 'a b' -metadata title='rock '\''n'\'' roll' -vf "scale=640:360,setsar=1" ''"#)
        require(parsed == ["-i", "a b", "-metadata", "title=rock 'n' roll", "-vf", "scale=640:360,setsar=1", ""], "Mixed quoting")
        let escaped = try FFmpegCommandRunner.arguments(in: "a\\ b \"a\\q\" x\\\ny")
        require(escaped == ["a b", "a\\q", "xy"], "Shell-compatible escapes")
        for invalid in ["'open", "\"open", "escape\\", "before\0after", "'\0'", "\\\0"] {
            do { _ = try FFmpegCommandRunner.arguments(in: invalid); fatalError("Accepted malformed argument") }
            catch ConversionError.engineFailed {}
        }
        require(FFmpegRuntimeInfo.hasEncoder("libmp3lame"), "Encoder registry")
        require(!FFmpegRuntimeInfo.hasEncoder("libx264"), "Missing encoder registry")
        require(FFmpegRuntimeInfo.hasDecoder("mp3") && FFmpegRuntimeInfo.hasMuxer("mp3"), "Decoder/muxer registry")
        require(FFmpegRuntimeInfo.current.externalLibraries == ["libmp3lame", "libopus"], "Build configuration")
        let hdr = try JSONDecoder().decode(VideoColorInfo.self, from: Data(#"{"pix_fmt":"yuv420p10le","bit_depth":10,"color_transfer":"arib-std-b67","dovi_profile":8,"dovi_compatibility_id":4}"#.utf8))
        require(hdr.isHDR && hdr.bitDepth == 10 && hdr.dolbyVisionCompatibilityID == 4, "HDR probe fields")
        let unknown = try JSONDecoder().decode(VideoColorInfo.self, from: Data("{}".utf8))
        require(!unknown.isHDR && unknown.bitDepth == nil, "Missing color fields stay unknown")
        let video = FFprobeVideoMetadata.probeVideo(at: URL(fileURLWithPath: "/fixture.webm"))!
        require(video.duration == 2.002 && video.frameCount == 60, "Duration tag and string frame count")
        require(video.dimensions?.width == 640 && video.dimensions?.height == 360 && abs(video.fps! - 29.97002997) < 0.0001, "Dimensions and rate fallback")
        let audio = FFprobeVideoMetadata.probeAudio(at: URL(fileURLWithPath: "/fixture.mp3"))!
        require(audio.duration == 2.002 && audio.audioCodec == "mp3" && audio.audioBitrate == 128000, "Audio probe")
        require(FFmpegMediaProbe.probe(at: URL(string: "https://example.com/media")!) == nil, "Only local probes")
        let shared = FFmpegCommandRunner()
        require(ConversionBackendDescription.command(arguments: ["-c", "copy"]) == "Stream copy · No re-encoding", "Remux must not report hardware encoding")
        require(ConversionBackendDescription.command(arguments: ["-c:v", "libvpx-vp9", "-c:a", "libopus"]) == "CPU · libvpx-vp9", "Prefer the video backend in mixed streams")
        require(ConversionBackendDescription.pipeline(logLine: "Unrelated log") == nil, "Ignore unrelated diagnostics")
        let backendObservation = Observation()
        try await shared.run("backend", duration: 1, progress: { _ in }, onEncodingStats: { backendObservation.recordBackend($0) })
        require(backendObservation.backendSnapshot == [
            "VideoToolbox · HEVC hardware\nDecode: VideoToolbox · Filters: VideoToolbox",
            "Retrying · CPU decoding and filtering",
            "VideoToolbox · HEVC\nDecode: CPU · Filters: CPU"
        ], "Report runtime acceleration and fallback without claiming unconfirmed hardware use")
        let observation = Observation()
        let cancelled = Task { try await shared.run("work", duration: 1, progress: { _ in }) }
        let surviving = Task { try await shared.run("work", duration: 1, progress: { observation.record($0) }) }
        try await Task.sleep(nanoseconds: 10_000_000)
        cancelled.cancel()
        try await expectCancelled(cancelled)
        try await surviving.value
        require(observation.snapshot.0.last == 1, "Cancelling a task must preserve another run on the same runner")
        require(!observation.snapshot.1, "Codec callbacks must not block the main thread")
        let another = FFmpegCommandRunner()
        let ownerCancelled = Task { try await shared.run("work", duration: nil, progress: { _ in }) }
        let unrelated = Task { try await another.run("work", duration: nil, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 10_000_000)
        shared.cancel()
        try await expectCancelled(ownerCancelled)
        try await unrelated.value
        try await shared.run("work", duration: nil, progress: { _ in })
        do { try await shared.run("fail", duration: nil, progress: { _ in }); fatalError("Expected engine error") }
        catch ConversionError.engineFailed(let message) {
            require(message.contains("-22") && message.contains("Could not open fixture input"), "Preserve native failure details")
        }
        print("Swift FFmpeg adapter: quoting, malformed arguments, metadata, capabilities, progress, failure, and isolated cancellation passed.")
    }
}
'''

def run(*args):
    subprocess.run(args, cwd=ROOT, check=True)

with tempfile.TemporaryDirectory(prefix="mbffmpeg-swift-tests-") as directory:
    temp = Path(directory)
    shutil.copy(ROOT / "Native/MBFFmpegBridge/include/MBFFmpegBridge.h", temp)
    (temp / "module.modulemap").write_text('module MBFFmpegBridge { header "MBFFmpegBridge.h" export * }\n')
    (temp / "stub.c").write_text(C_STUB)
    (temp / "Tests.swift").write_text(SWIFT_TEST)
    run("xcrun", "clang", "-c", str(temp / "stub.c"), "-o", str(temp / "stub.o"))
    run("xcrun", "swiftc", "-swift-version", "5", "-strict-concurrency=complete", "-warnings-as-errors",
        "-I", str(temp), "-module-cache-path", str(temp / "module-cache"),
        "Core/Conversion/FFmpegCommandRunner.swift", "Core/Conversion/FFmpegEncodingStats.swift",
        "Core/Compatibility/FFmpegRuntimeInfo.swift", "Core/Inspection/FFmpegMediaProbe.swift",
        "Core/Inspection/FFprobeVideoMetadata.swift", "Core/Models/VideoColorInfo.swift", str(temp / "Tests.swift"), str(temp / "stub.o"),
        "-o", str(temp / "adapter-tests"))
    run(str(temp / "adapter-tests"))
