import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Key photo support for Live Photos: the movie records when the still was
/// taken, and any other movie frame can become the exported still instead.
enum LivePhotoKeyPhoto {
    private static let stillImageTimeKey = "com.apple.quicktime.still-image-time"

    /// Movie time of the original still, from the movie's timed metadata track.
    static func originalTime(in movieURL: URL) async -> Double? {
        let asset = AVURLAsset(url: movieURL)
        guard let tracks = try? await asset.loadTracks(withMediaType: .metadata), !tracks.isEmpty else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            for track in tracks {
                guard let reader = try? AVAssetReader(asset: asset) else { continue }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                guard reader.canAdd(output) else { continue }
                reader.add(output)
                let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
                guard reader.startReading() else { continue }
                defer { reader.cancelReading() }
                while !Task.isCancelled, let group = adaptor.nextTimedMetadataGroup() {
                    let isStillImageTime = group.items.contains { item in
                        (item.key as? String) == stillImageTimeKey
                            || item.identifier?.rawValue.hasSuffix(stillImageTimeKey) == true
                    }
                    let seconds = group.timeRange.start.seconds
                    if isStillImageTime, seconds.isFinite, seconds >= 0 { return seconds }
                }
            }
            return nil
        }.value
    }

    /// Renders one movie frame as an upright still in import storage. The
    /// original photo's EXIF, GPS and IPTC details are copied so metadata
    /// choices still apply to the new key photo.
    static func render(movieURL: URL, at seconds: Double, metadataFrom stillURL: URL) async throws -> MediaFile {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movieURL))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (frame, _) = try await generator.image(at: CMTime(seconds: max(0, seconds), preferredTimescale: 600))
        try Task.checkCancellation()

        let type: UTType = (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? [])
            .contains(UTType.heic.identifier) ? .heic : .jpeg
        let outputURL = ImportStorage.url(originalName: nil, fallbackExtension: type.preferredFilenameExtension ?? "jpg")
        do {
            try await Task.detached(priority: .userInitiated) {
                guard let destination = CGImageDestinationCreateWithURL(
                    outputURL as CFURL, type.identifier as CFString, 1, nil
                ) else {
                    throw ConversionError.engineFailed("Couldn't create the key photo")
                }
                var properties = stillProperties(from: stillURL)
                properties[kCGImageDestinationLossyCompressionQuality] = 0.95
                CGImageDestinationAddImage(destination, frame, properties as CFDictionary)
                guard CGImageDestinationFinalize(destination) else {
                    throw ConversionError.engineFailed("Couldn't save the key photo")
                }
            }.value
            try Task.checkCancellation()
            TempStorage.allowAccessWhileLocked(at: outputURL)
            return try await MediaInspector.inspect(url: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Capture details from the photo, without values that describe its own
    /// pixels: the frame is already upright and has different dimensions.
    private static func stillProperties(from stillURL: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(stillURL as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return [:]
        }
        var output: [CFString: Any] = [:]
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
            output[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            output[kCGImagePropertyExifDictionary] = exif
        }
        for key in [kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let value = props[key] { output[key] = value }
        }
        return output
    }
}
