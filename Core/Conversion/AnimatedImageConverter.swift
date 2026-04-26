import Foundation
import ImageIO
import UniformTypeIdentifiers

final class AnimatedImageConverter: Converter {
    private let runner = FFmpegCommandRunner()

    func cancel() {
        runner.cancel()
    }

    func convert(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws -> ConversionResult {
        guard input.category == .animatedImage else {
            throw ConversionError.unsupportedConversion
        }

        switch config.outputFormat.category {
        case .video:
            return try await convertToVideo(input: input, config: config, progress: progress, encodingStats: encodingStats)
        case .image:
            return try await extractFirstFrame(input: input, config: config, progress: progress)
        case .audio, .animatedImage:
            throw ConversionError.unsupportedConversion
        }
    }

    private func convertToVideo(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?
    ) async throws -> ConversionResult {
        guard config.outputFormat != .webm else {
            throw ConversionError.unsupportedConversion
        }

        guard let duration = input.duration, duration > 0 else {
            throw ConversionError.invalidInput("GIF duration is unavailable.")
        }

        let outputURL = TempStorage.url(for: config.outputFormat)
        let passLog = TempStorage.url(extension: "log")
        let targetBytes = config.targetSizeBytes ?? input.sizeOnDisk
        var commandConfig = config
        let videoKbps: Int
        if config.operationMode == .autoTarget {
            let plan = AutoTargetPlanner.videoPlan(
                input: input,
                config: config,
                includesAudio: false
            )
            commandConfig.targetDimensions = plan.targetDimensions
            commandConfig.targetFPS = plan.targetFPS
            videoKbps = plan.videoBitrateKbps
        } else {
            let sourceVideoBitrateBps = BitrateCalculator.sourceVideoBitrateBps(
                totalBitrateBps: input.bitrate,
                audioBitrateBps: input.audioBitrate
            )
            let minimumVideoBitrate = BitrateCalculator.minimumVideoBitrateKbps(
                dimensions: config.targetDimensions ?? input.dimensions,
                fps: config.targetFPS ?? input.fps,
                outputFormat: config.outputFormat,
                sourceVideoBitrateBps: sourceVideoBitrateBps
            )
            videoKbps = BitrateCalculator.videoBitrateKbps(
                targetBytes: targetBytes,
                durationSec: duration,
                audioBitrateKbps: 0,
                minimumVideoBitrateKbps: minimumVideoBitrate
            )
        }
        let codec = Self.videoCodec(for: config.outputFormat)
        let hevcTag = config.outputFormat.ffmpegHEVCContainerTagArg
        let pixelFormat = config.outputFormat == .webm ? "" : " -pix_fmt yuv420p"
        let filters = Self.videoFilters(config: commandConfig)
        let fps = Self.fpsArgument(input: input, config: commandConfig)
        let inputPath = FFmpegCommandRunner.quoted(input.url.path)
        let outputPath = FFmpegCommandRunner.quoted(outputURL.path)
        let logPath = FFmpegCommandRunner.quoted(passLog.path)
        let outputMuxer = config.outputFormat.ffmpegOutputMuxerArg
        let pass1Discard = TempStorage.url(extension: config.outputFormat.fileExtension)
        let pass1DiscardPath = FFmpegCommandRunner.quoted(pass1Discard.path)

        let pass2Meta = FFmpegMetadataOptions.outputFlags(config.metadata)
        let pass1 = "-y -i \(inputPath)\(filters)\(fps) -c:v \(codec)\(hevcTag) -b:v \(videoKbps)k -pass 1 -passlogfile \(logPath)\(pixelFormat) -an\(config.outputFormat.ffmpegFirstPassMuxerArg) \(pass1DiscardPath)"
        let pass2 = "-y -i \(inputPath)\(filters)\(fps) -c:v \(codec)\(hevcTag) -b:v \(videoKbps)k -pass 2 -passlogfile \(logPath)\(pixelFormat) -an\(outputMuxer)\(pass2Meta) \(outputPath)"
        let onLog: (@Sendable (String) -> Void)? = {
            guard let encodingStats else { return nil }
            return { @Sendable line in
                if let stats = FFmpegLogStatsParser.parseProgressLine(line) {
                    encodingStats(stats)
                }
            }
        }()

        do {
            progress(0)
            try await runner.run(
                pass1,
                duration: duration,
                progress: { progress($0 * 0.45) },
                onLogLine: onLog,
                onEncodingStats: encodingStats
            )
            try? FileManager.default.removeItem(at: pass1Discard)
            try await runner.run(
                pass2,
                duration: duration,
                progress: { progress(0.45 + $0 * 0.55) },
                onLogLine: onLog,
                onEncodingStats: encodingStats
            )
            progress(1)
            cleanupPassLogs(passLog)
            let media = try await MediaInspector.inspect(url: outputURL)
            return ConversionResult(
                url: outputURL,
                outputFormat: config.outputFormat,
                sizeOnDisk: media.sizeOnDisk,
                dimensions: media.dimensions,
                duration: media.duration,
                fps: media.fps,
                bitrate: media.bitrate,
                videoCodec: media.videoCodec,
                audioCodec: media.audioCodec
            )
        } catch {
            try? FileManager.default.removeItem(at: pass1Discard)
            try? FileManager.default.removeItem(at: outputURL)
            cleanupPassLogs(passLog)
            throw error
        }
    }

    private func extractFirstFrame(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
              let frame = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.invalidInput("Couldn't read GIF frame.")
        }

        let intermediate = TempStorage.url(extension: "png")
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ConversionError.engineFailed("Couldn't create image destination.")
        }
        CGImageDestinationAddImage(destination, frame, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ConversionError.engineFailed("Couldn't encode GIF frame.")
        }
        try (data as Data).write(to: intermediate, options: .atomic)
        progress(0.25)

        do {
            let still = try await MediaInspector.inspect(url: intermediate)
            let result = try await ImageConverter().convert(input: still, config: config) {
                progress(0.25 + $0 * 0.75)
            }
            try? FileManager.default.removeItem(at: intermediate)
            return result
        } catch {
            try? FileManager.default.removeItem(at: intermediate)
            throw error
        }
    }

    private func cleanupPassLogs(_ url: URL) {
        for path in [url.path, "\(url.path)-0.log", "\(url.path)-0.log.mbtree"] {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    private static func videoCodec(for format: OutputFormat) -> String {
        switch format {
        case .mp4_hevc: "hevc_videotoolbox"
        case .webm: "libvpx-vp9"
        default: "h264_videotoolbox"
        }
    }

    private static func videoFilters(config: ConversionConfig) -> String {
        guard let target = config.targetDimensions else { return "" }
        let rawW = Int(target.width.rounded())
        let rawH = Int(target.height.rounded())
        guard let dims = VideoEncodeDimensions.even(width: rawW, height: rawH) else { return "" }
        return " -vf scale=\(dims.width):\(dims.height)"
    }

    private static func fpsArgument(input: MediaFile, config: ConversionConfig) -> String {
        guard let fps = config.targetFPS ?? input.fps else { return "" }
        return " -r \(fps)"
    }
}
