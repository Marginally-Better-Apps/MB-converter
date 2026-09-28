import AVFoundation
import Foundation

// Host-only UI dependency adapters. Audio conversion, inspection, metadata,
// output planning, and the native FFmpeg framework are production implementations.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    func record(error: Error, context: String, metadata: [String: String] = [:]) {}
    func record(message: String, context: String, metadata: [String: String], details: String) {
        print(message)
    }
}
struct ImageConverter {
    struct PNGSizeBaseline: Sendable { let bytes: Int64; let dimensions: CGSize }
    func measurePNGBaselineWithFallback(input: MediaFile, config: ConversionConfig) async throws -> PNGSizeBaseline {
        fatalError("Audio tests must not invoke image conversion")
    }
}

@main
struct AudioEditingTests {
    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        let input = try await MediaInspector.inspect(url: directory.appendingPathComponent("stereo.wav"))
        let duration = input.duration!
        func require(_ condition: @autoclosure () -> Bool, _ message: String) {
            guard condition() else {
                FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
                exit(1)
            }
        }
        // MP3 tags can have spaces in their keys. Each key=value pair must
        // survive command tokenization as one argument, including stream tags.
        var metadata = MetadataExportPolicy.default
        metadata.stripAll = false
        metadata.retainedFormatTags = ["Encoded by": "LAME in FL Studio 20", "BPM (beats per minute)": "120"]
        metadata.retainedStreamTags = [0: ["Artist's note": "Rock 'n' roll\nCafé"]]
        let metadataArgs = try FFmpegCommandRunner.arguments(in: FFmpegMetadataOptions.outputFlags(metadata))
        require(metadataArgs == ["-map_metadata", "-1", "-map_chapters", "-1",
            "-metadata", "BPM (beats per minute)=120", "-metadata", "Encoded by=LAME in FL Studio 20",
            "-metadata_input:s:0", "Artist's note=Rock 'n' roll\nCafé"], "Metadata keys and values must remain intact")
        let mp3 = try await MediaInspector.inspect(url: directory.appendingPathComponent("source.mp3"))
        let tagged = try await AudioConverter().convert(input: mp3,
            config: ConversionConfig(outputFormat: .flac, prefersRemuxWhenPossible: true, metadata: metadata),
            progress: { _ in })
        try FileManager.default.moveItem(at: tagged.url, to: directory.appendingPathComponent("tagged.flac"))
        func export(_ name: String, _ edits: AudioEditSettings, format: OutputFormat = .wav,
                    source: MediaFile? = nil) async throws {
            let result = try await AudioConverter().convert(input: source ?? input,
                config: ConversionConfig(outputFormat: format, audioEdits: edits, prefersRemuxWhenPossible: true),
                progress: { _ in })
            try FileManager.default.moveItem(at: result.url, to: directory.appendingPathComponent(name))
        }

        try await export("trim.wav", AudioEditSettings(trimStart: 0.123, trimEnd: 1.345))
        try await export("quiet.wav", AudioEditSettings(volume: 0.5))
        try await export("silent.wav", AudioEditSettings(volume: 0))
        try await export("boost.wav", AudioEditSettings(volume: 2))
        try await export("fast.wav", AudioEditSettings(speed: 2))
        try await export("slow.wav", AudioEditSettings(speed: 0.5))
        try await export("left.wav", AudioEditSettings(channels: .left))
        try await export("right.wav", AudioEditSettings(channels: .right))
        try await export("mono.wav", AudioEditSettings(channels: .mono))
        let mono = try await MediaInspector.inspect(url: directory.appendingPathComponent("left.wav"))
        try await export("mono-right.wav", AudioEditSettings(channels: .right), source: mono)
        try await export("stereo-from-mono.wav", AudioEditSettings(channels: .stereo), source: mono)
        try await export("short.wav", AudioEditSettings(trimStart: 1, trimEnd: 1.1, speed: 2))
        let combined = AudioEditSettings(trimStart: 0.25, trimEnd: 2.25, volume: 0.5, speed: 1.5, channels: .right)
        try await export("combined.wav", combined)
        let preview = try await AudioEditRenderer.preview(sourceURL: input.url, sourceDuration: duration,
                                                         edits: combined, progress: { _ in })
        try FileManager.default.moveItem(at: preview, to: directory.appendingPathComponent("preview.wav"))

        for format in [OutputFormat.mp3, .m4a, .aac, .flac, .ogg, .opus] {
            try await export("muted.\(format.fileExtension)", AudioEditSettings(volume: 0, channels: .mono), format: format)
        }
        let compressed = try await MediaInspector.inspect(url: directory.appendingPathComponent("source.opus"))
        try await export("opus-trim.wav", AudioEditSettings(trimStart: 0.123, trimEnd: 1.345), source: compressed)
        let video = try await MediaInspector.inspect(url: directory.appendingPathComponent("source.mp4"))
        try await export("extracted.wav", combined, source: video)

        for edits in [AudioEditSettings(trimStart: -1), AudioEditSettings(trimEnd: duration + 1),
                      AudioEditSettings(trimStart: 2, trimEnd: 1), AudioEditSettings(speed: 0),
                      AudioEditSettings(volume: .nan), AudioEditSettings(speed: .infinity)] {
            do {
                _ = try await AudioConverter().convert(input: input,
                    config: ConversionConfig(outputFormat: .wav, audioEdits: edits), progress: { _ in })
                preconditionFailure("Invalid edits were accepted")
            } catch ConversionError.invalidInput {}
        }
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: TempStorage.directory.path))
        let cancelled = Task {
            try await AudioEditRenderer.preview(sourceURL: input.url, sourceDuration: duration,
                                                edits: combined, progress: { _ in })
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled preview completed") }
        catch is CancellationError {} catch ConversionError.cancelled {}
        let after = Set(try FileManager.default.contentsOfDirectory(atPath: TempStorage.directory.path))
        require(before == after, "Cancelled preview left a temporary file")

        let model = OutputConfigViewModel(input: input)
        model.selectedFormat = .mp3
        let initialMaximum = model.targetSizeSliderReferenceBytes
        require(model.shouldShowAudioEditor, "Audio editor missing")
        model.audioEdits = AudioEditSettings(trimEnd: duration / 2, speed: 2)
        require(abs(model.audioOutputDuration! - duration / 4) < 0.001, "Edited duration wasn't applied")
        require(model.targetSizeSliderReferenceBytes < initialMaximum / 2, "Target size ignored edited duration")
        require(!model.shouldShowRemuxBadgeOnTargetSize, "Edited audio cannot be stream copied")
        let config = model.makeConfig()
        require(config.audioEdits == model.audioEdits, "Export lost edits")
        model.audioEdits.volume = 0.5
        require(config != model.makeConfig(), "Changing audio edits must invalidate cached conversion")
        let extraction = OutputConfigViewModel(input: video)
        extraction.selectedFormat = .mp3
        extraction.audioEdits = combined
        require(extraction.shouldShowAudioEditor, "Video extraction must offer audio editing")
        extraction.selectedFormat = .mp4_h264
        let videoEdits = extraction.makeConfig().audioEdits
        require(videoEdits.trimStart == 0 && videoEdits.trimEnd == nil && videoEdits.speed == 1,
                "Audio trim and speed must not desynchronize video output")
        require(videoEdits.volume == 0.5 && videoEdits.channels == .right,
                "Video output must preserve the selected volume and channels")
        require(!extraction.shouldShowRemuxBadgeOnTargetSize,
                "Video with audio effects cannot be stream copied unchanged")
        extraction.selectedFormat = .mp3
        require(extraction.audioEdits == combined, "Switching format lost audio edits")
        extraction.replaceInput(video)
        require(extraction.audioEdits.isIdentity, "Replacing the source retained stale trim offsets")
        print("PASS: audio export, preview, validation, cancellation, cache keys, and edited-duration planning")
    }
}
