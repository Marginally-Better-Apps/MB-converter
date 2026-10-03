import Foundation

/// Reads metadata directly through the bundled libavformat bridge.
enum FFprobeVideoMetadata {
    struct Result: Sendable {
        var duration: Double?
        var dimensions: CGSize?
        var fps: Double?
        var frameCount: Int?
        var videoCodec: String?
        var videoColor: VideoColorInfo?
        var audioCodec: String?
        var audioBitrate: Int?
    }

    struct AudioResult: Sendable {
        var duration: Double?
        var audioCodec: String?
        var audioBitrate: Int?
    }

    /// Containers where we prefer native FFmpeg metadata over AVFoundation when probing succeeds.
    static let preferredProbeExtensions: Set<String> = ["hevc", "m2v", "mkv", "webm", "ts", "mts", "m2ts"]

    static func probeAudio(at url: URL) -> AudioResult? {
        guard let info = FFmpegMediaProbe.probe(at: url),
              let audio = info.streams.first(where: { $0.codecType == "audio" }) else { return nil }
        return AudioResult(
            duration: positive(info.format?.duration) ?? positive(audio.duration)
                ?? tagClockDuration(audio.tags) ?? tagClockDuration(info.format?.tags),
            audioCodec: normalizeCodec(audio.codecName),
            audioBitrate: positive(audio.bitRate)
        )
    }

    static func probeVideo(at url: URL) -> Result? {
        guard let info = FFmpegMediaProbe.probe(at: url),
              let video = info.streams.first(where: { $0.codecType == "video" }) else { return nil }
        let audio = info.streams.first(where: { $0.codecType == "audio" })
        let fps = parseFrameRate(video.averageFrameRate) ?? parseFrameRate(video.realFrameRate)
        let frameCount = positive(video.frameCount)
        let duration = positive(info.format?.duration) ?? positive(video.duration)
            ?? tagClockDuration(video.tags) ?? tagClockDuration(info.format?.tags)
            ?? durationFromFrames(frameCount: frameCount, fps: fps)
        let dimensions: CGSize?
        if let width = positive(video.width), let height = positive(video.height) {
            dimensions = CGSize(width: CGFloat(width), height: CGFloat(height))
        } else {
            dimensions = nil
        }
        return Result(
            duration: duration, dimensions: dimensions, fps: fps, frameCount: frameCount,
            videoCodec: normalizeCodec(video.codecName), videoColor: video.color, audioCodec: normalizeCodec(audio?.codecName),
            audioBitrate: positive(audio?.bitRate)
        )
    }

    private static func positive<T: BinaryInteger>(_ value: T?) -> T? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func positive(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func parseFrameRate(_ string: String?) -> Double? {
        guard let string else { return nil }
        let parts = string.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/")
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 {
            return positive(numerator / denominator)
        }
        return positive(Double(string))
    }

    private static func normalizeCodec(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        return codec.lowercased()
    }

    private static func durationFromFrames(frameCount: Int?, fps: Double?) -> Double? {
        guard let frameCount, let fps else { return nil }
        return positive(Double(frameCount) / fps)
    }

    /// Matroska tags can supply duration as H:MM:SS.mmm when stream duration is absent.
    private static func tagClockDuration(_ tags: [String: String]?) -> Double? {
        guard let tags else { return nil }
        for key in ["DURATION", "DURATION-eng", "duration"] {
            guard let raw = tags[key] else { continue }
            let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
            guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]), let seconds = Double(parts[2]),
                  hours >= 0, minutes >= 0, minutes < 60, seconds >= 0, seconds < 60 else { continue }
            if let duration = positive(hours * 3600 + minutes * 60 + seconds) { return duration }
        }
        return nil
    }
}
