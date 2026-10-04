import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers
import libwebp
import Accelerate

#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

/// Converts still images using ImageIO and libwebp, with an FFmpeg decode fallback.
/// Uses quality search for size targets and a single encode for WebP quality mode.
final class ImageConverter: Converter {

    private let cancellationLock = NSLock()
    private var cancelled = false
    private let decodeRunner = FFmpegCommandRunner()

    func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
        decodeRunner.cancel()
    }

    private func checkCancellation() throws {
        try Task.checkCancellation()
        cancellationLock.lock()
        let stopped = cancelled
        cancellationLock.unlock()
        if stopped { throw ConversionError.cancelled }
    }

    func convert(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)? = nil
    ) async throws -> ConversionResult {
        try checkCancellation()
        encodingStats?(FFmpegEncodingDisplayStats(processingBackend:
            config.outputFormat == .webpImage ? "CPU · libwebp" : "ImageIO · System managed"
        ))
        encodingStats?(FFmpegEncodingDisplayStats(activity: "Decoding image…"))
        progress(0.05)

        guard config.outputFormat.category == .image else {
            throw ConversionError.unsupportedConversion
        }

        let decoded = try await withReadableSource(at: input.url) { source in
            try decodeForConversion(source: source, input: input, config: config)
        }
        var workingImage = decoded.image
        let commandConfig = decoded.config
        let editingSourceDimensions = config.mediaRotation.applied(to: decoded.sourceDimensions)

        workingImage = try rotatedImage(workingImage, rotation: commandConfig.mediaRotation)
        if commandConfig.isMirrored {
            workingImage = try mirroredImage(workingImage)
        }

        if let crop = commandConfig.cropRegion?.clamped(to: editingSourceDimensions) {
            workingImage = try croppedImage(workingImage, to: crop)
        }

        // Thumbnail decoding keeps the source shape, so finish at the exact
        // target size, which may have a different aspect ratio.
        if let target = commandConfig.targetDimensions,
           (target.width < CGFloat(workingImage.width) || target.height < CGFloat(workingImage.height)) {
            workingImage = try resizedImage(workingImage, to: target)
        }
        progress(0.3)
        try checkCancellation()

        let utType = utType(for: config.outputFormat)
        let outputURL = TempStorage.url(for: config.outputFormat)
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: outputURL) } }

        // 2. Encode (with target search if applicable)
        let data: Data
        if utType == .webP {
            let quality = max(0, min(1, commandConfig.imageQuality ?? 0.82))
            data = try encodeWebPWithLibWebP(
                image: workingImage, quality: quality, progress: progress, encodingStats: encodingStats
            )
            progress(0.95)
        } else if let targetBytes = commandConfig.targetSizeBytes,
           commandConfig.outputFormat.supportsTargetSize {
            encodingStats?(FFmpegEncodingDisplayStats(activity: "Encoding image…"))
            data = try encodeWithTarget(
                image: workingImage,
                utType: utType,
                targetBytes: Int(targetBytes),
                metadataPolicy: commandConfig.metadata,
                progress: { p in progress(0.3 + p * 0.65) }
            )
        } else {
            // No target or lossless — encode at high quality
            encodingStats?(FFmpegEncodingDisplayStats(activity: "Encoding image…"))
            data = try encode(image: workingImage, utType: utType, quality: 0.92, metadataPolicy: commandConfig.metadata)
            progress(0.95)
        }

        try checkCancellation()
        encodingStats?(FFmpegEncodingDisplayStats(encodedSize: "\(data.count)B", activity: "Saving image…"))
        try data.write(to: outputURL, options: .atomic)
        try checkCancellation()
        progress(1.0)
        try checkCancellation()

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path)
        let size = (attrs[.size] as? Int64) ?? Int64(data.count)

        succeeded = true
        return ConversionResult(
            url: outputURL,
            outputFormat: config.outputFormat,
            sizeOnDisk: size,
            dimensions: CGSize(width: workingImage.width, height: workingImage.height)
        )
    }

    // MARK: - Encoding

    struct PNGSizeBaseline: Sendable {
        let bytes: Int64
        let dimensions: CGSize
    }

    /// One full-size encode supplies the pixel-ratio estimate. Retain only its
    /// byte count, never the source raster or encoded output.
    func measurePNGBaseline(input: MediaFile, config: ConversionConfig) throws -> PNGSizeBaseline {
        try checkCancellation()
        guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil) else {
            throw ConversionError.invalidInput("Couldn't read image")
        }
        return try measurePNGBaseline(source: source, config: config)
    }

    func measurePNGBaselineWithFallback(input: MediaFile, config: ConversionConfig) async throws -> PNGSizeBaseline {
        let image = try await withReadableSource(at: input.url) { source in
            try uprightImage(from: source)
        }
        return try measurePNGBaseline(image: image, config: config)
    }

    private func measurePNGBaseline(source: CGImageSource, config: ConversionConfig) throws -> PNGSizeBaseline {
        try measurePNGBaseline(image: try uprightImage(from: source), config: config)
    }

    private func measurePNGBaseline(image: CGImage, config: ConversionConfig) throws -> PNGSizeBaseline {
        try autoreleasepool {
            try checkCancellation()
            var image = try rotatedImage(image, rotation: config.mediaRotation)
            if config.isMirrored {
                image = try mirroredImage(image)
            }
            if let crop = config.cropRegion?.clamped(to: CGSize(width: image.width, height: image.height)) {
                image = try croppedImage(image, to: crop)
            }
            try checkCancellation()
            let bytes = try measurePNG(image: image, metadata: config.metadata)
            try checkCancellation()
            return PNGSizeBaseline(bytes: bytes, dimensions: CGSize(width: image.width, height: image.height))
        }
    }

    private final class PNGByteCounter { var count: Int64 = 0 }

    /// Count the baseline PNG stream without retaining its compressed bytes.
    private func measurePNG(image: CGImage, metadata: MetadataExportPolicy) throws -> Int64 {
        let counter = PNGByteCounter()
        var callbacks = CGDataConsumerCallbacks(putBytes: { context, _, count in
            guard let context else { return 0 }
            Unmanaged<PNGByteCounter>.fromOpaque(context).takeUnretainedValue().count += Int64(count)
            return count
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(counter).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, UTType.png.identifier as CFString, 1, nil)
        else { throw ConversionError.engineFailed("Couldn't create PNG measurement destination") }
        return try withExtendedLifetime(counter) {
            try write(image: image, destination: destination, quality: 1, metadataPolicy: metadata)
            return counter.count
        }
    }

    private func encode(
        image: CGImage,
        utType: UTType,
        quality: Double,
        metadataPolicy: MetadataExportPolicy
    ) throws -> Data {
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
        try write(image: image, destination: dest, quality: quality, metadataPolicy: metadataPolicy)
        return data as Data
    }

    private func write(image: CGImage, destination: CGImageDestination, quality: Double,
                       metadataPolicy: MetadataExportPolicy) throws {
        var options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality,
            kCGImageDestinationEmbedThumbnail: false
        ]
        if let embedded = Self.imagePropertyMetadata(from: metadataPolicy) {
            for (k, v) in embedded {
                options[k] = v
            }
        }
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        let finalized = CGImageDestinationFinalize(destination)
        guard finalized else {
            throw ConversionError.engineFailed("Encode failed")
        }
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
            try checkCancellation()
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
        for entry in policy.retainedImageTags where !isOrientationTag(entry) {
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

    /// Decoding applies the source orientation to the pixels, so writing the
    /// source tag again would turn the output a second time in viewers.
    private static func isOrientationTag(_ entry: ImageMetadataEntry) -> Bool {
        entry.scope == .tiff && entry.dictionaryKey.caseInsensitiveCompare("Orientation") == .orderedSame
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

    // MARK: - WebP encoding

    /// Draw into the encoder-owned BGRA storage (ARGB words on little-endian Apple CPUs).
    /// This also materializes ImageIO's potentially lazy HEIC decode, without a second raster.
    private func prepareWebPPicture(image: CGImage, picture: inout WebPPicture) throws {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= WEBP_MAX_DIMENSION, height <= WEBP_MAX_DIMENSION else {
            throw ConversionError.invalidInput("WebP supports images up to \(WEBP_MAX_DIMENSION) pixels per side. Choose a smaller resolution.")
        }
        picture.use_argb = 1
        picture.width = Int32(width)
        picture.height = Int32(height)
        guard WebPPictureAlloc(&picture) != 0, let pixels = picture.argb else {
            throw ConversionError.engineFailed("Couldn't allocate pixels for WebP")
        }
        let bytesPerRow = Int(picture.argb_stride) * MemoryLayout<UInt32>.stride
        // Keep the context's lifetime inside this scope before editing its backing pixels.
        do {
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: pixels, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
                  ) else {
                throw ConversionError.engineFailed("Couldn't rasterize image for WebP")
            }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        try checkCancellation()
        // Core Graphics produces premultiplied colors; libwebp requires straight alpha.
        // RGBA's vImage operation works for BGRA too: both have alpha in the last byte.
        if WebPPictureHasTransparency(&picture) != 0 {
            var buffer = vImage_Buffer(data: pixels, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: bytesPerRow)
            var destination = buffer
            let result = vImageUnpremultiplyData_RGBA8888(&buffer, &destination, vImage_Flags(kvImageNoFlags))
            guard result == kvImageNoError else {
                throw ConversionError.engineFailed("Couldn't prepare WebP transparency (code \(result))")
            }
        }
        try checkCancellation()
    }

    private func encodeWebPImage(
        _ image: CGImage, quality: Double, progress: @escaping (Double) -> Void
    ) throws -> Data {
        var config = WebPConfig()
        let qualityPercent = Float(max(0, min(100, quality * 100)))
        guard WebPConfigPreset(&config, WEBP_PRESET_PHOTO, qualityPercent) != 0 else {
            throw ConversionError.engineFailed("WebP encoder config init failed")
        }
        // Method 2 failed the size/quality gates; see docs/validation/webp-encoding.md.
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
        try prepareWebPPicture(image: image, picture: &picture)

        let writerPtr = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        writerPtr.initialize(to: WebPMemoryWriter())
        WebPMemoryWriterInit(writerPtr)
        defer {
            WebPMemoryWriterClear(writerPtr)
            writerPtr.deinitialize(count: 1)
            writerPtr.deallocate()
        }

        let context = WebPProgressContext { percent in
            do {
                try self.checkCancellation()
                progress(Double(percent) / 100)
                // Cancellation may have been requested by the progress consumer.
                try self.checkCancellation()
                return true
            } catch {
                return false
            }
        }
        picture.progress_hook = { percent, picture in
            guard let opaque = picture?.pointee.user_data else { return 0 }
            return Unmanaged<WebPProgressContext>.fromOpaque(opaque).takeUnretainedValue().report(percent) ? 1 : 0
        }
        picture.user_data = Unmanaged.passUnretained(context).toOpaque()
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writerPtr)
        progress(0)
        try checkCancellation()
        // The C callback borrows this context only for the synchronous encode.
        let encoded = withExtendedLifetime(context) { WebPEncode(&config, &picture) }
        try checkCancellation()
        guard encoded != 0 else {
            if picture.error_code == VP8_ENC_ERROR_USER_ABORT { throw ConversionError.cancelled }
            throw ConversionError.engineFailed("WebP encode failed (code \(picture.error_code.rawValue))")
        }
        guard let mem = writerPtr.pointee.mem, writerPtr.pointee.size > 0 else {
            throw ConversionError.engineFailed("WebP encode produced no data")
        }
        return Data(bytes: mem, count: writerPtr.pointee.size)
    }

    private final class WebPProgressContext {
        let report: (Int32) -> Bool
        init(report: @escaping (Int32) -> Bool) { self.report = report }
    }

    private func encodeWebPWithLibWebP(
        image: CGImage, quality: Double,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?
    ) throws -> Data {
        encodingStats?(FFmpegEncodingDisplayStats(activity: "Preparing pixels…"))
        try checkCancellation()
        return try encodeWebPImage(image, quality: quality) { fraction in
            encodingStats?(FFmpegEncodingDisplayStats(activity: "Encoding WebP · \(Int((fraction * 100).rounded()))%"))
            progress(min(0.95, 0.4 + fraction * 0.55))
        }
    }

    // MARK: - Decode

    private struct DecodedImage {
        let image: CGImage
        let sourceDimensions: CGSize
        let config: ConversionConfig
    }

    private func decodeForConversion(
        source: CGImageSource, input: MediaFile, config: ConversionConfig
    ) throws -> DecodedImage {
        let sourceDimensions = try sourceImageDimensions(from: source)
        let editingSourceDimensions = config.mediaRotation.applied(to: sourceDimensions)
        var commandConfig = config
        if config.operationMode == .autoTarget, config.outputFormat.supportsTargetSize {
            let plan = AutoTargetPlanner.imagePlan(
                input: Self.planningInput(
                    input: input,
                    cropRegion: config.cropRegion,
                    rotation: config.mediaRotation
                ),
                outputFormat: config.outputFormat,
                targetBytes: config.targetSizeBytes ?? input.sizeOnDisk,
                lockedDimensions: config.targetDimensions,
                lockPolicy: config.autoTargetLockPolicy
            )
            commandConfig.targetDimensions = plan.targetDimensions
        }

        // 1. Decode at target-ish size when downscaling to avoid paying full HEIC decode cost.
        // Cropping needs exact source pixels first, so that path decodes full-size then scales after crop.
        let workingImage: CGImage
        if config.cropRegion == nil,
           let target = commandConfig.targetDimensions,
           target.width < editingSourceDimensions.width || target.height < editingSourceDimensions.height {
            // Large enough to cover both target dimensions, even when the target
            // doesn't keep the source's aspect ratio, plus a pixel of headroom so
            // thumbnail rounding can be trimmed to the exact target.
            let scale = max(target.width / editingSourceDimensions.width,
                            target.height / editingSourceDimensions.height)
            let longEdge = max(editingSourceDimensions.width, editingSourceDimensions.height)
            let maxPixel = Int(ceil(longEdge * min(1, scale))) + 1
            workingImage = try decodeThumbnail(source: source, maxPixelSize: maxPixel)
        } else {
            workingImage = try uprightImage(from: source)
        }

        return DecodedImage(image: workingImage, sourceDimensions: sourceDimensions, config: commandConfig)
    }

    /// Only the decode operation is retried; encoding failures retain their original error.
    /// The intermediary is full resolution and never replaces the source metadata policy.
    private func withReadableSource<T>(
        at url: URL, decode: (CGImageSource) throws -> T
    ) async throws -> T {
        try checkCancellation()
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            do { return try decode(source) }
            catch { try checkCancellation() }
        }
        let decodedURL = try await MediaPreviewRenderer.renderFirstFrame(sourceURL: url, runner: decodeRunner)
        defer { try? FileManager.default.removeItem(at: decodedURL) }
        try checkCancellation()
        guard let source = CGImageSourceCreateWithURL(decodedURL as CFURL, nil) else {
            throw ConversionError.invalidInput("Couldn't read image")
        }
        return try decode(source)
    }

    /// Upright dimensions; crop and rotation edits are relative to the displayed image.
    private func sourceImageDimensions(from source: CGImageSource) throws -> CGSize {
        guard let dimensions = ImageOrientation.orientedDimensions(of: source) else {
            throw ConversionError.invalidInput("Couldn't read image metadata")
        }
        return dimensions
    }

    /// Full-resolution decode with the source orientation tag applied.
    private func uprightImage(from source: CGImageSource) throws -> CGImage {
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ConversionError.invalidInput("Couldn't read image")
        }
        let upright = ImageOrientation.displayEdits(for: ImageOrientation.orientation(of: source))
        var working = try rotatedImage(image, rotation: upright.rotation)
        if upright.mirrored {
            working = try mirroredImage(working)
        }
        return working
    }

    private func decodeThumbnail(source: CGImageSource, maxPixelSize: Int) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        // Some large HEICs cannot use ImageIO's thumbnail decode at aggressive
        // downscales, even though their full-resolution image is readable.
        try checkCancellation()
        let image = try uprightImage(from: source)
        let scale = min(1, CGFloat(max(1, maxPixelSize)) / CGFloat(max(image.width, image.height)))
        return try resizedImage(image, to: CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale))
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

    /// Quarter turns and mirrors move pixels without changing color. Keep camera
    /// wide-color spaces such as Display P3; other spaces render through sRGB.
    private func editingColorSpace(for image: CGImage) -> CGColorSpace? {
        if let space = image.colorSpace, space.model == .rgb, space.supportsOutput,
           !CGColorSpaceUsesITUR_2100TF(space), !CGColorSpaceUsesExtendedRange(space) {
            return space
        }
        return CGColorSpace(name: CGColorSpace.sRGB)
    }

    private func rotatedImage(_ image: CGImage, rotation: MediaRotation) throws -> CGImage {
        guard rotation != .none else { return image }

        let sourceWidth = CGFloat(image.width)
        let sourceHeight = CGFloat(image.height)
        let destinationSize = rotation.applied(to: CGSize(width: sourceWidth, height: sourceHeight))
        guard let colorSpace = editingColorSpace(for: image),
              let context = CGContext(
                data: nil,
                width: Int(destinationSize.width),
                height: Int(destinationSize.height),
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ConversionError.engineFailed("Couldn't create image rotation context")
        }

        switch rotation {
        case .none:
            break
        case .clockwise90:
            context.translateBy(x: 0, y: sourceWidth)
            context.rotate(by: -.pi / 2)
        case .clockwise180:
            context.translateBy(x: sourceWidth, y: sourceHeight)
            context.rotate(by: .pi)
        case .clockwise270:
            context.translateBy(x: sourceHeight, y: 0)
            context.rotate(by: .pi / 2)
        }

        context.draw(image, in: CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight))
        guard let rotated = context.makeImage() else {
            throw ConversionError.engineFailed("Image rotation failed")
        }
        return rotated
    }

    private func mirroredImage(_ image: CGImage) throws -> CGImage {
        guard let colorSpace = editingColorSpace(for: image),
              let context = CGContext(
                data: nil,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else {
            throw ConversionError.engineFailed("Couldn't create image mirror context")
        }

        context.translateBy(x: CGFloat(image.width), y: 0)
        context.scaleBy(x: -1, y: 1)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let mirrored = context.makeImage() else {
            throw ConversionError.engineFailed("Image mirror failed")
        }
        return mirrored
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

    private static func planningInput(
        input: MediaFile,
        cropRegion: CropRegion?,
        rotation: MediaRotation
    ) -> MediaFile {
        guard let source = input.dimensions else { return input }
        let rotatedSource = rotation.applied(to: source)
        let dimensions: CGSize
        if let crop = cropRegion?.clamped(to: rotatedSource),
           !crop.isEffectivelyFullFrame(for: rotatedSource) {
            dimensions = crop.dimensions
        } else {
            dimensions = rotatedSource
        }

        guard dimensions != input.dimensions else { return input }

        return MediaFile(
            id: input.id,
            url: input.url,
            originalFilename: input.originalFilename,
            category: input.category,
            sizeOnDisk: input.sizeOnDisk,
            dimensions: dimensions,
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
