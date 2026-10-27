import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers
import Vision

/// Still-image operations built on ImageIO, Core Image and Vision. All functions are pure
/// (CGImage in, CGImage/Data out) so they're easy to test and chain.
enum ImageToolkit {
    static let ciContext = CIContext(options: [.cacheIntermediates: false])

    enum OutputFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
        case jpeg, png, heic, webp, tiff, gif, bmp
        case avif, jxl, jp2, psd, tga, ico, ppm, pcx, qoi, dds, sgi, xpm, hdr, eps

        var id: String { rawValue }

        var label: String {
            switch self {
            case .jpeg: "JPEG"
            case .jxl: "JPEG XL"
            case .jp2: "JPEG 2000"
            case .psd: "PSD (Photoshop)"
            case .tga: "TGA"
            case .ico: "ICO (icon)"
            case .ppm: "PPM"
            case .dds: "DDS"
            case .hdr: "HDR"
            default: rawValue.uppercased()
            }
        }

        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }

        var supportsTransparency: Bool {
            switch self {
            case .png, .heic, .webp, .tiff, .gif, .avif, .jxl, .jp2, .psd, .tga, .ico, .qoi, .dds, .sgi, .xpm: true
            default: false
            }
        }

        var isLossy: Bool { [.jpeg, .heic, .webp, .avif, .jxl, .jp2].contains(self) }

        /// Formats written by Apple's ImageIO; everything else goes through ImageMagick.
        var usesImageIO: Bool {
            switch self {
            case .jpeg, .png, .heic, .tiff, .gif, .bmp: true
            case .avif: UTType("public.avif").map(ImageToolkit.imageIOCanWrite) ?? false
            default: false
            }
        }

        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .webp: .webP
            case .tiff: .tiff
            case .gif: .gif
            case .bmp: .bmp
            case .avif: UTType("public.avif") ?? .image
            default: UTType(filenameExtension: fileExtension) ?? .image
            }
        }

        /// Whether this device's runtime can produce the format at all.
        var isAvailable: Bool {
            if self == .webp || usesImageIO { return true }
            if self == .avif { return FFmpegRuntimeInfo.hasEncoder("libsvtav1") && FFmpegRuntimeInfo.hasMuxer("avif") }
            return Magick.canWrite(magickCoder)
        }

        var magickCoder: String {
            switch self {
            case .jpeg: "jpeg"
            default: rawValue
            }
        }

        init?(fileFormat: FileFormat) {
            switch fileFormat {
            case .jpeg: self = .jpeg
            case .png: self = .png
            case .heic: self = .heic
            case .webp: self = .webp
            case .tiff: self = .tiff
            case .gif: self = .gif
            case .bmp: self = .bmp
            case .avif: self = .avif
            case .jxl: self = .jxl
            case .jp2: self = .jp2
            case .psd: self = .psd
            case .tga: self = .tga
            case .ico: self = .ico
            case .pnm: self = .ppm
            case .pcx: self = .pcx
            case .qoi: self = .qoi
            case .dds: self = .dds
            case .sgi: self = .sgi
            case .xpm: self = .xpm
            case .hdr: self = .hdr
            case .eps: self = .eps
            default: return nil
            }
        }

        var fileFormat: FileFormat {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .webp: .webp
            case .tiff: .tiff
            case .gif: .gif
            case .bmp: .bmp
            case .avif: .avif
            case .jxl: .jxl
            case .jp2: .jp2
            case .psd: .psd
            case .tga: .tga
            case .ico: .ico
            case .ppm: .pnm
            case .pcx: .pcx
            case .qoi: .qoi
            case .dds: .dds
            case .sgi: .sgi
            case .xpm: .xpm
            case .hdr: .hdr
            case .eps: .eps
            }
        }

        /// Output formats offered in pickers, best-known first.
        static var available: [OutputFormat] { allCases.filter(\.isAvailable) }
    }

    static func imageIOCanWrite(_ type: UTType) -> Bool {
        let identifiers = CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []
        return identifiers.contains(type.identifier)
    }

    // MARK: - IO

    /// Decodes the first frame upright (EXIF orientation applied) at full or capped size.
    static func load(_ url: URL, maxPixelSize: CGFloat? = nil) throws -> CGImage {
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           CGImageSourceGetType(source) != nil,
           let image = try? load(source: source, maxPixelSize: maxPixelSize, name: url.lastPathComponent) {
            return image
        }
        // PSD layers, TGA, ICO, PCX, QOI, JPEG XL, DDS… decode through ImageMagick.
        guard Magick.canRead(url.pathExtension) else {
            throw DocumentError.unreadable("“\(url.lastPathComponent)” isn't a readable image.")
        }
        let proxy = try Magick.pngProxy(for: url)
        defer { try? FileManager.default.removeItem(at: proxy) }
        guard let source = CGImageSourceCreateWithURL(proxy as CFURL, nil) else {
            throw DocumentError.unreadable("“\(url.lastPathComponent)” couldn't be decoded.")
        }
        return try load(source: source, maxPixelSize: maxPixelSize, name: url.lastPathComponent)
    }

    static func load(data: Data, maxPixelSize: CGFloat? = nil) throws -> CGImage {
        if let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetType(source) != nil,
           let image = try? load(source: source, maxPixelSize: maxPixelSize, name: "image") {
            return image
        }
        // Unknown to ImageIO: let ImageMagick sniff the bytes.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("decode-\(UUID().uuidString)")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let proxy = try Magick.pngProxy(for: url)
        defer { try? FileManager.default.removeItem(at: proxy) }
        guard let source = CGImageSourceCreateWithURL(proxy as CFURL, nil) else {
            throw DocumentError.unreadable("The image data couldn't be read.")
        }
        return try load(source: source, maxPixelSize: maxPixelSize, name: "image")
    }

    private static func load(source: CGImageSource, maxPixelSize: CGFloat?, name: String) throws -> CGImage {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0
        let longest = max(width, height)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize.map { min($0, max(longest, 1)) } ?? max(longest, 1)
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return image
        }
        if let image = CGImageSourceCreateImageAtIndex(source, 0, nil) { return image }
        throw DocumentError.unreadable("“\(name)” couldn't be decoded.")
    }

    static func properties(of url: URL) -> [String: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return [:] }
        return properties
    }

    static func encode(_ image: CGImage, as format: OutputFormat, quality: Double = 0.9, preserving metadata: [CFString: Any]? = nil) throws -> Data {
        if format == .webp {
            return try ImageConverter.webPData(from: image, quality: quality)
        }
        if format == .avif, !format.usesImageIO {
            return try encodeAVIFWithFFmpeg(image, quality: quality)
        }
        if !format.usesImageIO {
            return try encodeWithMagick(image, as: format, quality: quality)
        }
        var image = image
        if !format.supportsTransparency, hasAlpha(image) {
            image = flattened(image, background: .white) ?? image
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.utType.identifier as CFString, 1, nil) else {
            throw DocumentError.writeFailed("\(format.label) encoding isn't available on this device.")
        }
        var properties: [CFString: Any] = metadata ?? [:]
        if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw DocumentError.writeFailed("\(format.label) encoding failed.")
        }
        return data as Data
    }

    /// AVIF via SVT-AV1 still-picture encoding where ImageIO can't write AVIF (older iOS).
    static func encodeAVIFWithFFmpeg(_ image: CGImage, quality: Double) throws -> Data {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("avif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let output = folder.appendingPathComponent("output.avif")
        // AV1 4:2:0 needs even dimensions; pad by at most one pixel.
        var prepared = flattened(image, background: .white) ?? image
        if prepared.width % 2 == 1 || prepared.height % 2 == 1 {
            prepared = resize(prepared, to: CGSize(width: prepared.width + prepared.width % 2, height: prepared.height + prepared.height % 2)) ?? prepared
        }
        guard let png = PDFRasterizer.encode(prepared, type: .png) else { throw DocumentError.writeFailed("Couldn't prepare the image.") }
        try png.write(to: source)
        // Map 0…1 quality onto SVT-AV1's CRF (lower is better).
        let crf = Int((63 - quality * 45).rounded())
        let command = "-y -i \(FFmpegCommandRunner.quoted(source.path)) -frames:v 1 -an -c:v libsvtav1 -pix_fmt yuv420p " +
            "-mb-codec-opt:v preset=8 -mb-codec-opt:v crf=\(min(max(crf, 10), 63)) -f avif \(FFmpegCommandRunner.quoted(output.path))"
        try FFmpegCommandRunner.runBlocking(command)
        return try Data(contentsOf: output)
    }

    /// Writes a lossless PNG intermediate and lets ImageMagick produce the target format.
    private static func encodeWithMagick(_ image: CGImage, as format: OutputFormat, quality: Double) throws -> Data {
        var source = image
        if format == .ico, max(image.width, image.height) > 256 {
            // ICO entries top out at 256×256.
            source = resize(image, mode: .maxDimension(256)) ?? image
        }
        if !format.supportsTransparency, hasAlpha(source) {
            source = flattened(source, background: .white) ?? source
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("encode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let intermediate = folder.appendingPathComponent("source.png")
        guard let png = PDFRasterizer.encode(source, type: .png) else { throw DocumentError.writeFailed("Couldn't prepare the image.") }
        try png.write(to: intermediate)
        let output = folder.appendingPathComponent("output.\(format.fileExtension)")
        let percent = format.isLossy ? Int((quality * 100).rounded()) : 0
        try Magick.convert(intermediate, to: output, format: format.magickCoder, quality: percent,
                           flatten: !format.supportsTransparency, background: format.supportsTransparency ? nil : "#ffffff")
        return try Data(contentsOf: output)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    // MARK: - Geometry

    static func context(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        CGContext(
            data: nil,
            width: max(1, width),
            height: max(1, height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = max(1, Int(size.width.rounded()))
        let height = max(1, Int(size.height.rounded()))
        guard let context = context(width: width, height: height, opaque: !hasAlpha(image)) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    enum ResizeMode: Hashable, Sendable {
        case percent(Double)
        case maxDimension(Int)
        case exact(width: Int, height: Int)
        /// As large as fits inside width × height, keeping proportions.
        case fit(width: Int, height: Int)
        case width(Int)
        case height(Int)
    }

    static func targetSize(for image: CGImage, mode: ResizeMode) -> CGSize {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        switch mode {
        case .percent(let percent):
            return CGSize(width: width * percent / 100, height: height * percent / 100)
        case .fit(let boxWidth, let boxHeight):
            let scale = min(CGFloat(boxWidth) / width, CGFloat(boxHeight) / height)
            return CGSize(width: width * scale, height: height * scale)
        case .maxDimension(let maximum):
            let scale = min(1, CGFloat(maximum) / max(width, height))
            return CGSize(width: width * scale, height: height * scale)
        case .exact(let w, let h):
            return CGSize(width: w, height: h)
        case .width(let w):
            return CGSize(width: CGFloat(w), height: height * CGFloat(w) / width)
        case .height(let h):
            return CGSize(width: width * CGFloat(h) / height, height: CGFloat(h))
        }
    }

    static func resize(_ image: CGImage, mode: ResizeMode) -> CGImage? {
        resize(image, to: targetSize(for: image, mode: mode))
    }

    /// Rotates clockwise by a multiple of 90°.
    static func rotate(_ image: CGImage, quarterTurns: Int) -> CGImage? {
        let turns = ((quarterTurns % 4) + 4) % 4
        guard turns != 0 else { return image }
        let swap = turns % 2 == 1
        let width = swap ? image.height : image.width
        let height = swap ? image.width : image.height
        guard let context = context(width: width, height: height, opaque: !hasAlpha(image)) else { return nil }
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.rotate(by: -CGFloat(turns) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    /// Rotates by any angle, expanding the canvas; uncovered corners are transparent.
    static func rotate(_ image: CGImage, degrees: Double) -> CGImage? {
        let radians = CGFloat(degrees) * .pi / 180
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height).applying(CGAffineTransform(rotationAngle: radians))
        guard let context = context(width: Int(bounds.width.rounded()), height: Int(bounds.height.rounded())) else { return nil }
        context.interpolationQuality = .high
        context.translateBy(x: bounds.width / 2, y: bounds.height / 2)
        context.rotate(by: -radians)
        context.draw(image, in: CGRect(x: -CGFloat(image.width) / 2, y: -CGFloat(image.height) / 2, width: CGFloat(image.width), height: CGFloat(image.height)))
        return context.makeImage()
    }

    static func flip(_ image: CGImage, horizontal: Bool) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, opaque: !hasAlpha(image)) else { return nil }
        if horizontal {
            context.translateBy(x: CGFloat(image.width), y: 0)
            context.scaleBy(x: -1, y: 1)
        } else {
            context.translateBy(x: 0, y: CGFloat(image.height))
            context.scaleBy(x: 1, y: -1)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// Crops using a normalized (0…1), top-left-origin rectangle.
    static func crop(_ image: CGImage, normalized rect: CGRect) -> CGImage? {
        let pixelRect = CGRect(
            x: rect.minX * CGFloat(image.width),
            y: rect.minY * CGFloat(image.height),
            width: rect.width * CGFloat(image.width),
            height: rect.height * CGFloat(image.height)
        ).integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard pixelRect.width >= 1, pixelRect.height >= 1 else { return nil }
        return image.cropping(to: pixelRect)
    }

    /// Largest centered rectangle with the given aspect ratio, normalized.
    static func centeredCrop(aspect: CGFloat, imageSize: CGSize) -> CGRect {
        let imageAspect = imageSize.width / max(imageSize.height, 1)
        if imageAspect > aspect {
            let width = aspect / imageAspect
            return CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
        }
        let height = imageAspect / aspect
        return CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
    }

    static func flattened(_ image: CGImage, background: UIColor) -> CGImage? {
        guard let context = context(width: image.width, height: image.height, opaque: true) else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return context.makeImage()
    }

    // MARK: - Filters

    private static func render(_ output: CIImage?, extent: CGRect) -> CGImage? {
        guard let output else { return nil }
        return ciContext.createCGImage(output.cropped(to: extent), from: extent)
    }

    static func grayscale(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.photoEffectMono()
        filter.inputImage = input
        return render(filter.outputImage, extent: input.extent)
    }

    static func adjust(_ image: CGImage, brightness: Double = 0, contrast: Double = 1, saturation: Double = 1) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.colorControls()
        filter.inputImage = input
        filter.brightness = Float(brightness)
        filter.contrast = Float(contrast)
        filter.saturation = Float(saturation)
        return render(filter.outputImage, extent: input.extent)
    }

    static func invert(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.colorInvert()
        filter.inputImage = input
        return render(filter.outputImage, extent: input.extent)
    }

    static func sepia(_ image: CGImage, intensity: Double = 0.9) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.sepiaTone()
        filter.inputImage = input
        filter.intensity = Float(intensity)
        return render(filter.outputImage, extent: input.extent)
    }

    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.gaussianBlur()
        filter.inputImage = input.clampedToExtent()
        filter.radius = Float(radius)
        return render(filter.outputImage, extent: input.extent)
    }

    static func sharpen(_ image: CGImage, amount: Double = 0.6) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = input
        filter.sharpness = Float(amount)
        filter.radius = 1.5
        return render(filter.outputImage, extent: input.extent)
    }

    static func pixelate(_ image: CGImage, blockSize: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.pixellate()
        filter.inputImage = input.clampedToExtent()
        filter.scale = Float(max(2, blockSize))
        filter.center = CGPoint(x: 0, y: 0)
        return render(filter.outputImage, extent: input.extent)
    }

    /// Lanczos upscale followed by gentle sharpening (no generative model, no cloud).
    static func upscale(_ image: CGImage, factor: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let filter = CIFilter.lanczosScaleTransform()
        filter.inputImage = input
        filter.scale = Float(factor)
        filter.aspectRatio = 1
        guard let scaled = filter.outputImage else { return nil }
        let sharpen = CIFilter.sharpenLuminance()
        sharpen.inputImage = scaled
        sharpen.sharpness = 0.4
        sharpen.radius = Float(1.2 * factor)
        let extent = CGRect(x: 0, y: 0, width: (CGFloat(image.width) * factor).rounded(), height: (CGFloat(image.height) * factor).rounded())
        return render(sharpen.outputImage, extent: extent)
    }

    // MARK: - Vision-powered

    enum VisionError: LocalizedError {
        case noSubject
        case unsupported

        var errorDescription: String? {
            switch self {
            case .noSubject: "No clear subject was found in this image."
            case .unsupported: "Subject detection isn't available on this device."
            }
        }
    }

    /// Soft subject mask (white = subject) at the image's size.
    static func subjectMask(_ image: CGImage) throws -> CIImage {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let request = VNGenerateForegroundInstanceMaskRequest()
        do {
            try handler.perform([request])
        } catch {
            // Simulators and older devices lack the Neural Engine path; fall back to people segmentation.
            let person = VNGeneratePersonSegmentationRequest()
            person.qualityLevel = .accurate
            person.outputPixelFormat = kCVPixelFormatType_OneComponent8
            do {
                try handler.perform([person])
            } catch {
                throw VisionError.unsupported
            }
            guard let buffer = person.results?.first?.pixelBuffer else { throw VisionError.noSubject }
            let mask = CIImage(cvPixelBuffer: buffer)
            let scaleX = CGFloat(image.width) / mask.extent.width
            let scaleY = CGFloat(image.height) / mask.extent.height
            return mask.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw VisionError.noSubject
        }
        let buffer = try observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler)
        return CIImage(cvPixelBuffer: buffer)
    }

    enum BackgroundStyle: Hashable, Sendable {
        case transparent
        case color(UInt32)
        case blur(radius: Double)
    }

    static func replaceBackground(_ image: CGImage, with style: BackgroundStyle) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let mask = try subjectMask(image)
        let background: CIImage = switch style {
        case .transparent:
            CIImage(color: .clear).cropped(to: input.extent)
        case .color(let hex):
            CIImage(color: CIColor(color: UIColor(hex: hex))).cropped(to: input.extent)
        case .blur(let radius):
            input.clampedToExtent().applyingGaussianBlur(sigma: radius).cropped(to: input.extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = input
        blend.backgroundImage = background
        blend.maskImage = mask
        guard let output = render(blend.outputImage, extent: input.extent) else {
            throw DocumentError.writeFailed("Couldn't composite the subject.")
        }
        return output
    }

    /// Face rectangles in normalized, top-left-origin coordinates.
    static func faceRects(_ image: CGImage) throws -> [CGRect] {
        let request = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).map { face in
            let box = face.boundingBox
            return CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
        }
    }

    enum FaceObscureStyle: String, CaseIterable, Identifiable, Hashable, Sendable {
        case blur, pixelate, box
        var id: String { rawValue }
        var label: String { self == .box ? "Solid box" : rawValue.capitalized }
    }

    static func obscure(_ image: CGImage, regions: [CGRect], style: FaceObscureStyle) -> CGImage? {
        guard !regions.isEmpty else { return image }
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let effect: CGImage? = switch style {
        case .blur: blur(image, radius: max(width, height) / 40)
        case .pixelate: pixelate(image, blockSize: max(width, height) / 45)
        case .box: nil
        }
        guard let context = context(width: image.width, height: image.height, opaque: !hasAlpha(image)) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for region in regions {
            // Pad faces so hairlines and chins are covered; convert to bottom-left space.
            let padded = CGRect(x: region.minX - region.width * 0.15, y: region.minY - region.height * 0.2, width: region.width * 1.3, height: region.height * 1.35)
            let rect = CGRect(x: padded.minX * width, y: (1 - padded.maxY) * height, width: padded.width * width, height: padded.height * height)
            context.saveGState()
            context.addEllipse(in: rect)
            context.clip()
            if let effect {
                context.draw(effect, in: CGRect(x: 0, y: 0, width: width, height: height))
            } else {
                context.setFillColor(UIColor.black.cgColor)
                context.fill(rect)
            }
            context.restoreGState()
        }
        return context.makeImage()
    }

    // MARK: - Decoration

    static func addBorder(_ image: CGImage, width borderWidth: Int, colorHex: UInt32, cornerRadius: Double = 0) -> CGImage? {
        let width = image.width + borderWidth * 2
        let height = image.height + borderWidth * 2
        guard let context = context(width: width, height: height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let radius = CGFloat(cornerRadius) / 100 * CGFloat(min(width, height)) / 2
        let outer = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
        context.addPath(outer)
        context.setFillColor(UIColor(hex: colorHex).cgColor)
        context.fillPath()
        let inner = bounds.insetBy(dx: CGFloat(borderWidth), dy: CGFloat(borderWidth))
        let innerRadius = max(0, radius - CGFloat(borderWidth))
        context.addPath(CGPath(roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil))
        context.clip()
        context.draw(image, in: inner)
        return context.makeImage()
    }

    /// Rounds corners (radius as % of the short side / 2); 100% gives a circle/ellipse.
    static func roundCorners(_ image: CGImage, percent: Double, makeSquare: Bool = false) -> CGImage? {
        var source = image
        if makeSquare, image.width != image.height {
            let side = min(image.width, image.height)
            let rect = CGRect(x: (image.width - side) / 2, y: (image.height - side) / 2, width: side, height: side)
            source = image.cropping(to: rect) ?? image
        }
        guard let context = context(width: source.width, height: source.height) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let radius = CGFloat(min(max(percent, 0), 100)) / 100 * min(bounds.width, bounds.height) / 2
        context.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        context.draw(source, in: bounds)
        return context.makeImage()
    }

    struct Caption: Hashable, Sendable {
        var text: String
        var placement: PDFStamper.Placement = .bottom
        /// Font size as a fraction of the image's short side.
        var relativeSize: Double = 0.07
        var colorHex: UInt32 = 0xFFFFFF
        var outlineHex: UInt32 = 0x000000
        var opacity: Double = 1
        var outlined = true
        var rotation: Double = 0
        var font: CaptionRenderer.Font = .bold
        /// Center of the text as fractions of the image (top-left origin); overrides `placement`.
        var position: CGPoint?
    }

    /// Draws text (watermark, meme caption) onto an image.
    static func addText(_ image: CGImage, _ caption: Caption) -> CGImage? {
        addText(image, [caption])
    }

    /// Draws several captions onto an image in one pass.
    static func addText(_ image: CGImage, _ captions: [Caption]) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image)
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            for caption in captions {
                CaptionRenderer.draw(caption, imageSize: size, in: context.cgContext)
            }
        }.cgImage
    }

    static func overlay(_ image: CGImage, logo: CGImage, relativeWidth: Double, opacity: Double, placement: PDFStamper.Placement) -> CGImage? {
        let size = CGSize(width: image.width, height: image.height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
            let width = size.width * relativeWidth
            let height = width * CGFloat(logo.height) / CGFloat(max(logo.width, 1))
            let center = PDFStamper.anchor(for: placement, size: size, item: CGSize(width: width, height: height), margin: min(size.width, size.height) * 0.04)
            UIImage(cgImage: logo).draw(in: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), blendMode: .normal, alpha: opacity)
        }.cgImage
    }

    // MARK: - Compose & split

    static func split(_ image: CGImage, rows: Int, columns: Int) -> [CGImage] {
        guard rows > 0, columns > 0 else { return [image] }
        let tileWidth = image.width / columns
        let tileHeight = image.height / rows
        guard tileWidth > 0, tileHeight > 0 else { return [image] }
        var tiles: [CGImage] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                // The last row/column absorbs remainder pixels.
                let width = column == columns - 1 ? image.width - tileWidth * column : tileWidth
                let height = row == rows - 1 ? image.height - tileHeight * row : tileHeight
                if let tile = image.cropping(to: CGRect(x: column * tileWidth, y: row * tileHeight, width: width, height: height)) {
                    tiles.append(tile)
                }
            }
        }
        return tiles
    }

    enum CombineLayout: String, CaseIterable, Identifiable, Hashable, Sendable {
        case horizontal, vertical, grid
        var id: String { rawValue }
        var label: String {
            switch self {
            case .horizontal: "Side by side"
            case .vertical: "Stacked"
            case .grid: "Grid"
            }
        }
    }

    /// Stitches images together. Rows/columns are normalized to a common height/width.
    static func combine(_ images: [CGImage], layout: CombineLayout, spacing: Int = 0, backgroundHex: UInt32 = 0xFFFFFF, maxSide: Int = 6_000) -> CGImage? {
        guard !images.isEmpty else { return nil }
        let background = UIColor(hex: backgroundHex).cgColor
        switch layout {
        case .horizontal:
            let height = min(images.map(\.height).max() ?? 1, maxSide)
            let widths = images.map { Int((CGFloat($0.width) * CGFloat(height) / CGFloat($0.height)).rounded()) }
            let total = widths.reduce(0, +) + spacing * (images.count - 1)
            let scale = total > maxSide * 2 ? CGFloat(maxSide * 2) / CGFloat(total) : 1
            guard let context = context(width: Int(CGFloat(total) * scale), height: Int(CGFloat(height) * scale), opaque: true) else { return nil }
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.interpolationQuality = .high
            var x: CGFloat = 0
            for (image, width) in zip(images, widths) {
                context.draw(image, in: CGRect(x: x, y: 0, width: CGFloat(width) * scale, height: CGFloat(height) * scale))
                x += (CGFloat(width) + CGFloat(spacing)) * scale
            }
            return context.makeImage()
        case .vertical:
            let width = min(images.map(\.width).max() ?? 1, maxSide)
            let heights = images.map { Int((CGFloat($0.height) * CGFloat(width) / CGFloat($0.width)).rounded()) }
            let total = heights.reduce(0, +) + spacing * (images.count - 1)
            let scale = total > maxSide * 2 ? CGFloat(maxSide * 2) / CGFloat(total) : 1
            guard let context = context(width: Int(CGFloat(width) * scale), height: Int(CGFloat(total) * scale), opaque: true) else { return nil }
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.interpolationQuality = .high
            // Bitmap y runs bottom-up: lay out from the top.
            var y = CGFloat(context.height)
            for (image, height) in zip(images, heights) {
                let h = CGFloat(height) * scale
                y -= h
                context.draw(image, in: CGRect(x: 0, y: y, width: CGFloat(width) * scale, height: h))
                y -= CGFloat(spacing) * scale
            }
            return context.makeImage()
        case .grid:
            let columns = Int(ceil(sqrt(Double(images.count))))
            let rows = Int(ceil(Double(images.count) / Double(columns)))
            let cell = min(images.map { min($0.width, $0.height) }.max() ?? 512, maxSide / max(columns, 1))
            let width = columns * cell + spacing * (columns - 1)
            let height = rows * cell + spacing * (rows - 1)
            guard let context = context(width: width, height: height, opaque: true) else { return nil }
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            for (index, image) in images.enumerated() {
                let row = index / columns
                let column = index % columns
                let origin = CGPoint(x: column * (cell + spacing), y: height - (row + 1) * cell - row * spacing)
                // Center-crop each image to a square cell.
                let crop = centeredCrop(aspect: 1, imageSize: CGSize(width: image.width, height: image.height))
                let square = self.crop(image, normalized: crop) ?? image
                context.draw(square, in: CGRect(origin: origin, size: CGSize(width: cell, height: cell)))
            }
            return context.makeImage()
        }
    }

    // MARK: - GIF & QR

    static func animatedGIF(_ frames: [CGImage], frameDelay: Double, loopCount: Int = 0, maxSide: Int = 800) throws -> Data {
        guard !frames.isEmpty else { throw DocumentError.empty("Add at least one image.") }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, frames.count, nil) else {
            throw DocumentError.writeFailed("GIF encoder unavailable.")
        }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]] as CFDictionary)
        // All frames share the first frame's size so the animation doesn't jump.
        let reference = frames[0]
        let canvas = targetSize(for: reference, mode: .maxDimension(maxSide))
        for frame in frames {
            let fitted = fit(frame, into: canvas) ?? frame
            CGImageDestinationAddImage(destination, fitted, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: frameDelay, kCGImagePropertyGIFUnclampedDelayTime: frameDelay]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw DocumentError.writeFailed("GIF encoding failed.") }
        return data as Data
    }

    /// Letterboxes an image into a canvas of the given size (white background).
    static func fit(_ image: CGImage, into size: CGSize) -> CGImage? {
        let width = Int(size.width.rounded())
        let height = Int(size.height.rounded())
        guard let context = context(width: width, height: height, opaque: true) else { return nil }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        let scale = min(size.width / CGFloat(image.width), size.height / CGFloat(image.height))
        let drawSize = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.draw(image, in: CGRect(x: (size.width - drawSize.width) / 2, y: (size.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        return context.makeImage()
    }

    enum QRCorrection: String, CaseIterable, Identifiable, Hashable, Sendable {
        case low = "L", medium = "M", quartile = "Q", high = "H"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .low: "Simplest pattern"
            case .medium: "Standard"
            case .quartile: "Sturdy"
            case .high: "Sturdiest (room for a logo)"
            }
        }
    }

    static func qrCode(_ text: String, size: Int = 1024, correction: QRCorrection = .medium, foregroundHex: UInt32 = 0x000000, backgroundHex: UInt32 = 0xFFFFFF) throws -> CGImage {
        guard !text.isEmpty else { throw DocumentError.invalidOption("Enter text or a link to encode.") }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = correction.rawValue
        guard let output = filter.outputImage else { throw DocumentError.writeFailed("The text is too long for a QR code.") }
        let colored = output.applyingFilter("CIFalseColor", parameters: [
            "inputColor0": CIColor(color: UIColor(hex: foregroundHex)),
            "inputColor1": CIColor(color: UIColor(hex: backgroundHex))
        ])
        // Quiet zone of 4 modules, then integer scaling keeps modules crisp.
        let modules = output.extent.width + 8
        let scale = max(1, (CGFloat(size) / modules).rounded(.down))
        let padded = colored.transformed(by: CGAffineTransform(translationX: 4, y: 4))
            .composited(over: CIImage(color: CIColor(color: UIColor(hex: backgroundHex))).cropped(to: CGRect(x: 0, y: 0, width: modules, height: modules)))
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let image = ciContext.createCGImage(padded, from: padded.extent) else {
            throw DocumentError.writeFailed("Couldn't render the QR code.")
        }
        return image
    }

    static func decodeQRCodes(in image: CGImage) -> [String] {
        let request = VNDetectBarcodesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let vision = (request.results ?? []).compactMap(\.payloadStringValue)
        if !vision.isEmpty { return vision }
        // Core Image's detector works where Vision's barcode model isn't available (e.g. simulators).
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        return (detector?.features(in: CIImage(cgImage: image)) ?? []).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
    }
}
