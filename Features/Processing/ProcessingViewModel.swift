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

    /// Overall conversion progress. Unlike the pass-specific display value, this never
    /// resets when a two-pass encode moves from analysis to encoding.
    var overallProgress: Double {
        min(1, max(0, progress))
    }

    var overallProgressText: String? {
        guard progressIsDeterminate else { return nil }
        return "\(Int((overallProgress * 100).rounded(.down)))%"
    }

    var elapsedText: String {
        MetadataFormatter.durationText(elapsedSeconds)
    }

    /// Stable values for the activity card. Placeholders keep the layout from jumping
    /// while FFmpeg warms up or when a converter does not emit detailed statistics.
    var encoderActivityText: String {
        liveStatsPrimaryLine ?? (isRunning ? "Starting…" : "—")
    }

    var encoderOutputText: String {
        liveStatsDetailLine ?? "—"
    }

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

    /// e.g. "FFmpeg 24.0 fps\nSpeed 1.25x"
    var liveStatsPrimaryLine: String? {
        guard let s = liveStats else { return nil }
        let parts = [
            s.fps.flatMap(Self.formatFPS),
            s.speed.flatMap(Self.formatSpeed)
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    /// Current encoded output size, normalized to MB.
    var liveStatsDetailLine: String? {
        guard let s = liveStats else { return nil }
        return s.encodedSize.flatMap(Self.formatEncodedSize)
    }

    private static func formatEncodedSize(_ raw: String) -> String? {
        let value = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: ",", with: "")
        guard !value.isEmpty, value != "n/a" else { return nil }

        let numericPrefix = value.prefix { $0.isNumber || $0 == "." }
        guard let number = Double(numericPrefix), number.isFinite, number >= 0 else { return nil }

        let unit = value.dropFirst(numericPrefix.count).trimmingCharacters(in: .whitespaces)
        let multiplier: Double
        switch unit {
        case "", "b":
            multiplier = 1
        case "kb", "kib":
            multiplier = 1_024
        case "mb", "mib":
            multiplier = 1_024 * 1_024
        case "gb", "gib":
            multiplier = 1_024 * 1_024 * 1_024
        default:
            return nil
        }

        return String(format: "%.1f MB", number * multiplier / 1_000_000)
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
            DiagnosticsLog.shared.record(
                error: error,
                context: "Validate conversion capabilities",
                metadata: Self.diagnosticMetadata(input: input, config: config)
            )
            Haptics.error()
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
                var metadata = Self.diagnosticMetadata(input: input, config: config)
                metadata["Elapsed seconds"] = String(format: "%.3f", elapsedSeconds)
                metadata["Overall progress"] = String(format: "%.4f", progress)
                metadata["Pass label"] = passLabel
                if let liveStatsPrimaryLine {
                    metadata["Latest encoder activity"] = liveStatsPrimaryLine
                }
                if let liveStatsDetailLine {
                    metadata["Latest encoder output"] = liveStatsDetailLine
                }
                DiagnosticsLog.shared.record(
                    error: error,
                    context: "Convert media",
                    metadata: metadata
                )
                Haptics.error()
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

    private static func diagnosticMetadata(
        input: MediaFile,
        config: ConversionConfig
    ) -> [String: String] {
        var metadata: [String: String] = [
            "Input filename": input.originalFilename,
            "Input category": input.category.rawValue,
            "Input container": input.containerFormat,
            "Input bytes": String(input.sizeOnDisk),
            "Output format": config.outputFormat.displayName,
            "Operation mode": config.operationMode.rawValue,
            "Rotation degrees": String(config.mediaRotation.rawValue),
            "Single-pass target encode": String(config.usesSinglePassVideoTargetEncode),
            "Prefer remux": String(config.prefersRemuxWhenPossible),
            "Strip all metadata": String(config.metadata.stripAll)
        ]

        if let dimensions = input.dimensions {
            metadata["Input dimensions"] = "\(Int(dimensions.width))x\(Int(dimensions.height))"
        }
        if let duration = input.duration {
            metadata["Input duration seconds"] = String(format: "%.6f", duration)
        }
        if let fps = input.fps {
            metadata["Input FPS"] = String(format: "%.4f", fps)
        }
        if let bitrate = input.bitrate {
            metadata["Input bitrate bps"] = String(bitrate)
        }
        if let videoCodec = input.videoCodec {
            metadata["Input video codec"] = videoCodec
        }
        if let audioCodec = input.audioCodec {
            metadata["Input audio codec"] = audioCodec
        }
        if let dimensions = config.targetDimensions {
            metadata["Target dimensions"] = "\(Int(dimensions.width))x\(Int(dimensions.height))"
        }
        if let fps = config.targetFPS {
            metadata["Target FPS"] = String(format: "%.4f", fps)
        }
        if let bytes = config.targetSizeBytes {
            metadata["Target bytes"] = String(bytes)
        }
        if let quality = config.imageQuality {
            metadata["Image quality"] = String(format: "%.4f", quality)
        }
        if let quality = config.videoQuality {
            metadata["Video quality"] = String(format: "%.4f", quality)
        }
        if let bitrate = config.preferredAudioBitrateKbps {
            metadata["Preferred audio kbps"] = String(bitrate)
        }
        if let crop = config.cropRegion {
            metadata["Crop"] = "x=\(crop.x), y=\(crop.y), width=\(crop.width), height=\(crop.height)"
        }
        return metadata
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
