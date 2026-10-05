import Foundation
import Observation

@MainActor
@Observable
/// App-owned conversion session. Views observe it but do not own its worker.
final class ProcessingViewModel {
    private(set) var attemptID: UUID?
    private(set) var input: MediaFile?
    private(set) var config: ConversionConfig?
    private(set) var result: ConversionResult?
    private(set) var isInterrupted = false
    private(set) var backgroundMode = ConversionBackgroundMode.preparing

    @ObservationIgnored private let background: ConversionBackgroundExecuting
    @ObservationIgnored private let makeConverter: (MediaFile, ConversionConfig) throws -> Converter
    @ObservationIgnored private let recordResult: (MediaFile, ConversionConfig, ConversionResult) -> Void
    @ObservationIgnored private let validate: (MediaFile, ConversionConfig) throws -> Void
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let runsTimer: Bool

    init(background: ConversionBackgroundExecuting? = nil,
         makeConverter: ((MediaFile, ConversionConfig) throws -> Converter)? = nil,
         recordResult: ((MediaFile, ConversionConfig, ConversionResult) -> Void)? = nil,
         validate: ((MediaFile, ConversionConfig) throws -> Void)? = nil,
         now: @escaping () -> Date = Date.init,
         runsTimer: Bool = true) {
        self.background = background ?? ConversionBackgroundController(
            platform: SystemBackgroundExecution(), notifications: ConversionNotifications.shared
        )
        self.makeConverter = makeConverter ?? { try ConversionRouter.converter(for: $0, config: $1) }
        self.recordResult = recordResult ?? { ConversionHistoryStore.shared.record(input: $0, config: $1, result: $2) }
        self.validate = validate ?? Self.validateCapabilities
        self.now = now
        self.runsTimer = runsTimer
    }

    var progress: Double = 0
    var elapsedSeconds: TimeInterval = 0
    var passLabel = "Preparing..."
    var showTwoPassProgress = false
    var progressIsDeterminate = true
    /// Latest FFmpeg stats line when the engine emits it.
    var liveStats: FFmpegEncodingDisplayStats?
    var processingBackend = "Preparing…"
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
        if let activity = s.activity { return activity }
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

    @ObservationIgnored private var converter: Converter?
    @ObservationIgnored private var conversionTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    private var startDate: Date?
    @ObservationIgnored private var startedWorkerID: UUID?

    func start(input: MediaFile, config: ConversionConfig) {
        guard !isRunning else { return }
        // Recreating a processing view must not restart a completed or interrupted job.
        guard attemptID == nil || self.input != input || self.config != config else { return }
        let id = UUID()
        attemptID = id
        self.input = input
        self.config = config
        result = nil
        errorMessage = nil
        isInterrupted = false
        progress = 0
        elapsedSeconds = 0
        liveStats = nil
        processingBackend = "Preparing…"
        backgroundMode = .preparing
        do {
            try validate(input, config)
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticsLog.shared.record(error: error, context: "Validate conversion capabilities",
                                         metadata: Self.diagnosticMetadata(input: input, config: config))
            Haptics.error()
            return
        }

        isRunning = true
        let isVideoOutput = (input.category == .video || input.category == .animatedImage)
            && config.outputFormat.category == .video
        showTwoPassProgress = isVideoOutput && config.usesTwoPassVideoEncoding
        progressIsDeterminate = !isVideoOutput || Self.hasKnownDuration(input)
        passLabel = progressIsDeterminate
            ? "Preparing..."
            : (showTwoPassProgress ? "Analyzing source..." : "Reading stream timing...")
        startDate = now()
        startTimer()
        background.start(
            id: id, title: "\(input.originalFilename) → \(config.outputFormat.displayName)", subtitle: passLabel,
            ready: { [weak self] mode in
                guard let self, self.isCurrent(id) else { return }
                self.backgroundMode = mode
                self.beginConversion(id: id, input: input, config: config)
            },
            expired: { [weak self] in
                guard let self, self.isCurrent(id) else { return }
                self.stop(interrupted: true)
            }
        )
    }

    private func isCurrent(_ id: UUID) -> Bool { attemptID == id && isRunning }

    private func beginConversion(id: UUID, input: MediaFile, config: ConversionConfig) {
        guard startedWorkerID != id else { return }
        startedWorkerID = id
        // A cancelled native encoder may still be unwinding. Wait before starting
        // its replacement, while rejecting all callbacks from the old attempt.
        let previous = conversionTask
        conversionTask = Task { [self] in
            await previous?.value
            guard isCurrent(id), !Task.isCancelled else { return }
            do {
                let converter = try makeConverter(input, config)
                self.converter = converter
                let output = try await converter.convert(
                    input: input, config: config,
                    progress: { [weak self] value in
                        Task { @MainActor in
                            guard let self, self.isCurrent(id) else { return }
                            self.updateProgress(value, input: input, config: config)
                        }
                    },
                    encodingStats: { [weak self] stats in
                        Task { @MainActor in
                            guard let self, self.isCurrent(id) else { return }
                            if let backend = stats.processingBackend {
                                self.processingBackend = backend
                            }
                            // Backend-only events must not erase live speed/size values.
                            if stats.processingBackend == nil || stats.timeMilliseconds != nil {
                                self.liveStats = stats
                            }
                            if let milliseconds = stats.timeMilliseconds {
                                self.background.recordProcessedUnits(milliseconds)
                            }
                        }
                    }
                )
                guard isCurrent(id), !Task.isCancelled else {
                    try? FileManager.default.removeItem(at: output.url)
                    return
                }
                // Recording belongs to execution, not to a navigation callback.
                recordResult(input, config, output)
                progress = 1
                progressIsDeterminate = true
                passLabel = "Complete"
                result = output
                finish(success: true)
            } catch {
                guard isCurrent(id) else { return }
                if error is CancellationError || Self.isCancellation(error) {
                    stop(interrupted: false)
                } else {
                    errorMessage = error.localizedDescription
                    var metadata = Self.diagnosticMetadata(input: input, config: config)
                    metadata["Elapsed seconds"] = String(format: "%.3f", elapsedSeconds)
                    metadata["Overall progress"] = String(format: "%.4f", progress)
                    metadata["Pass label"] = passLabel
                    DiagnosticsLog.shared.record(error: error, context: "Convert media", metadata: metadata)
                    finish(success: false)
                    Haptics.error()
                }
            }
        }
    }

    func cancel() { stop(interrupted: false) }

    private func stop(interrupted: Bool) {
        guard isRunning else { return }
        converter?.cancel()
        conversionTask?.cancel()
        isInterrupted = interrupted
        passLabel = interrupted ? "Conversion interrupted" : "Cancelled"
        if interrupted {
            errorMessage = "Background processing ended before the conversion finished. Retry with the app open to start again."
        }
        finish(success: false)
    }

    private func finish(success: Bool) {
        isRunning = false
        if let startDate { elapsedSeconds = now().timeIntervalSince(startDate) }
        timerTask?.cancel()
        timerTask = nil
        converter = nil
        background.finish(success: success)
    }

    func retry(input: MediaFile, config: ConversionConfig) {
        guard !isRunning else { return }
        attemptID = nil
        start(input: input, config: config)
    }

    func dismissAttempt() {
        cancel()
        attemptID = nil
        input = nil
        config = nil
        result = nil
        errorMessage = nil
        isInterrupted = false
    }

    func setBackgrounded(_ backgrounded: Bool) {
        background.setBackgrounded(backgrounded)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if case ConversionError.cancelled = error { return true }
        return false
    }

    private func updateProgress(_ value: Double, input: MediaFile, config: ConversionConfig) {
        guard value.isFinite else { return }
        // Some native stages report 1 before output inspection/finalization.
        progress = max(progress, min(0.99, max(0, value)))
        if input.category == .video || input.category == .animatedImage,
           config.outputFormat.category == .video {
            if !progressIsDeterminate, value > 0, value < 1 { progressIsDeterminate = true }
            if value >= 1 {
                passLabel = "Finishing..."
            } else if !showTwoPassProgress {
                passLabel = progressIsDeterminate ? "Encoding..." : "Reading stream timing..."
            } else if progressIsDeterminate {
                passLabel = progress < 0.45 ? "Analyzing..." : "Encoding..."
            } else {
                passLabel = "Analyzing source..."
            }
        } else {
            passLabel = value >= 1 ? "Finishing..." : "Converting..."
        }
        background.update(fraction: progressIsDeterminate ? progress : nil, stage: passLabel)
    }

    private func startTimer() {
        guard runsTimer else { return }
        timerTask = Task {
            while !Task.isCancelled {
                if let startDate { elapsedSeconds = now().timeIntervalSince(startDate) }
                background.tick()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
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
            "Two-pass video encode": String(config.usesTwoPassVideoEncoding),
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
