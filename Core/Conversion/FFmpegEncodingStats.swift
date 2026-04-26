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

    var timeSeconds: Double? {
        guard let timeMilliseconds else { return nil }
        return Double(timeMilliseconds) / 1000.0
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
