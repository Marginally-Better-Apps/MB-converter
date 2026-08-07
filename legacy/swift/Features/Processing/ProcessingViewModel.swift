import Foundation
import Observation

@MainActor
@Observable
final class ProcessingViewModel {
    var progress: Double = 0
    var elapsedSeconds: TimeInterval = 0
    var passLabel = "Preparing..."
    var showTwoPassProgress = false
    var progressIsDeterminate = true
    /// Latest FFmpeg stats line when the engine emits it.
    var liveStats: FFmpegEncodingDisplayStats?
    var errorMessage: String?
    var isRunning = false

    var analyzingProgress: Double {
        guard showTwoPassProgress else { return progress }
        return min(1, max(0, progress / 0.45))
    }

    var encodingProgress: Double {
        guard showTwoPassProgress else { return progress }
        return min(1, max(0, (progress - 0.45) / 0.55))
    }

    /// Progress value shown in UI. For two-pass conversion this resets for each pass.
    var displayProgress: Double {
        guard showTwoPassProgress else { return progress }
        return progress < 0.45 ? analyzingProgress : encodingProgress
    }

    var displayProgressText: String? {
        guard progressIsDeterminate else { return nil }
        return "\(Int(displayProgress * 100))%"
    }

    /// e.g. "Speed 1.25x"
    var liveStatsPrimaryLine: String? {
        guard let s = liveStats else { return nil }
        let parts = [
            s.frame.map { "Frame \($0)" },
            s.fps.flatMap(Self.formatFPS),
            s.speed.flatMap(Self.formatSpeed)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// e.g. elapsed time, encoded size, bitrate
    var liveStatsDetailLine: String? {
        guard let s = liveStats else { return nil }
        let parts = [
            s.time.flatMap(Self.formatTime),
            s.encodedSize.flatMap(Self.formatEncodedSize),
            s.throughputBitrate.flatMap(Self.formatBitrate)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func formatBitrate(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "n/a" else { return nil }
        let numeric = value.filter { $0.isNumber || $0 == "." }
        guard let number = Double(numeric) else { return "Bitrate \(raw.trimmingCharacters(in: .whitespaces))" }
        let bps: Int
        if value.contains("mbit") {
            bps = Int((number * 1_000_000).rounded())
        } else if value.contains("kbit") {
            bps = Int((number * 1_000).rounded())
        } else {
            bps = Int(number.rounded())
        }
        return "Bitrate \(MetadataFormatter.bitrateText(max(0, bps)))"
    }

    private static func formatEncodedSize(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "n/a" else { return nil }
        return "Output \(value)"
    }

    private static func formatFPS(_ value: Double) -> String? {
        guard value.isFinite, value > 0 else { return nil }
        return String(format: "FFmpeg %.1f fps", value)
    }

    private static func formatSpeed(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !value.isEmpty, value != "n/a" else { return nil }
        let numeric = value.replacingOccurrences(of: "x", with: "")
        guard let speed = Double(numeric) else { return "Speed \(raw.trimmingCharacters(in: .whitespaces))" }
        return String(format: "Speed %.2fx", speed)
    }

    private static func formatTime(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.lowercased() != "n/a" else { return nil }
        return "Time \(value)"
    }

    private var converter: Converter?
    private var conversionTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?
    private var started = false
    private var startDate: Date?

    func start(
        input: MediaFile,
        config: ConversionConfig,
        onComplete: @escaping @MainActor (ConversionResult) -> Void
    ) {
        guard !started else { return }
        do {
            try Self.validateCapabilities(input: input, config: config)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            print("[APP ERROR] \(error.localizedDescription)")
            return
        }

        started = true
        isRunning = true
        errorMessage = nil
        liveStats = nil
        let isVideoOutput = (input.category == .video || input.category == .animatedImage)
            && config.outputFormat.category == .video
        showTwoPassProgress = isVideoOutput && !config.usesSinglePassVideoTargetEncode
        progressIsDeterminate = !isVideoOutput || Self.hasKnownDuration(input)
        passLabel = progressIsDeterminate
            ? "Preparing..."
            : (showTwoPassProgress ? "Analyzing source..." : "Reading stream timing...")
        startDate = Date()
        startTimer()

        conversionTask = Task {
            do {
                let converter = try ConversionRouter.converter(for: input, config: config)
                self.converter = converter
                let result = try await converter.convert(
                    input: input,
                    config: config,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            self?.updateProgress(value, input: input, config: config)
                        }
                    },
                    encodingStats: { [weak self] stats in
                        Task { @MainActor in
                            self?.liveStats = stats
                        }
                    }
                )
                isRunning = false
                timerTask?.cancel()
                onComplete(result)
            } catch is CancellationError {
                handleCancellation()
            } catch ConversionError.cancelled {
                handleCancellation()
            } catch {
                isRunning = false
                timerTask?.cancel()
                errorMessage = error.localizedDescription
                Haptics.error()
                print("[APP ERROR] \(error.localizedDescription)")
            }
        }
    }

    func cancel() {
        converter?.cancel()
        conversionTask?.cancel()
        handleCancellation()
    }

    func retry(
        input: MediaFile,
        config: ConversionConfig,
        onComplete: @escaping @MainActor (ConversionResult) -> Void
    ) {
        progress = 0
        elapsedSeconds = 0
        liveStats = nil
        showTwoPassProgress = false
        progressIsDeterminate = true
        passLabel = "Preparing..."
        started = false
        start(input: input, config: config, onComplete: onComplete)
    }

    private func updateProgress(_ value: Double, input: MediaFile, config: ConversionConfig) {
        progress = min(1, max(0, value))
        if input.category == .video || input.category == .animatedImage,
           config.outputFormat.category == .video {
            if !progressIsDeterminate, progress > 0, progress < 1 {
                progressIsDeterminate = true
            }
            if progress >= 1 {
                passLabel = "Finishing..."
            } else if !showTwoPassProgress {
                passLabel = progressIsDeterminate ? "Encoding..." : "Reading stream timing..."
            } else if progressIsDeterminate {
                passLabel = progress < 0.45 ? "Analyzing..." : "Encoding..."
            } else {
                passLabel = "Analyzing source..."
            }
        } else {
            passLabel = "Converting..."
        }
    }

    private func startTimer() {
        timerTask = Task {
            while !Task.isCancelled {
                if let startDate {
                    elapsedSeconds = Date().timeIntervalSince(startDate)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func handleCancellation() {
        isRunning = false
        timerTask?.cancel()
        passLabel = "Cancelled"
    }

    private static func hasKnownDuration(_ input: MediaFile) -> Bool {
        guard let duration = input.duration else { return false }
        return duration.isFinite && duration > 0
    }

    private static func validateCapabilities(input: MediaFile, config: ConversionConfig) throws {
        guard CodecCapability.canEncode(config.outputFormat) else {
            throw ConversionError.codecUnavailable(
                reason: CodecCapability.unsupportedReason(for: config.outputFormat)
                    ?? "The selected output format is not supported by the bundled FFmpeg runtime."
            )
        }

        if let issue = CodecCapability.decodeIssue(for: input) {
            throw ConversionError.codecUnavailable(
                reason: "\(issue.codecLabel) cannot be decoded by the bundled FFmpeg runtime. \(issue.reason)"
            )
        }
    }
}
