import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import libwebp

#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

/// Converts still images using ImageIO + CoreImage.
/// For lossy targets, performs an 8-iteration binary search on quality to hit target size.
final class ImageConverter: Converter {

    private var cancelled = false

    func cancel() {
        cancelled = true
    }

    func convert(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats _: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws -> ConversionResult {
        cancelled = false
        progress(0.05)

        guard config.outputFormat.category == .image else {
            throw ConversionError.unsupportedConversion
        }

        guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil) else {
            throw ConversionError.invalidInput("Couldn't read image")
        }

        let sourceDimensions = try sourceImageDimensions(from: source)
        var commandConfig = config
        if config.operationMode == .autoTarget, config.outputFormat.supportsTargetSize {
            let plan = AutoTargetPlanner.imagePlan(
                input: Self.planningInput(input: input, cropRegion: config.cropRegion),
                outputFormat: config.outputFormat,
                targetBytes: config.targetSizeBytes ?? input.sizeOnDisk,
                lockedDimensions: config.targetDimensions,
                lockPolicy: config.autoTargetLockPolicy
            )
            commandConfig.targetDimensions = plan.targetDimensions
        }

        // 1. Decode at target-ish size when downscaling to avoid paying full HEIC decode cost.
        // Cropping needs exact source pixels first, so that path decodes full-size then scales after crop.
        var workingImage: CGImage
        if config.cropRegion == nil,
           let target = commandConfig.targetDimensions,
           target.width < sourceDimensions.width || target.height < sourceDimensions.height {
            let maxPixel = Int(ceil(max(target.width, target.height)))
            workingImage = try decodeThumbnail(source: source, maxPixelSize: maxPixel)
        } else {
            guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw ConversionError.invalidInput("Couldn't read image")
            }
            workingImage = cgImage
        }

        if let crop = commandConfig.cropRegion?.clamped(to: sourceDimensions) {
            workingImage = try croppedImage(workingImage, to: crop)
        }

        if config.cropRegion != nil,
           let target = commandConfig.targetDimensions,
           (target.width < CGFloat(workingImage.width) || target.height < CGFloat(workingImage.height)) {
            workingImage = try resizedImage(workingImage, to: target)
        }
        progress(0.3)
        if cancelled { throw ConversionError.cancelled }

        let utType = utType(for: config.outputFormat)
        let outputURL = TempStorage.url(for: config.outputFormat)

        // 2. Encode (with target search if applicable)
        let data: Data
        if utType == .webP {
            let quality = max(0, min(1, commandConfig.imageQuality ?? 0.82))
            data = try encode(image: workingImage, utType: utType, quality: quality, metadataPolicy: commandConfig.metadata)
            progress(0.95)
        } else if let targetBytes = commandConfig.targetSizeBytes,
           commandConfig.outputFormat.supportsTargetSize {
            data = try encodeWithTarget(
                image: workingImage,
                utType: utType,
                targetBytes: Int(targetBytes),
                metadataPolicy: commandConfig.metadata,
                progress: { p in progress(0.3 + p * 0.65) }
            )
        } else {
            // No target or lossless — encode at high quality
            data = try encode(image: workingImage, utType: utType, quality: 0.92, metadataPolicy: commandConfig.metadata)
            progress(0.95)
        }

        try data.write(to: outputURL, options: .atomic)
        progress(1.0)

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attrs[.size] as? Int64) ?? Int64(data.count)

        return ConversionResult(
            url: outputURL,
            outputFormat: config.outputFormat,
            sizeOnDisk: size,
            dimensions: CGSize(width: workingImage.width, height: workingImage.height)
        )
    }

    // MARK: - Encoding

    private func encode(
        image: CGImage,
        utType: UTType,
        quality: Double,
        metadataPolicy: MetadataExportPolicy
    ) throws -> Data {
        if utType == .webP {
            return try encodeWebPWithLibWebP(image: image, quality: quality)
        }
        let data = NSMutableData()
        let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            utType.identifier as CFString,
            1,
            nil
        )
        guard let dest else {
            throw ConversionError.engineFailed("Couldn't create image destination")
        }
        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationEmbedThumbnail: false
        ]
        if let embedded = Self.imagePropertyMetadata(from: metadataPolicy) {
            for (k, v) in embedded {
                options[k] = v
            }
        }
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        let finalized = CGImageDestinationFinalize(dest)
        guard finalized else {
            throw ConversionError.engineFailed("Encode failed")
        }
        return data as Data
    }

    /// Binary-search the quality coefficient to land at-or-just-under `targetBytes`.
    /// Prefers undershoot to overshoot (compression use case).
    private func encodeWithTarget(
        image: CGImage,
        utType: UTType,
        targetBytes: Int,
        metadataPolicy: MetadataExportPolicy,
        progress: (Double) -> Void
    ) throws -> Data {
        var lo: Double = 0.05
        var hi: Double = 1.0
        var best: Data?
        let iterations = 12

        for i in 0..<iterations {
            if cancelled { throw ConversionError.cancelled }
            let q = (lo + hi) / 2.0
            let data = try encode(image: image, utType: utType, quality: q, metadataPolicy: metadataPolicy)

            if data.count <= targetBytes {
                best = data
                lo = q   // try a higher quality next
            } else {
                hi = q   // need to compress more
            }
            progress(Double(i + 1) / Double(iterations))
        }

        if let best { return best }
        // Couldn't get under target even at min quality — encode at the lowest tried
        // and surface that in the UI as "smallest possible at this resolution"
        return try encode(image: image, utType: utType, quality: lo, metadataPolicy: metadataPolicy)
    }

    /// Builds `CGImageDestination` top-level property dictionaries (EXIF, GPS, …) from the export policy.
    private static func imagePropertyMetadata(from policy: MetadataExportPolicy) -> [CFString: Any]? {
        guard !policy.stripAll, !policy.retainedImageTags.isEmpty else { return nil }
        var exif: [String: Any] = [:]
        var gps: [String: Any] = [:]
        var iptc: [String: Any] = [:]
        var tiff: [String: Any] = [:]
        var png: [String: Any] = [:]
        var xmp: [String: Any] = [:]
        for entry in policy.retainedImageTags {
            let value = coercedImageTagValue(entry.value)
            switch entry.scope {
            case .exif: exif[entry.dictionaryKey] = value
            case .gps: gps[entry.dictionaryKey] = value
            case .iptc: iptc[entry.dictionaryKey] = value
            case .tiff: tiff[entry.dictionaryKey] = value
            case .png: png[entry.dictionaryKey] = value
            case .xmp: xmp[entry.dictionaryKey] = value
            }
        }
        var out: [CFString: Any] = [:]
        if !tiff.isEmpty { out[kCGImagePropertyTIFFDictionary] = tiff as CFDictionary }
        if !exif.isEmpty { out[kCGImagePropertyExifDictionary] = exif as CFDictionary }
        if !gps.isEmpty { out[kCGImagePropertyGPSDictionary] = gps as CFDictionary }
        if !iptc.isEmpty { out[kCGImagePropertyIPTCDictionary] = iptc as CFDictionary }
        if !png.isEmpty { out[kCGImagePropertyPNGDictionary] = png as CFDictionary }
        if !xmp.isEmpty { out["{XMP}" as CFString] = xmp as CFDictionary }
        return out.isEmpty ? nil : out
    }

    private static func coercedImageTagValue(_ string: String) -> Any {
        if let intVal = Int(string) {
            return intVal
        }
        if let doubleVal = Double(string) {
            return doubleVal
        }
        return string
    }

    private struct WebPBGRARaster {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bgra: Data
    }

    /// Single rasterization for WebP: target-size search used to repeat this ~8× per image (very slow on large photos).
    private func rasterizeBGRAForWebP(image: CGImage) throws -> WebPBGRARaster {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        let byteCount = bytesPerRow * height
        var bgra = Data(count: byteCount)

        let rasterized: Bool = bgra.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return false }
            guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return false }
            guard let ctx = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
            return true
        }
        guard rasterized else {
            throw ConversionError.engineFailed("Couldn't rasterize image for WebP")
        }
        return WebPBGRARaster(width: width, height: height, bytesPerRow: bytesPerRow, bgra: bgra)
    }

    private func encodeWebPFromRaster(_ raster: WebPBGRARaster, quality: Double) throws -> Data {
        var config = WebPConfig()
        let qualityPercent = Float(max(0, min(100, quality * 100)))
        guard WebPConfigPreset(&config, WEBP_PRESET_PHOTO, qualityPercent) != 0 else {
            throw ConversionError.engineFailed("WebP encoder config init failed")
        }
        config.method = 3
        config.thread_level = 1
        guard WebPValidateConfig(&config) != 0 else {
            throw ConversionError.engineFailed("WebP encoder config invalid")
        }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else {
            throw ConversionError.engineFailed("WebP picture init failed")
        }
        defer { WebPPictureFree(&picture) }
        picture.use_argb = 1
        picture.width = Int32(raster.width)
        picture.height = Int32(raster.height)

        let writerPtr = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        writerPtr.initialize(to: WebPMemoryWriter())
        WebPMemoryWriterInit(writerPtr)
        defer {
            WebPMemoryWriterClear(writerPtr)
            writerPtr.deinitialize(count: 1)
            writerPtr.deallocate()
        }

        let encoded: Data = try raster.bgra.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ConversionError.engineFailed("WebP raster buffer unavailable")
            }
            guard WebPPictureImportBGRA(&picture, base, Int32(raster.bytesPerRow)) != 0 else {
                throw ConversionError.engineFailed("WebP picture import failed")
            }

            picture.writer = WebPMemoryWrite
            picture.custom_ptr = UnsafeMutableRawPointer(writerPtr)
            guard WebPEncode(&config, &picture) != 0 else {
                throw ConversionError.engineFailed("WebP encode failed")
            }
            guard let mem = writerPtr.pointee.mem, writerPtr.pointee.size > 0 else {
                throw ConversionError.engineFailed("WebP encode produced no data")
            }
            return Data(bytes: mem, count: writerPtr.pointee.size)
        }
        return encoded
    }

    /// ffmpeg-kit **min** builds omit WebP muxers/encoders; use libwebp directly (SDWebImage/libwebp-Xcode).
    private func encodeWebPWithLibWebP(image: CGImage, quality: Double) throws -> Data {
        let raster = try rasterizeBGRAForWebP(image: image)
        return try encodeWebPFromRaster(raster, quality: quality)
    }

    // MARK: - Decode

    private func sourceImageDimensions(from source: CGImageSource) throws -> CGSize {
        guard
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = props[kCGImagePropertyPixelWidth] as? Int,
            let height = props[kCGImagePropertyPixelHeight] as? Int
        else {
            throw ConversionError.invalidInput("Couldn't read image metadata")
        }
        return CGSize(width: width, height: height)
    }

    private func decodeThumbnail(source: CGImageSource, maxPixelSize: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ConversionError.engineFailed("Thumbnail decode failed")
        }
        return image
    }

    private func croppedImage(_ image: CGImage, to crop: CropRegion) throws -> CGImage {
        let sourceRect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let cropRect = crop.rect.integral.intersection(sourceRect)
        guard cropRect.width > 0,
              cropRect.height > 0,
              let cropped = image.cropping(to: cropRect)
        else {
            throw ConversionError.invalidInput("Crop rectangle is outside the image.")
        }
        return cropped
    }

    private func resizedImage(_ image: CGImage, to target: CGSize) throws -> CGImage {
        let width = min(image.width, max(1, Int(target.width.rounded())))
        let height = min(image.height, max(1, Int(target.height.rounded())))
        guard width < image.width || height < image.height else {
            return image
        }
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ConversionError.engineFailed("Couldn't create image resize context")
        }

        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw ConversionError.engineFailed("Image resize failed")
        }
        return resized
    }

    private static func planningInput(input: MediaFile, cropRegion: CropRegion?) -> MediaFile {
        guard let source = input.dimensions,
              let crop = cropRegion?.clamped(to: source),
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

    // MARK: - Format Mapping

    private func utType(for format: OutputFormat) -> UTType {
        switch format {
        case .jpg: .jpeg
        case .png: .png
        case .heic: .heic
        case .webpImage: .webP
        case .tiff: .tiff
        default: .data
        }
    }

}
