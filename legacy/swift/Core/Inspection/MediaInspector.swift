import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreMedia

/// Routes a file URL to the right inspector and returns a fully-populated MediaFile.
/// All AVAsset access uses the iOS 16+ async APIs (no deprecated synchronous calls).
enum MediaInspector {

    static func inspect(url: URL) async throws -> MediaFile {
        guard let category = FormatMatrix.detectCategory(from: url) else {
            throw ConversionError.invalidInput("Unsupported file type")
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? Int64) ?? 0
        let filename = url.lastPathComponent
        let ext = url.pathExtension.lowercased()

        switch category {
        case .image:
            return try inspectImage(url: url, filename: filename, size: size, ext: ext)
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
    ) throws -> MediaFile {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props  = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width  = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else {
            throw ConversionError.invalidInput("Couldn't read image metadata")
        }
        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .image,
            sizeOnDisk: size,
            dimensions: CGSize(width: width, height: height),
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

        var duration: Double
        let vTracks: [AVAssetTrack]
        let aTracks: [AVAssetTrack]
        do {
            async let durationCM = asset.load(.duration)
            async let videoTracks = asset.loadTracks(withMediaType: .video)
            async let audioTracks = asset.loadTracks(withMediaType: .audio)
            let durationValue = try await durationCM
            let rawSeconds = CMTimeGetSeconds(durationValue)
            if CMTIME_IS_INDEFINITE(durationValue) || !rawSeconds.isFinite || rawSeconds <= 0 {
                duration = 0
            } else {
                duration = rawSeconds
            }
            vTracks = try await videoTracks
            aTracks = try await audioTracks
        } catch {
            #if canImport(ffmpegkit)
            if let p = FFprobeVideoMetadata.probeVideo(at: url) {
                let durationSec = p.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
                if durationSec != nil || p.dimensions != nil {
                    let bitrate: Int? = {
                        guard let t = durationSec, t > 0 else { return nil }
                        return Int((Double(size) * 8.0 / t).rounded())
                    }()
                    return MediaFile(
                        url: url,
                        originalFilename: filename,
                        category: .video,
                        sizeOnDisk: size,
                        dimensions: p.dimensions,
                        duration: durationSec,
                        fps: p.fps,
                        bitrate: bitrate,
                        audioBitrate: nil,
                        videoCodec: p.videoCodec,
                        audioCodec: p.audioCodec,
                        containerFormat: ext
                    )
                }
            }
            #endif
            return fallbackVideoMediaFile(
                url: url,
                filename: filename,
                size: size,
                ext: ext
            )
        }

        var dimensions: CGSize?
        var fps: Double?
        var videoCodec: String?
        var audioCodec: String?

        var videoDataRateBps: Float = 0
        if let vTrack = vTracks.first {
            let naturalSize = try await vTrack.load(.naturalSize)
            let transform   = try await vTrack.load(.preferredTransform)
            let oriented    = naturalSize.applying(transform)
            dimensions = CGSize(
                width: abs(oriented.width).rounded(),
                height: abs(oriented.height).rounded()
            )
            fps = Double(try await vTrack.load(.nominalFrameRate))
            videoDataRateBps = try await vTrack.load(.estimatedDataRate)

            if let desc = try await vTrack.load(.formatDescriptions).first {
                videoCodec = fourCharCodeString(CMFormatDescriptionGetMediaSubType(desc))
            }
        }

        var audioDataRateBps: Float = 0
        if let aTrack = aTracks.first,
           let desc = try await aTrack.load(.formatDescriptions).first {
            audioCodec = fourCharCodeString(CMFormatDescriptionGetMediaSubType(desc))
            audioDataRateBps = try await aTrack.load(.estimatedDataRate)
        }

        #if canImport(ffmpegkit)
        applyFFprobeSupplement(
            url: url,
            ext: ext,
            avDuration: &duration,
            dimensions: &dimensions,
            fps: &fps,
            videoCodec: &videoCodec,
            audioCodec: &audioCodec
        )
        #endif

        let bitrate = duration > 0 ? Int((Double(size) * 8.0 / duration).rounded()) : nil

        let audioBitrate: Int? = {
            if audioDataRateBps > 0 {
                return Int(audioDataRateBps.rounded())
            }
            if let b = bitrate, videoDataRateBps > 0, b > Int(videoDataRateBps) {
                return max(0, b - Int(videoDataRateBps.rounded()))
            }
            return nil
        }()

        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .video,
            sizeOnDisk: size,
            dimensions: dimensions,
            duration: duration > 0 ? duration : nil,
            fps: fps,
            bitrate: bitrate,
            audioBitrate: audioBitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            containerFormat: ext
        )
    }

    // MARK: - Audio

    private static func inspectAudio(
        url: URL, filename: String, size: Int64, ext: String
    ) async throws -> MediaFile {
        let asset = AVURLAsset(url: url)
        let durationCM = try await asset.load(.duration)
        let duration = CMTimeGetSeconds(durationCM)
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        var audioCodec: String?
        if let track = tracks.first,
           let desc = try await track.load(.formatDescriptions).first {
            audioCodec = fourCharCodeString(CMFormatDescriptionGetMediaSubType(desc))
        }

        let bitrate = duration > 0 ? Int((Double(size) * 8.0 / duration).rounded()) : nil

        return MediaFile(
            url: url,
            originalFilename: filename,
            category: .audio,
            sizeOnDisk: size,
            duration: duration > 0 ? duration : nil,
            bitrate: bitrate,
            audioCodec: audioCodec,
            containerFormat: ext
        )
    }

    // MARK: - Helpers

    /// Converts a CoreMedia FourCC into a human-readable codec string (e.g. 'avc1', 'hvc1', 'mp4a').
    #if canImport(ffmpegkit)
    /// Fills duration and track metadata from FFprobe when AVFoundation omits or misreports them (common for Matroska / WebM / TS).
    private static func applyFFprobeSupplement(
        url: URL,
        ext: String,
        avDuration: inout Double,
        dimensions: inout CGSize?,
        fps: inout Double?,
        videoCodec: inout String?,
        audioCodec: inout String?
    ) {
        let avOK = avDuration > 0
        let wantProbe = FFprobeVideoMetadata.preferredProbeExtensions.contains(ext) || !avOK
        guard wantProbe, let p = FFprobeVideoMetadata.probeVideo(at: url) else { return }
        if let d = p.duration, d > 0, d.isFinite {
            if FFprobeVideoMetadata.preferredProbeExtensions.contains(ext) || !avOK {
                avDuration = d
            }
        }
        if dimensions == nil, let dim = p.dimensions { dimensions = dim }
        if fps == nil, let f = p.fps { fps = f }
        if videoCodec == nil, let c = p.videoCodec { videoCodec = c }
        if audioCodec == nil, let c = p.audioCodec { audioCodec = c }
    }
    #endif

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

    private static func fallbackVideoMediaFile(
        url: URL,
        filename: String,
        size: Int64,
        ext: String
    ) -> MediaFile {
        MediaFile(
            url: url,
            originalFilename: filename,
            category: .video,
            sizeOnDisk: size,
            dimensions: nil,
            duration: nil,
            fps: nil,
            bitrate: nil,
            audioBitrate: nil,
            videoCodec: nil,
            audioCodec: nil,
            containerFormat: ext
        )
    }

}
