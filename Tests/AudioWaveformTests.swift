import CoreGraphics
import Darwin
import Foundation

// Host-only regressions for the production sampler. No clipboard, simulator,
// audio playback, or network access is needed.
@main
struct AudioWaveformTests {
    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fatalError(message) }
    }

    static func main() throws {
        if CommandLine.arguments.count > 1 {
            for path in CommandLine.arguments.dropFirst() {
                try benchmark(URL(fileURLWithPath: path))
            }
            return
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-waveform-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let framesPerBar = 8_192
        let rising = directory.appendingPathComponent("rising.wav")
        try writeWave(to: rising, frames: framesPerBar * 24) { frame, _ in
            let levels: [Int16] = [0, 4_000, 12_000, 28_000]
            let peak = levels[min(3, frame / (framesPerBar * 6))]
            return frame % 64 < 32 ? peak : -peak
        }
        let samples = AudioWaveformThumbnail.samples(from: rising)
        require(samples?.count == 24, "Expected one real amplitude per bar")
        let peaks = samples!
        require(peaks.allSatisfy { $0.isFinite && (0...1).contains($0) }, "Amplitudes must be finite and normalized")
        require(peaks[0..<6].allSatisfy { $0 == 0 }, "The silent first quarter must remain silent")
        require(peaks[6] > 0 && peaks[6] < peaks[12] && peaks[12] < peaks[18], "Waveform must follow rising source amplitude across the full file")
        for start in [0, 6, 12, 18] {
            require(peaks[start..<(start + 6)].allSatisfy { abs($0 - peaks[start]) < 0.01 }, "Equal-amplitude regions must produce stable peaks")
        }

        let silence = directory.appendingPathComponent("silence.wav")
        try writeWave(to: silence, frames: 48_000) { _, _ in 0 }
        require(AudioWaveformThumbnail.samples(from: silence)?.allSatisfy { $0 == 0 } == true, "Silence must not become invented waveform peaks")

        let stereo = directory.appendingPathComponent("antiphase.wav")
        try writeWave(to: stereo, frames: framesPerBar * 24, channels: 2) { frame, channel in
            let value: Int16 = frame % 64 < 32 ? 16_000 : -16_000
            return channel == 0 ? value : -value
        }
        let stereoPeaks = AudioWaveformThumbnail.samples(from: stereo)
        require(stereoPeaks?.count == 24 && stereoPeaks!.allSatisfy { $0 > 0 }, "Opposite-phase stereo channels must not cancel the waveform")

        let tiny = directory.appendingPathComponent("one-frame.wav")
        try writeWave(to: tiny, frames: 1) { _, _ in 16_000 }
        let tinyPeaks = AudioWaveformThumbnail.samples(from: tiny)
        require(tinyPeaks?.count == 24 && tinyPeaks!.allSatisfy { $0 > 0 }, "A valid one-frame file must produce a bounded waveform")

        let empty = directory.appendingPathComponent("zero-frame.wav")
        try writeWave(to: empty, frames: 0) { _, _ in 0 }
        require(AudioWaveformThumbnail.samples(from: empty) == nil, "Zero-frame files must not produce a waveform")
        let corrupt = directory.appendingPathComponent("corrupt.wav")
        try Data("This is not audio.".utf8).write(to: corrupt)
        require(AudioWaveformThumbnail.samples(from: corrupt) == nil, "Corrupt input must fail quietly")
        require(AudioWaveformThumbnail.samples(from: directory.appendingPathComponent("missing.wav")) == nil, "Missing input must fail quietly")

        require(AudioWaveformThumbnail.samples(from: rising, isCancelled: { true }) == nil, "Already-cancelled previews must not decode")
        var cancellationChecks = 0
        let cancelled = AudioWaveformThumbnail.samples(from: rising, isCancelled: {
            cancellationChecks += 1
            return cancellationChecks >= 4
        })
        require(cancelled == nil && cancellationChecks >= 4, "Cancellation must be observed between sample reads")
        require(AudioWaveformThumbnail.image(from: rising, maxPixelSize: 144, isCancelled: { true }) == nil, "Cancelled previews must not render")

        for dimension in [56, 144] {
            let image = AudioWaveformThumbnail.image(from: rising, maxPixelSize: dimension)
            require(image != nil && image!.width > 0 && image!.height > 0, "Valid audio must render a thumbnail")
            require(image!.width <= dimension && image!.height <= dimension, "Thumbnail must respect the pixel budget")
        }
        require(AudioWaveformThumbnail.image(from: silence, maxPixelSize: 144) != nil, "Silent audio must still have a preview")

        print("Audio waveform: amplitude, silence, stereo phase, tiny/empty/corrupt input, cancellation, and image bounds passed.")
    }

    private static func writeWave(
        to url: URL,
        frames: Int,
        channels: Int = 1,
        sample: (Int, Int) -> Int16
    ) throws {
        let payloadSize = frames * channels * 2
        var data = Data(capacity: 44 + payloadSize)
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        func u32(_ value: UInt32) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        text("RIFF"); u32(UInt32(36 + payloadSize)); text("WAVEfmt "); u32(16)
        u16(1); u16(UInt16(channels)); u32(48_000); u32(UInt32(48_000 * channels * 2))
        u16(UInt16(channels * 2)); u16(16); text("data"); u32(UInt32(payloadSize))
        for frame in 0..<frames {
            for channel in 0..<channels {
                u16(UInt16(bitPattern: sample(frame, channel)))
            }
        }
        try data.write(to: url)
    }

    private static func benchmark(_ url: URL) throws {
        let start = ProcessInfo.processInfo.systemUptime
        let samples = AudioWaveformThumbnail.samples(from: url)
        let sampled = ProcessInfo.processInfo.systemUptime
        let image = AudioWaveformThumbnail.image(from: url, maxPixelSize: 144)
        let rendered = ProcessInfo.processInfo.systemUptime
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let fileSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        let report: [String: Any] = [
            "fixture": url.lastPathComponent,
            "file_bytes": fileSize,
            "sample_ms": (sampled - start) * 1_000,
            "image_ms_including_sampling": (rendered - sampled) * 1_000,
            "bars": samples?.count ?? 0,
            "rendered": image != nil,
            "peak_rss_bytes": usage.ru_maxrss
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
