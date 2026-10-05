// Frozen pre-optimization WebP encoder for benchmark comparisons only.
    private struct WebPBGRARaster {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bgra: Data
    }

    /// Materializes ImageIO's potentially lazy HEIC decode before importing pixels into libwebp.
    private func rasterizeBGRAForWebP(image: CGImage) throws -> WebPBGRARaster {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0, width <= WEBP_MAX_DIMENSION, height <= WEBP_MAX_DIMENSION else {
            throw ConversionError.invalidInput("WebP supports images up to \(WEBP_MAX_DIMENSION) pixels per side. Choose a smaller resolution.")
        }
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

    private func encodeWebPFromRaster(
        _ raster: WebPBGRARaster, quality: Double, progress: @escaping (Double) -> Void
    ) throws -> Data {
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

        try raster.bgra.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw ConversionError.engineFailed("WebP raster buffer unavailable")
            }
            guard WebPPictureImportBGRA(&picture, base, Int32(raster.bytesPerRow)) != 0 else {
                throw ConversionError.engineFailed("WebP picture import failed")
            }
        }
        try checkCancellation()

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
        let raster = try rasterizeBGRAForWebP(image: image)
        try checkCancellation()
        return try encodeWebPFromRaster(raster, quality: quality) { fraction in
            encodingStats?(FFmpegEncodingDisplayStats(activity: "Encoding WebP · \(Int((fraction * 100).rounded()))%"))
            progress(min(0.95, 0.4 + fraction * 0.55))
        }
    }

