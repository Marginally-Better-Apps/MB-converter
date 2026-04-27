import AVFoundation
import CoreMedia
import Foundation

final class AudioConverter: Converter {
    private static let processingQueue = DispatchQueue(label: "converter.native-audio")

    private let lock = NSLock()
    private var activeReader: AVAssetReader?
    private var activeWriter: AVAssetWriter?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let reader = activeReader
        let writer = activeWriter
        lock.unlock()

        reader?.cancelReading()
        writer?.cancelWriting()
    }

    func convert(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws -> ConversionResult {
        guard (input.category == .audio || input.category == .video),
              config.outputFormat.category == .audio else {
            throw ConversionError.unsupportedConversion
        }
        guard let duration = input.duration, duration > 0 else {
            throw ConversionError.invalidInput("Audio duration is unavailable.")
        }
        if input.category == .video, input.audioCodec == nil {
            throw ConversionError.invalidInput("This video has no audio track to extract.")
        }

        setCancelled(false)

        let outputURL = TempStorage.url(for: config.outputFormat)
        let sourceBps = input.category == .video ? input.audioBitrate : input.bitrate

        if Self.shouldRemux(input: input, config: config) {
            do {
                return try await remuxAudio(
                    input: input,
                    config: config,
                    duration: duration,
                    progress: progress
                )
            } catch {
                if Self.isCancellation(error) {
                    throw error
                }
                // Metadata can look compatible while container details are not;
                // if copy fails, continue on normal transcode path.
            }
        }

        var bitrate = config.targetSizeBytes.map {
            BitrateCalculator.audioBitrateKbps(targetBytes: $0, durationSec: duration)
        } ?? 192
        if let override = config.preferredAudioBitrateKbps {
            bitrate = override
        }

        let maxKbps: Int
        if config.outputFormat == .m4a || config.outputFormat == .aac {
            maxKbps = AudioExportParameters.maxAACKbps
        } else {
            maxKbps = BitrateCalculator.maximumAudioEncodeKbps(for: config.outputFormat)
        }
        bitrate = BitrateCalculator.capAudioEncodeKbps(
            requested: bitrate,
            sourceBps: sourceBps,
            maximumKbps: maxKbps
        )
        bitrate = max(Self.minimumSupportedBitrateKbps(for: config.outputFormat), bitrate)

        let asset = AVURLAsset(url: input.url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw ConversionError.invalidInput("No audio track found.")
        }

        if Self.shouldUseFfmpegToEncodeContainerMetadataIfNeeded(config) {
            if config.outputFormat == .m4a {
                return try await transcodeWithFFmpeg(
                    input: input,
                    outputURL: outputURL,
                    format: .m4a,
                    audioCodec: CodecCapability.encoderName(for: .m4a),
                    bitrateKbps: bitrate,
                    treatAsLossyForBitrateArg: true,
                    duration: duration,
                    metadata: config.metadata,
                    progress: progress
                )
            }
            if config.outputFormat == .wav {
                return try await transcodeWithFFmpeg(
                    input: input,
                    outputURL: outputURL,
                    format: .wav,
                    audioCodec: nil,
                    bitrateKbps: nil,
                    treatAsLossyForBitrateArg: false,
                    duration: duration,
                    metadata: config.metadata,
                    progress: progress
                )
            }
        }

        if config.outputFormat == .m4a, bitrate > 256 {
            return try await transcodeWithFFmpeg(
                input: input,
                outputURL: outputURL,
                format: .m4a,
                audioCodec: CodecCapability.encoderName(for: .m4a),
                bitrateKbps: bitrate,
                treatAsLossyForBitrateArg: true,
                duration: duration,
                metadata: config.metadata,
                progress: progress
            )
        }

        if !Self.supportsNativeEncoding(config.outputFormat) {
            return try await transcodeWithFFmpeg(
                input: input,
                outputURL: outputURL,
                format: config.outputFormat,
                audioCodec: nil,
                bitrateKbps: config.outputFormat.isLossy ? bitrate : nil,
                treatAsLossyForBitrateArg: config.outputFormat.isLossy,
                duration: duration,
                metadata: config.metadata,
                progress: progress
            )
        }

        do {
            progress(0)
            try await transcode(
                asset: asset,
                track: track,
                outputURL: outputURL,
                format: config.outputFormat,
                bitrateKbps: config.outputFormat.isLossy ? bitrate : nil,
                duration: duration,
                progress: progress
            )
            progress(1)
            let media = try await MediaInspector.inspect(url: outputURL)
            return ConversionResult(
                url: outputURL,
                outputFormat: config.outputFormat,
                sizeOnDisk: media.sizeOnDisk,
                duration: media.duration,
                bitrate: media.bitrate
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func remuxAudio(
        input: MediaFile,
        config: ConversionConfig,
        duration: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        let outputURL = TempStorage.url(for: config.outputFormat)
        let inputPath = FFmpegCommandRunner.quoted(input.url.path)
        let outputPath = FFmpegCommandRunner.quoted(outputURL.path)
        let meta = FFmpegMetadataOptions.outputFlags(config.metadata)
        let command = "-y -i \(inputPath) -vn -map 0:a:0 -c copy\(config.outputFormat.ffmpegOutputMuxerArg)\(meta) \(outputPath)"

        do {
            progress(0)
            try await FFmpegCommandRunner().run(
                command,
                duration: duration,
                progress: progress
            )
            progress(1)
            let media = try await MediaInspector.inspect(url: outputURL)
            return ConversionResult(
                url: outputURL,
                outputFormat: config.outputFormat,
                sizeOnDisk: media.sizeOnDisk,
                duration: media.duration,
                bitrate: media.bitrate,
                audioCodec: media.audioCodec
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private func transcodeWithFFmpeg(
        input: MediaFile,
        outputURL: URL,
        format: OutputFormat,
        audioCodec: String?,
        bitrateKbps: Int?,
        treatAsLossyForBitrateArg: Bool,
        duration: TimeInterval,
        metadata: MetadataExportPolicy,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> ConversionResult {
        guard let codec = audioCodec ?? Self.ffmpegAudioCodec(for: format) else {
            throw ConversionError.codecUnavailable(
                reason: CodecCapability.unsupportedReason(for: format) ?? "The selected audio encoder is unavailable."
            )
        }

        let inputPath = FFmpegCommandRunner.quoted(input.url.path)
        let outputPath = FFmpegCommandRunner.quoted(outputURL.path)
        let addBitrate = treatAsLossyForBitrateArg && (bitrateKbps ?? 0) > 0
        let bitrateArg = addBitrate ? " -b:a \((bitrateKbps ?? 0))k" : ""
        let formatArgs = Self.ffmpegAudioFormatArguments(for: format)
        let meta = FFmpegMetadataOptions.outputFlags(metadata)
        let command = "-y -i \(inputPath) -vn -map 0:a:0 -c:a \(codec)\(bitrateArg)\(formatArgs)\(format.ffmpegOutputMuxerArg)\(meta) \(outputPath)"

        do {
            progress(0)
            try await FFmpegCommandRunner().run(
                command,
                duration: duration,
                progress: progress
            )
            progress(1)
            let media = try await MediaInspector.inspect(url: outputURL)
            return ConversionResult(
                url: outputURL,
                outputFormat: format,
                sizeOnDisk: media.sizeOnDisk,
                duration: media.duration,
                bitrate: media.bitrate,
                audioCodec: media.audioCodec
            )
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func ffmpegAudioCodec(for format: OutputFormat) -> String? {
        CodecCapability.encoderName(for: format)
    }

    /// Native (AVAudio) file writers don't apply container tags; use FFmpeg when the user needs specific metadata preserved.
    private static func shouldUseFfmpegToEncodeContainerMetadataIfNeeded(_ config: ConversionConfig) -> Bool {
        guard !config.metadata.stripAll else { return false }
        guard config.outputFormat == .m4a || config.outputFormat == .wav else { return false }
        if !config.metadata.retainedImageTags.isEmpty { return false }
        return !config.metadata.retainedFormatTags.isEmpty || !config.metadata.retainedStreamTags.isEmpty
    }

    private static func ffmpegAudioFormatArguments(for format: OutputFormat) -> String {
        switch format {
        case .mp3:
            // MP3 encoders reject some source layouts/rates (for example multi-channel FLAC);
            // normalize to broadly-compatible stereo 48 kHz before encode.
            return " -ac 2 -ar 48000"
        case .m4a:
            // Match native AVAssetWriter path (stereo cap) and avoid muxer/encoder edge cases on device.
            return " -ac 2"
        default:
            return ""
        }
    }

    private func transcode(
        asset: AVAsset,
        track: AVAssetTrack,
        outputURL: URL,
        format: OutputFormat,
        bitrateKbps: Int?,
        duration: TimeInterval,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let settings = try await Self.settings(for: track, format: format, bitrateKbps: bitrateKbps)
        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderTrackOutput(track: track, outputSettings: settings.readerOutput)
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw ConversionError.engineFailed("Couldn't read the audio track.")
        }
        reader.add(readerOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: settings.fileType)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: settings.writerInput)
        writerInput.expectsMediaDataInRealTime = false

        guard writer.canAdd(writerInput) else {
            throw ConversionError.engineFailed("Couldn't create the audio output.")
        }
        writer.add(writerInput)

        setActive(reader: reader, writer: writer)
        defer { clearActive() }

        guard writer.startWriting() else {
            throw writer.error ?? ConversionError.engineFailed("Couldn't start audio writing.")
        }
        // Session must be started before reading/appending. Order matches Apple's reader/writer transcode flow.
        writer.startSession(atSourceTime: .zero)
        guard reader.startReading() else {
            writer.cancelWriting()
            throw reader.error ?? ConversionError.engineFailed("Couldn't start audio reading.")
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let guardBox = NativeAudioContinuationGuard(continuation)

            writerInput.requestMediaDataWhenReady(on: Self.processingQueue) { [weak self] in
                guard let self else { return }

                while writerInput.isReadyForMoreMediaData {
                    if self.isCancelled {
                        reader.cancelReading()
                        writerInput.markAsFinished()
                        writer.cancelWriting()
                        guardBox.resume(throwing: ConversionError.cancelled)
                        return
                    }

                    if reader.status == .failed {
                        writerInput.markAsFinished()
                        writer.cancelWriting()
                        guardBox.resume(throwing: reader.error ?? ConversionError.engineFailed("Audio reading failed."))
                        return
                    }

                    if reader.status == .cancelled {
                        writerInput.markAsFinished()
                        writer.cancelWriting()
                        guardBox.resume(throwing: ConversionError.cancelled)
                        return
                    }

                    guard let sampleBuffer = readerOutput.copyNextSampleBuffer() else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if self.isCancelled {
                                guardBox.resume(throwing: ConversionError.cancelled)
                            } else if writer.status == .completed {
                                guardBox.resume(returning: ())
                            } else {
                                guardBox.resume(throwing: writer.error ?? ConversionError.engineFailed("Audio writing failed."))
                            }
                        }
                        return
                    }

                    let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
                    if seconds.isFinite, duration > 0 {
                        progress(min(0.99, max(0, seconds / duration)))
                    }

                    if !writerInput.append(sampleBuffer) {
                        reader.cancelReading()
                        writerInput.markAsFinished()
                        writer.cancelWriting()
                        guardBox.resume(throwing: writer.error ?? ConversionError.engineFailed("Audio writing failed."))
                        return
                    }
                }
            }
        }
    }

    private static func supportsNativeEncoding(_ format: OutputFormat) -> Bool {
        switch format {
        case .m4a, .wav:
            true
        default:
            false
        }
    }

    private static func minimumSupportedBitrateKbps(for format: OutputFormat) -> Int {
        switch format {
        case .m4a:
            // Prevent invalid very-low AAC bitrates that can fail on iOS encoders.
            return 64
        case .wav:
            return 1
        default:
            return 1
        }
    }

    private struct NativeAudioSettings {
        let fileType: AVFileType
        let readerOutput: [String: Any]
        let writerInput: [String: Any]
    }

    private static func settings(
        for track: AVAssetTrack,
        format: OutputFormat,
        bitrateKbps: Int?
    ) async throws -> NativeAudioSettings {
        let properties = try await audioProperties(for: track)
        let pcm16: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: properties.sampleRate,
            AVNumberOfChannelsKey: properties.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        // 32-bit float, non-interleaved: format most reliable for the AAC encode path.
        let pcmFloat: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: properties.sampleRate,
            AVNumberOfChannelsKey: properties.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: true
        ]
        let aacBitsPerSec: Int = {
            let minimumKbps = minimumSupportedBitrateKbps(for: format)
            let rawKbps = max(minimumKbps, bitrateKbps ?? 192)
            let maximumKbps = BitrateCalculator.maximumAudioEncodeKbps(for: format)
            return min(maximumKbps * 1000, max(minimumKbps * 1000, rawKbps * 1000))
        }()

        switch format {
        case .m4a:
            return NativeAudioSettings(
                fileType: .m4a,
                readerOutput: pcmFloat,
                writerInput: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: properties.sampleRate,
                    AVNumberOfChannelsKey: properties.channelCount,
                    AVEncoderBitRateKey: aacBitsPerSec
                ]
            )
        case .wav:
            return NativeAudioSettings(fileType: .wav, readerOutput: pcm16, writerInput: pcm16)
        default:
            throw ConversionError.unsupportedConversion
        }
    }

    private static func audioProperties(for track: AVAssetTrack) async throws -> (sampleRate: Double, channelCount: Int) {
        guard let desc = try await track.load(.formatDescriptions).first,
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee else {
            return (44_100, 2)
        }

        let sampleRate = asbd.mSampleRate.isFinite && asbd.mSampleRate > 0
            ? asbd.mSampleRate
            : 44_100
        let channels = asbd.mChannelsPerFrame > 0
            ? Int(asbd.mChannelsPerFrame)
            : 2
        return (sampleRate, min(max(1, channels), 2))
    }

    private func setActive(reader: AVAssetReader, writer: AVAssetWriter) {
        lock.lock()
        activeReader = reader
        activeWriter = writer
        lock.unlock()
    }

    private func clearActive() {
        lock.lock()
        activeReader = nil
        activeWriter = nil
        lock.unlock()
    }

    private func setCancelled(_ value: Bool) {
        lock.lock()
        cancelled = value
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private static func shouldRemux(input: MediaFile, config: ConversionConfig) -> Bool {
        config.prefersRemuxWhenPossible
            && config.outputFormat.category == .audio
            && config.outputFormat.canRemuxStandaloneAudioCodec(
                input.audioCodec,
                inputContainer: input.containerFormat
            )
    }

    private static func isCancellation(_ error: Error) -> Bool {
        if case ConversionError.cancelled = error {
            return true
        }
        return error is CancellationError
    }
}

private final class NativeAudioContinuationGuard {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: Void) {
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
