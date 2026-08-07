import Foundation

#if canImport(ffmpegkit)
@preconcurrency import ffmpegkit
#endif

final class FFmpegCommandRunner {
    private var cancelled = false

    func cancel() {
        cancelled = true
        #if canImport(ffmpegkit)
        FFmpegKit.cancel()
        #endif
    }

    func run(
        _ command: String,
        duration: TimeInterval?,
        progress: @escaping @Sendable (Double) -> Void,
        onLogLine: (@Sendable (String) -> Void)? = nil,
        onEncodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws {
        cancelled = false

        #if canImport(ffmpegkit)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let guardBox = ContinuationGuard(continuation)
                var recentLogLines: [String] = []
                var didLogFirstStatistics = false
                var lastStatisticsLogTime = -5_000
                let logHandler: ((Log?) -> Void) = { (log: Log?) in
                    guard let log, let text = log.getMessage() else { return }
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        recentLogLines.append(trimmed)
                        if recentLogLines.count > 120 {
                            recentLogLines.removeFirst(recentLogLines.count - 120)
                        }
                    }
                    onLogLine?(text)
                    Self.logFFmpegErrorIfNeeded(text)
                }
                _ = FFmpegKit.executeAsync(command, withCompleteCallback: { session in
                    let returnCode = session?.getReturnCode()
                    if ReturnCode.isSuccess(returnCode) {
                        guardBox.resume(returning: ())
                    } else if ReturnCode.isCancel(returnCode) {
                        guardBox.resume(throwing: ConversionError.cancelled)
                    } else {
                        let returnCodeText: String
                        if let returnCode {
                            returnCodeText = String(returnCode.getValue())
                        } else {
                            returnCodeText = "unknown"
                        }
                        let failStack = session?.getFailStackTrace()?.trimmingCharacters(in: .whitespacesAndNewlines)
                        let message: String
                        if let failStack, !failStack.isEmpty {
                            message = failStack
                        } else if let detail = Self.errorDetail(from: recentLogLines) {
                            message = "FFmpeg exited with code \(returnCodeText): \(detail)"
                        } else {
                            message = "FFmpeg exited with code \(returnCodeText)"
                        }
                        print("[FFMPEG COMMAND] \(command)")
                        print("[FFMPEG ERROR] \(message)")
                        guardBox.resume(throwing: ConversionError.engineFailed(message))
                    }
                }, withLogCallback: logHandler, withStatisticsCallback: { statistics in
                    let currentMillisecondsInt = Int(statistics?.getTime() ?? 0)
                    if !didLogFirstStatistics || currentMillisecondsInt - lastStatisticsLogTime >= 5_000 {
                        didLogFirstStatistics = true
                        lastStatisticsLogTime = currentMillisecondsInt
                    }
                    if let statistics, let onEncodingStats {
                        onEncodingStats(
                            FFmpegEncodingDisplayStats(
                                frame: Int(statistics.getVideoFrameNumber()),
                                fps: Double(statistics.getVideoFps()),
                                encodedSize: "\(statistics.getSize())kB",
                                time: Self.formatFfmpegTime(milliseconds: Int64(statistics.getTime())),
                                timeMilliseconds: Int64(statistics.getTime()),
                                throughputBitrate: String(format: "%.1fkbits/s", statistics.getBitrate()),
                                speed: "\(statistics.getSpeed())x"
                            )
                        )
                    }
                    guard let duration, duration > 0 else {
                        // Duration can be unknown for raw/elementary streams (e.g. .hevc).
                        // In that case we surface real FFmpeg stats but do not invent a percent.
                        return
                    }
                    let currentMilliseconds = Double(statistics?.getTime() ?? 0)
                    let fraction = min(1, max(0, currentMilliseconds / (duration * 1000)))
                    progress(fraction)
                })
            }
        } onCancel: {
            self.cancel()
        }

        if cancelled {
            throw ConversionError.cancelled
        }
        #else
        throw ConversionError.engineFailed("FFmpegKit is not linked.")
        #endif
    }

    static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func formatFfmpegTime(milliseconds: Int64) -> String {
        let totalSeconds = max(0, Double(milliseconds) / 1000.0)
        let hours = Int(totalSeconds / 3600)
        let minutes = Int((totalSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
        let seconds = totalSeconds.truncatingRemainder(dividingBy: 60)
        return String(format: "%02d:%02d:%05.2f", hours, minutes, seconds)
    }

    private static func logFFmpegErrorIfNeeded(_ line: String) {
        let normalized = line.lowercased()
        guard normalized.contains("error") || normalized.contains("failed") else { return }
        print("[FFMPEG STDERR] \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
    }

    private static func errorDetail(from lines: [String]) -> String? {
        let prioritized = lines.reversed().filter { line in
            let n = line.lowercased()
            return n.contains("error")
                || n.contains("failed")
                || n.contains("unknown encoder")
                || n.contains("invalid argument")
                || n.contains("could not")
                || n.contains("not found")
        }
        if let first = prioritized.first {
            return first
        }
        return lines.reversed().first(where: { line in
            guard !line.isEmpty else { return false }
            return !Self.isLikelyFfmpegBannerLine(line)
        })
    }

    /// FFmpeg logs the library banner to stderr; fast failures sometimes leave only those lines in the buffer.
    private static func isLikelyFfmpegBannerLine(_ line: String) -> Bool {
        let n = line.lowercased()
        if n.hasPrefix("ffmpeg version") { return true }
        if n.contains("copyright (c)") && n.contains("ffmpeg") { return true }
        if n.contains("built with") { return true }
        if n.hasPrefix("configuration:") { return true }
        if n.contains("libavutil") && n.contains("/") { return true }
        if n.contains("libavcodec") && n.contains("/") { return true }
        if n.contains("libavformat") && n.contains("/") { return true }
        if n.contains("libavdevice") && n.contains("/") { return true }
        if n.contains("libavfilter") && n.contains("/") { return true }
        if n.contains("libswscale") && n.contains("/") { return true }
        if n.contains("libswresample") && n.contains("/") { return true }
        if n.contains("libpostproc") && n.contains("/") { return true }
        return false
    }

}

private final class ContinuationGuard<T> {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(returning: value)
        continuation = nil
    }

    func resume(throwing error: Error) {
        lock.lock()
        defer { lock.unlock() }
        continuation?.resume(throwing: error)
        continuation = nil
    }
}
