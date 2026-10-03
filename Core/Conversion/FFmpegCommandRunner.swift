import Foundation

#if canImport(MBFFmpegBridge)
import MBFFmpegBridge
#endif

/// Owns cancellation for this converter only. Each invocation has an independent callback context.
final class FFmpegCommandRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var activeRuns: [UUID: FFmpegRunContext] = [:]

    func cancel() {
        lock.lock()
        let runs = Array(activeRuns.values)
        lock.unlock()
        runs.forEach { $0.cancel() }
    }

    func run(
        _ command: String,
        duration: TimeInterval?,
        progress: @escaping @Sendable (Double) -> Void,
        onLogLine: (@Sendable (String) -> Void)? = nil,
        onEncodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws {
        let arguments = try Self.arguments(in: command)
        guard !arguments.isEmpty else {
            throw ConversionError.engineFailed("The FFmpeg command is empty.")
        }
        #if canImport(MBFFmpegBridge)
        if let backend = ConversionBackendDescription.command(arguments: arguments) {
            onEncodingStats?(FFmpegEncodingDisplayStats(processingBackend: backend))
        }
        let context = FFmpegRunContext(duration: duration, progress: progress, onLogLine: onLogLine, onEncodingStats: onEncodingStats)
        let identifier = register(context)
        defer { unregister(identifier) }
        try await withTaskCancellationHandler {
            guard !Task.isCancelled else { throw ConversionError.cancelled }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // The bridge is synchronous. Never run its codec work on the caller's actor.
                DispatchQueue.global(qos: .userInitiated).async {
                    if context.isCancelled {
                        continuation.resume(throwing: ConversionError.cancelled)
                        return
                    }
                    let strings = (["ffmpeg"] + arguments).map { strdup($0) }
                    defer { strings.forEach { free($0) } }
                    guard strings.allSatisfy({ $0 != nil }) else {
                        continuation.resume(throwing: ConversionError.engineFailed("Could not allocate FFmpeg arguments."))
                        return
                    }
                    let pointers = strings.map { $0.map { UnsafePointer<CChar>($0) } }
                    let opaque = Unmanaged.passUnretained(context).toOpaque()
                    let result = pointers.withUnsafeBufferPointer { buffer in
                        mbf_execute(Int32(buffer.count), buffer.baseAddress, { opaque, message in
                            guard let opaque, let message else { return }
                            Unmanaged<FFmpegRunContext>.fromOpaque(opaque).takeUnretainedValue().log(String(cString: message))
                        }, { opaque, outputTime, bytes, frames in
                            guard let opaque else { return }
                            Unmanaged<FFmpegRunContext>.fromOpaque(opaque).takeUnretainedValue()
                                .update(outputTimeMicroseconds: outputTime, bytes: bytes, frames: frames)
                        }, { opaque in
                            guard let opaque else { return 0 }
                            return Unmanaged<FFmpegRunContext>.fromOpaque(opaque).takeUnretainedValue().isCancelled ? 1 : 0
                        }, opaque)
                    }
                    if context.isCancelled {
                        continuation.resume(throwing: ConversionError.cancelled)
                    } else if result == 0 {
                        progress(1)
                        continuation.resume(returning: ())
                    } else {
                        let logs = context.recentLogLines
                        let detail = Self.errorDetail(from: logs).map { ": \($0)" } ?? ""
                        let message = "FFmpeg exited with code \(result)\(detail)"
                        DiagnosticsLog.shared.record(
                            message: message,
                            context: "FFmpeg command failed",
                            metadata: ["Return code": String(result)],
                            details: "Command:\n\(command)\n\nRecent FFmpeg output:\n\(logs.joined(separator: "\n"))"
                        )
                        continuation.resume(throwing: ConversionError.engineFailed(message))
                    }
                }
            }
        } onCancel: {
            // Task cancellation is scoped to this run, including while it is queued.
            context.cancel()
        }
        #else
        throw ConversionError.engineFailed("The bundled FFmpeg bridge is not linked. Build the custom FFmpeg frameworks first.")
        #endif
    }

    private func register(_ context: FFmpegRunContext) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let identifier = UUID()
        activeRuns[identifier] = context
        return identifier
    }

    private func unregister(_ identifier: UUID) {
        lock.lock()
        defer { lock.unlock() }
        activeRuns.removeValue(forKey: identifier)
    }

    static func quoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    /// Decode our shell-style argument strings without invoking a shell or expanding input.
    /// Handles adjacent quoted segments, empty arguments, and paths containing apostrophes.
    static func arguments(in command: String) throws -> [String] {
        enum Quote { case single, double }
        var quote: Quote?
        var arguments: [String] = []
        var current = ""
        var hasArgument = false
        let characters = Array(command)
        var index = 0
        func invalid(_ reason: String) -> ConversionError {
            .engineFailed("Invalid FFmpeg command: \(reason)")
        }
        while index < characters.count {
            let character = characters[index]
            guard character != "\0" else { throw invalid("NUL characters are not permitted.") }
            if quote == .single {
                if character == "'" { quote = nil } else { current.append(character) }
            } else if character == "\\" {
                guard index + 1 < characters.count else { throw invalid("trailing escape.") }
                let next = characters[index + 1]
                guard next != "\0" else { throw invalid("NUL characters are not permitted.") }
                if quote == .double && next != "\\" && next != "\"" && next != "$" && next != "`" && next != "\n" {
                    current.append(character)
                } else {
                    index += 1
                    if next != "\n" { current.append(next); hasArgument = true }
                }
            } else if quote == .double {
                if character == "\"" { quote = nil } else { current.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character == "'" ? .single : .double
                hasArgument = true
            } else if character.isWhitespace {
                if hasArgument {
                    arguments.append(current)
                    current = ""
                    hasArgument = false
                }
            } else {
                current.append(character)
                hasArgument = true
            }
            index += 1
        }
        guard quote == nil else { throw invalid("unterminated quoted argument.") }
        if hasArgument { arguments.append(current) }
        return arguments
    }

    private static func errorDetail(from lines: [String]) -> String? {
        if let limitation = lines.last(where: { $0.hasPrefix("Video limitation: ") }) {
            return String(limitation.dropFirst("Video limitation: ".count))
        }
        let prioritized = lines.reversed().first { line in
            let n = line.lowercased()
            return n.contains("error") || n.contains("failed") || n.contains("unknown encoder")
                || n.contains("invalid argument") || n.contains("could not") || n.contains("not found")
        }
        return prioritized ?? lines.reversed().first { line in
            let n = line.lowercased()
            return !n.isEmpty && !n.hasPrefix("ffmpeg version") && !n.hasPrefix("configuration:")
                && !n.contains("copyright (c)") && !n.contains("built with")
                && !["libavutil", "libavcodec", "libavformat", "libavdevice", "libavfilter", "libswscale", "libswresample"].contains(where: n.contains)
        }
    }
}

private final class FFmpegRunContext: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var logLines: [String] = []
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var highestProgress = 0.0
    private let duration: TimeInterval?
    private let progress: @Sendable (Double) -> Void
    private let onLogLine: (@Sendable (String) -> Void)?
    private let onEncodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?

    init(duration: TimeInterval?, progress: @escaping @Sendable (Double) -> Void,
         onLogLine: (@Sendable (String) -> Void)?, onEncodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?) {
        self.duration = duration
        self.progress = progress
        self.onLogLine = onLogLine
        self.onEncodingStats = onEncodingStats
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    var recentLogLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return logLines
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func log(_ text: String) {
        let lines = text.split(whereSeparator: { $0.isNewline }).map { String($0.prefix(4_096)) }
        lock.lock()
        if lines.contains(where: { $0.hasPrefix("MBF_RETRY ") }) {
            startedAt = ProcessInfo.processInfo.systemUptime
        }
        logLines.append(contentsOf: lines)
        if logLines.count > 120 { logLines.removeFirst(logLines.count - 120) }
        lock.unlock()
        for line in lines {
            if let backend = ConversionBackendDescription.pipeline(logLine: line) {
                onEncodingStats?(FFmpegEncodingDisplayStats(processingBackend: backend))
            }
        }
        onLogLine?(text)
    }

    func update(outputTimeMicroseconds: Int64, bytes: Int64, frames: Int64) {
        guard !isCancelled, outputTimeMicroseconds >= 0 else { return }
        let seconds = Double(outputTimeMicroseconds) / 1_000_000
        lock.lock()
        let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - startedAt)
        let fraction = duration.flatMap { $0.isFinite && $0 > 0 ? min(1, max(0, seconds / $0)) : nil }
        if let fraction { highestProgress = max(highestProgress, fraction) }
        let displayedProgress = highestProgress
        lock.unlock()
        onEncodingStats?(FFmpegEncodingDisplayStats(
            frame: frames >= 0 ? Int(clamping: frames) : nil,
            fps: frames >= 0 ? Double(frames) / elapsed : nil,
            encodedSize: bytes >= 0 ? "\(bytes)B" : nil,
            time: String(format: "%02d:%02d:%05.2f", Int(seconds / 3600), Int(seconds.truncatingRemainder(dividingBy: 3600) / 60), seconds.truncatingRemainder(dividingBy: 60)),
            timeMilliseconds: outputTimeMicroseconds / 1_000,
            throughputBitrate: bytes >= 0 && seconds > 0 ? String(format: "%.1fkbits/s", Double(bytes) * 8 / seconds / 1_000) : nil,
            speed: String(format: "%.2fx", seconds / elapsed)
        ))
        if fraction != nil { progress(displayedProgress) }
    }
}
