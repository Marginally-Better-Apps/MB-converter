import Foundation

final class VideoConverter: Converter {
    private let runner = FFmpegCommandRunner()
    private let audioConverter = AudioConverter()

    func cancel() {
        runner.cancel()
        audioConverter.cancel()
    }

    func convert(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws -> ConversionResult {
        guard input.category == .video else {
            throw ConversionError.unsupportedConversion
        }

        switch config.outputFormat.category {
        case .video:
            return try await convertVideo(input: input, config: config, progress: progress, encodingStats: encodingStats)
        case .audio:
            return try await audioConverter.convert(input: input, config: config, progress: progress, encodingStats: encodingStats)
        case .image:
            return try await extractFrame(input: input, config: config, progress: progress)
        case .animatedImage:
            throw ConversionError.unsupportedConversion
        }
    }

    private func convertVideo(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?
    ) async throws -> ConversionResult {
        guard config.outputFormat != .webm else {
            throw ConversionError.unsupportedConversion
        }

        let duration = input.duration.flatMap { $0 > 0 ? $0 : nil }

        if Self.shouldRemux(input: input, config: config) {
            do {
                return try await remuxVideo(
                    input: input,
                    config: config,
                    duration: duration,
                    progress: progress,
                    encodingStats: encodingStats
                )
            } catch {
                if Self.isCancellation(error) {
                    throw error
                }
                // If stream-copy fails despite compatible-looking metadata, fall back to the normal encode path.
            }
        }

        let outputURL = TempStorage.url(for: config.outputFormat)
        let passLog = TempStorage.url(extension: "log")
        let targetBytes = config.targetSizeBytes ?? input.sizeOnDisk
        let hasAudio = input.audioCodec != nil
        var commandConfig = config
        let audioBitrate: Int
        var videoKbps: Int
        let sourceVideoBitrateBps = BitrateCalculator.sourceVideoBitrateBps(
            totalBitrateBps: input.bitrate,
            audioBitrateBps: input.audioBitrate
        )

        if config.operationMode == .autoTarget {
            let plan = AutoTargetPlanner.videoPlan(
                input: Self.planningInput(input: input, config: config),
                config: config,
                includesAudio: hasAudio
            )
            commandConfig.targetDimensions = plan.targetDimensions
            commandConfig.targetFPS = plan.targetFPS
            audioBitrate = plan.audioBitrateKbps
            videoKbps = plan.videoBitrateKbps
        } else {
            let suggestedAudioKbps = hasAudio
                ? (duration.map { BitrateCalculator.suggestedAudioBitrate(for: targetBytes, durationSec: $0) } ?? 128)
                : 0
            let baseRequestedKbps = hasAudio
                ? (config.preferredAudioBitrateKbps ?? suggestedAudioKbps)
                : 0
            let requestedAudioKbps = hasAudio
                ? BitrateCalculator.capAudioEncodeKbps(
                    requested: baseRequestedKbps,
                    sourceBps: input.audioBitrate
                )
                : 0
            audioBitrate = config.outputFormat == .webm
                ? min(requestedAudioKbps, 128)
                : requestedAudioKbps
            let minimumVideoBitrate = BitrateCalculator.minimumVideoBitrateKbps(
                dimensions: Self.effectiveVideoDimensions(input: input, config: config),
                fps: config.targetFPS ?? input.fps,
                outputFormat: config.outputFormat,
                sourceVideoBitrateBps: sourceVideoBitrateBps
            )
            if let duration {
                videoKbps = BitrateCalculator.videoBitrateKbps(
                    targetBytes: targetBytes,
                    durationSec: duration,
                    audioBitrateKbps: audioBitrate,
                    minimumVideoBitrateKbps: minimumVideoBitrate
                )
            } else {
                // Raw/elementary streams (e.g. .m2v) may report unknown duration; keep conversion available
                // by falling back to a source-informed bitrate heuristic.
                let sourceVideoKbps = sourceVideoBitrateBps.map { max(1, $0 / 1000) } ?? minimumVideoBitrate
                videoKbps = max(minimumVideoBitrate, sourceVideoKbps)
            }
        }

        if duration == nil {
            videoKbps = BitrateCalculator.qualityDrivenVideoBitrateKbps(
                quality: config.videoQuality ?? 0.72,
                dimensions: Self.effectiveVideoDimensions(input: input, config: commandConfig),
                fps: commandConfig.targetFPS ?? input.fps,
                outputFormat: config.outputFormat,
                sourceVideoBitrateBps: sourceVideoBitrateBps
            )
        }

        let videoCodec = Self.videoCodec(for: config.outputFormat)
        let hevcTag = config.outputFormat.ffmpegHEVCContainerTagArg
        let audioCodec = config.outputFormat == .webm ? "libopus" : "aac"
        let audioArguments = hasAudio ? " -c:a \(audioCodec) -b:a \(audioBitrate)k" : " -an"
        let filters = Self.videoFilters(input: input, config: commandConfig)
        let fps = Self.fpsArgument(input: input, config: commandConfig)
        let inputPath = FFmpegCommandRunner.quoted(input.url.path)
        let outputPath = FFmpegCommandRunner.quoted(outputURL.path)
        let logPath = FFmpegCommandRunner.quoted(passLog.path)
        let fastStart = config.outputFormat == .webm ? "" : " -movflags +faststart"
        let outputMuxer = config.outputFormat.ffmpegOutputMuxerArg
        let pass1Discard = TempStorage.url(extension: config.outputFormat.fileExtension)
        let pass1DiscardPath = FFmpegCommandRunner.quoted(pass1Discard.path)

        let pass2Meta = FFmpegMetadataOptions.outputFlags(config.metadata)
        let pass1 = "-y -i \(inputPath)\(filters)\(fps) -c:v \(videoCodec)\(hevcTag) -b:v \(videoKbps)k -pass 1 -passlogfile \(logPath) -an\(config.outputFormat.ffmpegFirstPassMuxerArg) \(pass1DiscardPath)"
        let pass2 = "-y -i \(inputPath)\(filters)\(fps) -c:v \(videoCodec)\(hevcTag) -b:v \(videoKbps)k -pass 2 -passlogfile \(logPath)\(audioArguments)\(outputMuxer)\(fastStart)\(pass2Meta) \(outputPath)"
        let pass1Estimate = FFmpegPassProgressEstimate()
        let pass1Stats: @Sendable (FFmpegEncodingDisplayStats) -> Void = { stats in
            pass1Estimate.record(stats)
            encodingStats?(stats)
        }
        let pass2Stats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = encodingStats
        let pass1Log = Self.logStatsHandler(for: pass1Stats)
        let pass2Log = Self.logStatsHandler(for: pass2Stats)

        let durationForPass1 = duration

        func durationForPass2() -> TimeInterval? {
            duration ?? pass1Estimate.duration
        }

        func finishAnalyzingIfDurationWasLearned() {
            guard duration == nil, durationForPass2() != nil else { return }
            progress(0.45)
        }

        do {
            progress(0)
            try await runner.run(
                pass1,
                duration: durationForPass1,
                progress: { progress($0 * 0.45) },
                onLogLine: pass1Log,
                onEncodingStats: pass1Stats
            )
            finishAnalyzingIfDurationWasLearned()
            try? FileManager.default.removeItem(at: pass1Discard)
            try await runner.run(
                pass2,
                duration: durationForPass2(),
                progress: { progress(0.45 + $0 * 0.55) },
                onLogLine: pass2Log,
                onEncodingStats: pass2Stats
            )
            progress(1)
            cleanupPassLogs(passLog)
            return try await result(
                for: outputURL,
                format: config.outputFormat,
                audioEncodeKbps: hasAudio ? audioBitrate : nil
            )
        } catch {
            try? FileManager.default.removeItem(at: pass1Discard)
            try? FileManager.default.removeItem(at: outputURL)
            cleanupPassLogs(passLog)
            throw error
        }
    }

    private static func logStatsHandler(
        for handler: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?
    ) -> (@Sendable (String) -> Void)? {
        guard let handler else { return nil }
        return { @Sendable line in
            if let stats = FFmpegLogStatsParser.parseProgressLine(line) {
                handler(stats)
            }
        }
    }

    private func remuxVideo(
        input: MediaFile,
        config: ConversionConfig,
        duration: TimeInterval?,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?
    ) async throws -> ConversionResult {
        let outputURL = TempStorage.url(for: config.outputFormat)
        let inputPath = FFmpegCommandRunner.quoted(input.url.path)
        let outputPath = FFmpegCommandRunner.quoted(outputURL.path)
        let outputMuxer = config.outputFormat.ffmpegOutputMuxerArg
        let fastStart = config.outputFormat == .webm ? "" : " -movflags +faststart"
        let hevcTag = config.outputFormat.ffmpegHEVCContainerTagArg
        let meta = FFmpegMetadataOptions.outputFlags(config.metadata)
        let command = "-y -i \(inputPath) -map 0:v:0 -map 0:a:0? -c copy\(hevcTag)\(outputMuxer)\(fastStart)\(meta) \(outputPath)"
        do {
            progress(0)
            try await runner.run(
                command,
                duration: duration,
                progress: progress,
                onEncodingStats: encodingStats
            )
            progress(1)
            return try await result(for: outputURL, format: config.outputFormat)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func extractFrame(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        let needsImageTuning = config.targetSizeBytes != nil && config.outputFormat.supportsTargetSize
        let outputURL = needsImageTuning ? TempStorage.url(extension: "png") : TempStorage.url(for: config.outputFormat)
        let time = config.frameTimeForExtraction ?? 0
        let extractionFormat: OutputFormat = needsImageTuning ? .png : config.outputFormat
        let outputMuxer = extractionFormat.ffmpegOutputMuxerArg
        let imageCodecArg: String = {
            switch extractionFormat {
            case .jpg:
                return " -c:v mjpeg"
            case .png:
                return " -c:v png"
            default:
                return ""
            }
        }()
        let meta = FFmpegMetadataOptions.outputFlags(config.metadata)
        let filters = Self.videoFilters(input: input, config: config)
        let command = "-y -ss \(time) -i \(FFmpegCommandRunner.quoted(input.url.path))\(filters) -frames:v 1\(imageCodecArg)\(outputMuxer)\(meta) \(FFmpegCommandRunner.quoted(outputURL.path))"

        do {
            try await runner.run(command, duration: input.duration) { progress($0 * 0.5) }
            if needsImageTuning {
                let still = try await MediaInspector.inspect(url: outputURL)
                var imageConfig = config
                imageConfig.cropRegion = nil
                imageConfig.targetDimensions = nil
                let result = try await ImageConverter().convert(input: still, config: imageConfig) { progress(0.5 + $0 * 0.5) }
                try? FileManager.default.removeItem(at: outputURL)
                return result
            }
            progress(1)
            return try await result(for: outputURL, format: config.outputFormat)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func result(
        for url: URL,
        format: OutputFormat,
        audioEncodeKbps: Int? = nil
    ) async throws -> ConversionResult {
        let media = try await MediaInspector.inspect(url: url)
        let outAudioBps: Int? = (format.category == .video)
            ? (audioEncodeKbps.map { $0 * 1000 } ?? media.audioBitrate)
            : nil
        return ConversionResult(
            url: url,
            outputFormat: format,
            sizeOnDisk: media.sizeOnDisk,
            dimensions: media.dimensions,
            duration: media.duration,
            fps: media.fps,
            bitrate: media.bitrate,
            audioBitrate: outAudioBps,
            videoCodec: media.videoCodec,
            audioCodec: media.audioCodec
        )
    }

    private func cleanupPassLogs(_ url: URL) {
        let paths = [
            url.path,
            "\(url.path)-0.log",
            "\(url.path)-0.log.mbtree"
        ]
        for path in paths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func shouldRemux(input: MediaFile, config: ConversionConfig) -> Bool {
        config.prefersRemuxWhenPossible
            && config.cropRegion == nil
            && config.targetDimensions == nil
            && config.targetFPS == nil
            && config.outputFormat.canRemuxVideoCodec(input.videoCodec)
            && config.outputFormat.canRemuxAudioCodec(input.audioCodec)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if case ConversionError.cancelled = error {
            return true
        }
        return error is CancellationError
    }

    private static func videoCodec(for format: OutputFormat) -> String {
        switch format {
        case .mp4_hevc: "hevc_videotoolbox"
        case .webm: "libvpx-vp9"
        default: "h264_videotoolbox"
        }
    }

    private static func videoFilters(input: MediaFile, config: ConversionConfig) -> String {
        var filters: [String] = []

        if let crop = config.cropRegion,
           let cropFilter = cropFilter(input: input, crop: crop) {
            filters.append(cropFilter)
        }

        if let target = config.targetDimensions {
            let rawW = Int(target.width.rounded())
            let rawH = Int(target.height.rounded())
            if let dims = VideoEncodeDimensions.even(width: rawW, height: rawH) {
                filters.append("scale=\(dims.width):\(dims.height)")
            }
        }

        guard !filters.isEmpty else { return "" }
        return " -vf \(filters.joined(separator: ","))"
    }

    private static func cropFilter(input: MediaFile, crop: CropRegion) -> String? {
        guard let source = input.dimensions,
              let clamped = crop.clamped(to: source),
              !clamped.isEffectivelyFullFrame(for: source)
        else { return nil }

        let sourceWidth = Int(source.width.rounded())
        let sourceHeight = Int(source.height.rounded())
        guard sourceWidth > 1, sourceHeight > 1 else { return nil }

        var width = max(2, Int(clamped.width.rounded()))
        var height = max(2, Int(clamped.height.rounded()))
        width -= width % 2
        height -= height % 2
        width = min(width, sourceWidth - sourceWidth % 2)
        height = min(height, sourceHeight - sourceHeight % 2)

        var x = max(0, Int(clamped.x.rounded()))
        var y = max(0, Int(clamped.y.rounded()))
        x = min(x, max(0, sourceWidth - width))
        y = min(y, max(0, sourceHeight - height))
        x -= x % 2
        y -= y % 2

        return "crop=\(width):\(height):\(x):\(y)"
    }

    private static func effectiveVideoDimensions(input: MediaFile, config: ConversionConfig) -> CGSize? {
        config.targetDimensions
            ?? config.cropRegion?.clamped(to: input.dimensions ?? .zero)?.dimensions
            ?? input.dimensions
    }

    private static func planningInput(input: MediaFile, config: ConversionConfig) -> MediaFile {
        guard let source = input.dimensions,
              let crop = config.cropRegion?.clamped(to: source),
              !crop.isEffectivelyFullFrame(for: source)
        else { return input }

        return MediaFile(
            id: input.id,
            url: input.url,
            originalFilename: input.originalFilename,
            category: input.category,
            sizeOnDisk: input.sizeOnDisk,
            dimensions: crop.dimensions,
            duration: input.duration,
            fps: input.fps,
            bitrate: input.bitrate,
            audioBitrate: input.audioBitrate,
            videoCodec: input.videoCodec,
            audioCodec: input.audioCodec,
            containerFormat: input.containerFormat
        )
    }

    private static func fpsArgument(input: MediaFile, config: ConversionConfig) -> String {
        guard let target = config.targetFPS,
              let source = input.fps,
              target < source else { return "" }
        return " -r \(target)"
    }

}

private final class FFmpegPassProgressEstimate: @unchecked Sendable {
    private let lock = NSLock()
    private var maximumTimeMilliseconds: Int64 = 0

    var duration: TimeInterval? {
        lock.lock()
        defer { lock.unlock() }
        guard maximumTimeMilliseconds > 0 else { return nil }
        return Double(maximumTimeMilliseconds) / 1000.0
    }

    func record(_ stats: FFmpegEncodingDisplayStats) {
        guard let timeMilliseconds = stats.timeMilliseconds, timeMilliseconds > 0 else { return }
        lock.lock()
        maximumTimeMilliseconds = max(maximumTimeMilliseconds, timeMilliseconds)
        lock.unlock()
    }
}
