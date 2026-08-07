import Foundation

#if canImport(ffmpegkit)
import ffmpegkit

/// Uses FFprobe (via FFmpegKit) to read container metadata that `AVURLAsset` often omits for Matroska, WebM, and MPEG-TS.
enum FFprobeVideoMetadata {

    struct Result {
        var duration: Double?
        var dimensions: CGSize?
        var fps: Double?
        var frameCount: Int?
        var videoCodec: String?
        var audioCodec: String?
    }

    /// Containers where we prefer FFprobe duration/dimensions over AVFoundation when FFprobe succeeds.
    static let preferredProbeExtensions: Set<String> = ["hevc", "m2v", "mkv", "webm", "ts", "mts", "m2ts"]

    static func probeVideo(at url: URL) -> Result? {
        let session = FFprobeKit.getMediaInformation(url.path, withTimeout: 15_000)
        guard let info = session?.getMediaInformation() else { return nil }

        var duration = parseDuration(info.getDuration())

        var width: Int?
        var height: Int?
        var fps: Double?
        var frameCount: Int?
        var videoCodec: String?
        var audioCodec: String?

        let streams = info.getStreams() ?? []

        for item in streams {
            guard let stream = item as? StreamInformation else { continue }
            let type = stream.getType()?.lowercased() ?? ""
            if type == "video", width == nil {
                width = stream.getWidth()?.intValue
                height = stream.getHeight()?.intValue
                fps = parseFrameRate(stream.getAverageFrameRate()) ?? parseFrameRate(stream.getRealFrameRate())
                // Use FFmpegKit accessors only — KVC on `StreamInformation` throws for undefined keys.
                duration = duration
                    ?? parseDuration(stream.getStringProperty("duration"))
                    ?? tagClockDuration(stream.getTags())
                frameCount = stream.getNumberProperty("nb_frames")?.intValue
                    ?? parseInt(stream.getStringProperty("nb_frames"))
                videoCodec = normalizeCodec(stream.getCodec())
            } else if type == "audio", audioCodec == nil {
                audioCodec = normalizeCodec(stream.getCodec())
            }
        }

        duration = duration
            ?? tagClockDuration(info.getTags())
            ?? durationFromFrames(frameCount: frameCount, fps: fps)

        let dimensions: CGSize?
        if let w = width, let h = height, w > 0, h > 0 {
            dimensions = CGSize(width: w, height: h)
        } else {
            dimensions = nil
        }

        return Result(
            duration: duration,
            dimensions: dimensions,
            fps: fps,
            frameCount: frameCount,
            videoCodec: videoCodec,
            audioCodec: audioCodec
        )
    }

    private static func parseDuration(_ string: String?) -> Double? {
        guard let string, !string.isEmpty, string != "N/A" else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func parseClockDuration(_ string: String?) -> Double? {
        guard let string, !string.isEmpty, string != "N/A" else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        let total = (hours * 3600) + (minutes * 60) + seconds
        return total.isFinite && total > 0 ? total : nil
    }

    private static func parseFrameRate(_ string: String?) -> Double? {
        guard let string, !string.isEmpty, string != "N/A" else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let slash = trimmed.firstIndex(of: "/") {
            let num = Double(trimmed[..<slash])
            let den = Double(trimmed[trimmed.index(after: slash)...])
            guard let num, let den, den != 0 else { return nil }
            let v = num / den
            return v.isFinite && v > 0 ? v : nil
        }
        guard let v = Double(trimmed), v.isFinite, v > 0 else { return nil }
        return v
    }

    private static func normalizeCodec(_ codec: String?) -> String? {
        guard let codec, !codec.isEmpty else { return nil }
        return codec.lowercased()
    }

    private static func durationFromFrames(frameCount: Int?, fps: Double?) -> Double? {
        guard let frameCount, frameCount > 0, let fps, fps > 0 else { return nil }
        let duration = Double(frameCount) / fps
        return duration.isFinite && duration > 0 ? duration : nil
    }

    private static func parseInt(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value != "N/A" else { return nil }
        return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// FFprobe tag-based duration (e.g. `DURATION`, `DURATION-eng`) in `H:MM:SS.mmm` form.
    private static func tagClockDuration(_ tags: [AnyHashable: Any]?) -> Double? {
        guard let tags else { return nil }
        let keys = ["DURATION", "DURATION-eng", "duration"]
        for key in keys {
            if let raw = tags[key] as? String {
                if let d = parseClockDuration(raw) { return d }
            }
        }
        return nil
    }
}

#endif
