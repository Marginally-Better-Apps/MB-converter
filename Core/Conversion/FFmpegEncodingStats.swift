import Foundation

/// Values parsed from FFmpeg status lines (`frame= … fps= … size= …`).
struct FFmpegEncodingDisplayStats: Equatable, Sendable {
    var frame: Int?
    var fps: Double?
    var encodedSize: String?
    var time: String?
    var timeMilliseconds: Int64?
    var throughputBitrate: String?
    var speed: String?
    /// Execution backend updates also travel through this callback, without timing fields.
    var processingBackend: String?
    /// Native image encoders report stages and progress instead of video FPS/speed.
    var activity: String?

    var timeSeconds: Double? {
        guard let timeMilliseconds else { return nil }
        return Double(timeMilliseconds) / 1000.0
    }
}

enum ConversionBackendDescription {
    static func encoder(_ name: String) -> String {
        if name == "copy" { return "Stream copy · No re-encoding" }
        if name.contains("videotoolbox") { return "VideoToolbox · \(name.hasPrefix("hevc") ? "HEVC" : "H.264")" }
        return "CPU · \(name)"
    }

    static func command(arguments: [String]) -> String? {
        // Prefer the video encoder when the command also encodes audio.
        for option in ["-c:v", "-c", "-c:a"] {
            if let index = arguments.lastIndex(of: option), index + 1 < arguments.count {
                return encoder(arguments[index + 1])
            }
        }
        return nil
    }

    static func pipeline(logLine: String) -> String? {
        let line = logLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("MBF_RETRY ") { return "Retrying · CPU decoding and filtering" }
        guard line.hasPrefix("Video pipeline: decode="),
              let decodeEnd = line.range(of: " filter="),
              let filterEnd = line.range(of: " encoder="),
              let encoderEnd = line.range(of: " input=") else { return nil }
        let decode = String(line[line.index(line.startIndex, offsetBy: "Video pipeline: decode=".count)..<decodeEnd.lowerBound])
        let filter = String(line[decodeEnd.upperBound..<filterEnd.lowerBound])
        let encoding = String(line[filterEnd.upperBound..<encoderEnd.lowerBound])
        guard let name = encoding.split(separator: " ").first else { return nil }
        let hardware = encoding.contains("(hardware required)") ? " hardware" : ""
        return "\(encoder(String(name)))\(hardware)\nDecode: \(decode.hasPrefix("VideoToolbox") ? "VideoToolbox" : decode) · Filters: \(filter)"
    }
}

/// Pulls the familiar `frame= / fps= / …` progress line out of full FFmpeg log text.
enum FFmpegLogStatsParser {

    // Parse key fields independently so we can handle both progress and final lines,
    // even when FFmpeg changes spacing or omits a field.
    private static let frameRegex = try? NSRegularExpression(pattern: "frame=\\s*(\\d+)", options: [])
    private static let fpsRegex = try? NSRegularExpression(pattern: "fps=\\s*([\\d.]+)", options: [])
    private static let sizeRegex = try? NSRegularExpression(pattern: "(?:L)?size=\\s*(\\S+)", options: [])
    private static let timeRegex = try? NSRegularExpression(pattern: "time=\\s*(\\S+)", options: [])
    private static let bitrateRegex = try? NSRegularExpression(pattern: "bitrate=\\s*(\\S+)", options: [])
    private static let speedRegex = try? NSRegularExpression(pattern: "speed=\\s*(\\S+)", options: [])

    static func parseProgressLine(_ raw: String) -> FFmpegEncodingDisplayStats? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let strippedPrefix = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last.map(String.init) ?? line
        return parseStrippedLogContent(stripPrefix(strippedPrefix))
    }

    private static func stripPrefix(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces)
    }

    private static func parseStrippedLogContent(_ line: String) -> FFmpegEncodingDisplayStats? {
        guard line.contains("frame="), line.contains("fps=") else { return nil }
        let stats = FFmpegEncodingDisplayStats(
            frame: firstIntMatch(frameRegex, in: line),
            fps: firstDoubleMatch(fpsRegex, in: line),
            encodedSize: firstStringMatch(sizeRegex, in: line),
            time: firstStringMatch(timeRegex, in: line),
            timeMilliseconds: firstStringMatch(timeRegex, in: line).flatMap(milliseconds(fromFFmpegTime:)),
            throughputBitrate: firstStringMatch(bitrateRegex, in: line),
            speed: firstStringMatch(speedRegex, in: line)
        )
        if stats.frame == nil && stats.fps == nil && stats.encodedSize == nil && stats.time == nil {
            return nil
        }
        return stats
    }

    private static func firstStringMatch(_ regex: NSRegularExpression?, in line: String) -> String? {
        guard let regex else { return nil }
        let nsRange = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: nsRange), match.numberOfRanges > 1 else {
            return nil
        }
        let range = match.range(at: 1)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: line) else { return nil }
        return String(line[swiftRange])
    }

    private static func firstIntMatch(_ regex: NSRegularExpression?, in line: String) -> Int? {
        firstStringMatch(regex, in: line).flatMap(Int.init)
    }

    private static func firstDoubleMatch(_ regex: NSRegularExpression?, in line: String) -> Double? {
        firstStringMatch(regex, in: line).flatMap(Double.init)
    }

    static func milliseconds(fromFFmpegTime value: String) -> Int64? {
        let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else {
            return nil
        }
        let totalSeconds = (hours * 3600.0) + (minutes * 60.0) + seconds
        guard totalSeconds.isFinite, totalSeconds >= 0 else { return nil }
        return Int64((totalSeconds * 1000.0).rounded())
    }
}
