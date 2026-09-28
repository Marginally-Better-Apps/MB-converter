import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

/// Routes a file URL to the right inspector and returns a fully-populated MediaFile.
/// All AVAsset access uses the iOS 16+ async APIs (no deprecated synchronous calls).
enum MediaInspector {

    static func inspect(url: URL) async throws -> MediaFile {
        try Task.checkCancellation()
        guard let category = FormatMatrix.detectCategory(from: url) else {
            throw ConversionError.invalidInput("Unsupported file type")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        switch category {
        case .image:
            return try await inspectImage(url: url, filename: filename, size: size, ext: ext)
        case .animatedImage:
            return try inspectAnimatedImage(url: url, filename: filename, size: size, ext: ext)
        case .video:
            return try await inspectVideo(url: url, filename: filename, size: size, ext: ext)
        case .audio:
            return try await inspectAudio(url: url, filename: filename, size: size, ext: ext)
        }
    }

    // MARK: - Image

    private static func inspectImage(
        url: URL, filename: String, size: Int64, ext: String
    ) async throws -> MediaFile {
        let dimensions: CGSize
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let width = props[kCGImagePropertyPixelWidth] as? Int,
           let height = props[kCGImagePropertyPixelHeight] as? Int,
           width > 0, height > 0 {
            dimensions = CGSize(width: width, height: height)
        } else {
            // ImageIO support varies by OS version. FFmpeg can inspect and decode
            // additional still images, including AVIF on older supported devices.
            let probe = await Task.detached(priority: .userInitiated) {
                FFmpegMediaProbe.probe(at: url)
            }.value
            try Task.checkCancellation()
            guard let stream = probe?.streams.first(where: { $0.codecType == "video" }),
                  let width = stream.width, let height = stream.height,
                  width > 0, height > 0 else {
                throw ConversionError.invalidInput("Couldn't read image metadata")
            }
            dimensions = CGSize(width: width, height: height)
        }
        guard dimensions.width.isFinite, dimensions.height.isFinite else {
            throw ConversionError.invalidInput("Couldn't read image metadata")
        }
        try Task.checkCancellation()
        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .image,
            sizeOnDisk: size,
            dimensions: dimensions,
            containerFormat: ext
        )
    }

    // MARK: - Animated Image (GIF)

    private static func inspectAnimatedImage(
        url: URL, filename: String, size: Int64, ext: String
    ) throws -> MediaFile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ConversionError.invalidInput("Couldn't read animated image")
        }
        let frameCount = CGImageSourceGetCount(source)
        var totalDuration: Double = 0

        for i in 0..<frameCount {
            if let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
               let gif = props[kCGImagePropertyGIFDictionary] as? [CFString: Any] {
                // Prefer unclamped delay; some GIFs use clamped only
                let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                    ?? (gif[kCGImagePropertyGIFDelayTime] as? Double)
                    ?? 0.1
                totalDuration += max(delay, 0.02)  // browsers floor at ~20ms
            }
        }

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width  = (props?[kCGImagePropertyPixelWidth]  as? Int) ?? 0
        let height = (props?[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let fps = totalDuration > 0 ? Double(frameCount) / totalDuration : 10.0

        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .animatedImage,
            sizeOnDisk: size,
            dimensions: CGSize(width: width, height: height),
            duration: totalDuration > 0 ? totalDuration : nil,
            fps: fps,
            containerFormat: ext
        )
    }

    // MARK: - Video

    private static func inspectVideo(
        url: URL, filename: String, size: Int64, ext: String
    ) async throws -> MediaFile {
        let asset = AVURLAsset(url: url)
        var duration: Double?
        var dimensions: CGSize?
        var fps: Double?
        var videoCodec: String?
        var videoColor: VideoColorInfo?
        var audioCodec: String?
        var videoDataRate: Int?
        var audioBitrate: Int?
        var foundVideoTrack = false
        var nativeReadFailed = false

        do {
            async let durationCM = asset.load(.duration)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            duration = validDuration(CMTimeGetSeconds(try await durationCM))

            if let track = try await videoTracks.first {
                foundVideoTrack = true
                let naturalSize = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let oriented = naturalSize.applying(transform)
                if oriented.width.isFinite, oriented.height.isFinite,
                   abs(oriented.width) > 0, abs(oriented.height) > 0 {
                    dimensions = CGSize(
                        width: abs(oriented.width).rounded(),
                        height: abs(oriented.height).rounded()
                    )
                }
                fps = validDuration(Double(try await track.load(.nominalFrameRate)))
                videoDataRate = positiveInteger(Double(try await track.load(.estimatedDataRate)))
                if let description = try await track.load(.formatDescriptions).first {
                    videoCodec = fourCharCodeString(CMFormatDescriptionGetMediaSubType(description))
                }
            }
            if let track = try await audioTracks.first {
                if let description = try await track.load(.formatDescriptions).first {
                    audioCodec = fourCharCodeString(CMFormatDescriptionGetMediaSubType(description))
                }
                audioBitrate = positiveInteger(Double(try await track.load(.estimatedDataRate)))
            }
        } catch {
            if error is CancellationError { throw error }
            nativeReadFailed = true
            DiagnosticsLog.shared.record(
                error: error,
                context: "Inspect video with AVFoundation",
                metadata: ["Filename": filename, "Fallback": "FFmpeg media probe"]
            )
        }

        // All native property loads are covered by the fallback, including failures
        // while reading track format descriptions and not only asset loading.
        let prefersProbe = FFprobeVideoMetadata.preferredProbeExtensions.contains(ext)
        // Probe every video for color signaling, including AVFoundation-readable iPhone HDR clips.
        do {
            let probe = await Task.detached(priority: .userInitiated) {
                FFprobeVideoMetadata.probeVideo(at: url)
            }.value
            if let probe {
                foundVideoTrack = true
                if let probeDuration = probe.duration.flatMap(validDuration), duration == nil || prefersProbe || nativeReadFailed {
                    duration = probeDuration
                }
                videoColor = probe.videoColor
                dimensions = dimensions ?? probe.dimensions
                fps = fps ?? probe.fps
                videoCodec = videoCodec ?? probe.videoCodec
                audioCodec = audioCodec ?? probe.audioCodec
                audioBitrate = audioBitrate ?? probe.audioBitrate
            }
        }

        let bitrate = estimatedBitrate(size: size, duration: duration)
        if audioBitrate == nil, audioCodec != nil,
           let bitrate, let videoDataRate, bitrate > videoDataRate {
            audioBitrate = bitrate - videoDataRate
        }
        // The synchronous probe runs in a detached worker; propagate cancellation
        // before returning metadata to a completed or cancelled conversion task.
        try Task.checkCancellation()

        guard foundVideoTrack else {
            throw ConversionError.invalidInput("Couldn't read a video track from this file. The file may be invalid or incomplete.")
        }

        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .video,
            sizeOnDisk: size,
            dimensions: dimensions,
            duration: duration,
            fps: fps,
            bitrate: bitrate,
            audioBitrate: audioBitrate,
            videoCodec: videoCodec,
            videoColor: videoColor,
            audioCodec: audioCodec,
            containerFormat: ext
        )
    }

    // MARK: - Audio

    private static func inspectAudio(
        url: URL, filename: String, size: Int64, ext: String
    ) async throws -> MediaFile {
        let asset = AVURLAsset(url: url)
        var duration: Double?
        var audioCodec: String?
        var audioBitrate: Int?
        var foundAudioTrack = false
        var nativeReadFailed = false

        do {
            duration = validDuration(CMTimeGetSeconds(try await asset.load(.duration)))
            if let track = try await asset.loadTracks(withMediaType: .audio).first {
                foundAudioTrack = true
                if let description = try await track.load(.formatDescriptions).first {
                    audioCodec = fourCharCodeString(CMFormatDescriptionGetMediaSubType(description))
                }
                audioBitrate = positiveInteger(Double(try await track.load(.estimatedDataRate)))
            }
        } catch {
            if error is CancellationError { throw error }
            nativeReadFailed = true
            DiagnosticsLog.shared.record(
                error: error,
                context: "Inspect audio with AVFoundation",
                metadata: ["Filename": filename, "Fallback": "FFmpeg media probe"]
            )
        }

        // Also used when inspecting newly exported Ogg/Opus files that AVFoundation
        // cannot reopen, so a successful conversion is not discarded at inspection.
        if nativeReadFailed || !foundAudioTrack || duration == nil || audioCodec == nil || audioBitrate == nil {
            let probe = await Task.detached(priority: .userInitiated) {
                FFprobeVideoMetadata.probeAudio(at: url)
            }.value
            if let probe {
                foundAudioTrack = true
                duration = duration ?? probe.duration.flatMap(validDuration)
                audioCodec = audioCodec ?? probe.audioCodec
                audioBitrate = audioBitrate ?? probe.audioBitrate
            }
        }
        guard foundAudioTrack else {
            throw ConversionError.invalidInput("Couldn't read an audio track from this file.")
        }
        try Task.checkCancellation()

        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .audio,
            sizeOnDisk: size,
            duration: duration,
            bitrate: estimatedBitrate(size: size, duration: duration),
            audioBitrate: audioBitrate,
            audioCodec: audioCodec,
            containerFormat: ext
        )
    }

    // MARK: - Helpers

    private static func validDuration(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }

    private static func positiveInteger(_ value: Double) -> Int? {
        guard value.isFinite, value > 0, value < Double(Int.max) else { return nil }
        return Int(value.rounded())
    }

    private static func estimatedBitrate(size: Int64, duration: Double?) -> Int? {
        guard let duration, duration > 0 else { return nil }
        return positiveInteger(Double(size) * 8.0 / duration)
    }

    /// Converts a CoreMedia FourCC into a human-readable codec string (e.g. 'avc1', 'hvc1', 'mp4a').
    private static func fourCharCodeString(_ code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xff),
            UInt8((code >> 16) & 0xff),
            UInt8((code >>  8) & 0xff),
            UInt8( code        & 0xff),
        ]
        return String(bytes: bytes, encoding: .ascii)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

}
