import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import libwebp

// Standalone macOS regression driver; see Scripts/TestImageConversion.py.
@main
struct ImageConversionTests {
    static func main() async throws {
        if let fixture = ProcessInfo.processInfo.environment["MB_IMAGE_TEST_FALLBACK"] {
            try await verifyDecodeFallback(URL(fileURLWithPath: fixture))
        }
        try await verifyEXIFOrientation()
        try await PNGDimensionsTests.run()
        try await WebPRegressionTests.run()
        let large = ProcessInfo.processInfo.environment["MB_IMAGE_TEST_LARGE"] == "1"
        let width = large ? 8064 : 2048
        let height = large ? 6048 : 1536
        let source = try makeHEIC(width: width, height: height)
        defer { try? FileManager.default.removeItem(at: source) }
        let input = MediaFile(url: source, originalFilename: "photo.heic", category: .image,
                              sizeOnDisk: Int64(try Data(contentsOf: source).count),
                              dimensions: CGSize(width: width, height: height), containerFormat: "heic")
        try await PNGDimensionsTests.benchmark(input: input)
        try await LivePhotoViewModelTests.run(still: source)

        // The last size doesn't keep the source's aspect ratio (custom size with
        // Preserve aspect ratio off); a thumbnail decode alone would keep the source shape.
        for target in [nil, CGSize(width: 512, height: 384), CGSize(width: 512, height: height - 36)] as [CGSize?] {
            let events = Events()
            let started = Date()
            let result = try await ImageConverter().convert(
                input: input, config: ConversionConfig(outputFormat: .webpImage, targetDimensions: target),
                progress: { events.append($0) }, encodingStats: { events.append($0) }
            )
            defer { try? FileManager.default.removeItem(at: result.url) }
            let data = try Data(contentsOf: result.url)
            var decodedWidth: Int32 = 0, decodedHeight: Int32 = 0
            let decoded = data.withUnsafeBytes {
                WebPDecodeBGRA($0.baseAddress?.assumingMemoryBound(to: UInt8.self), data.count,
                               &decodedWidth, &decodedHeight)
            }
            try require(decoded != nil, "Output must decode as WebP")
            WebPFree(decoded)
            let expected = target ?? input.dimensions!
            try require(CGSize(width: Int(decodedWidth), height: Int(decodedHeight)) == expected,
                        "Output dimensions must match the requested size")
            try require(result.sizeOnDisk == Int64(data.count), "Output size must match the file")
            let progress = events.values
            log("HEIC → WebP \(decodedWidth)×\(decodedHeight): \(String(format: "%.2f", Date().timeIntervalSince(started)))s; \(progress.count) progress events")
            try require(progress.contains { $0 > 0.4 && $0 < 0.95 },
                        "WebP must report progress while encoding, not sit at 30% until finished")
            try require(progress == progress.sorted() && progress.last == 1,
                        "Progress must be monotonic and finish at 100%")
            try require(events.stats.contains { $0.activity?.hasPrefix("Encoding WebP") == true },
                        "Native encoding must report activity instead of leaving the UI at Starting")
            try require(events.stats.last?.encodedSize == "\(data.count)B",
                        "Native encoding must report the completed output size")
        }

        // Abort from inside the native encoder's progress hook, before output is published.
        let baseline = try conversionFiles()
        let converter = ImageConverter()
        do {
            let result = try await converter.convert(
                input: input, config: ConversionConfig(outputFormat: .webpImage), progress: {
                    if $0 > 0.4 && $0 < 0.95 { converter.cancel() }
                }
            )
            try? FileManager.default.removeItem(at: result.url)
            throw Failure(message: "Cancellation during WebP encoding must abort the conversion")
        } catch ConversionError.cancelled {}
        try require(try conversionFiles() == baseline, "Cancelled WebP must leave no partial output")

        log("Image conversion regression tests passed")
    }

    private static func verifyDecodeFallback(_ url: URL) async throws {
        let original = try Data(contentsOf: url)
        let native = CGImageSourceCreateWithURL(url as CFURL, nil)
        try require(native.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } == nil,
                    "JPEG-LS fixture must exercise the unsupported native decode path")
        let input = try await MediaInspector.inspect(url: url)
        try require(input.category == .image && input.dimensions == CGSize(width: 48, height: 32),
                    "FFmpeg inspection must recover image dimensions when ImageIO cannot read them")
        var config = ConversionConfig(outputFormat: .png, mediaRotation: .clockwise90)
        config.metadata.stripAll = false
        config.metadata.retainedImageTags = [ImageMetadataEntry(scope: .png, dictionaryKey: "Description",
            value: "Original source policy", imagePropertyKey: "PNG.Description")]
        let baseline = try await ImageConverter().measurePNGBaselineWithFallback(input: input, config: config)
        let output = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }
        try require(output.dimensions == CGSize(width: 32, height: 48),
                    "Fallback conversion must retain full resolution and apply rotation")
        try require(baseline.dimensions == output.dimensions && baseline.bytes == output.sizeOnDisk,
                    "Fallback PNG baseline must match the exported pixels and metadata")
        let result = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as! [String: Any]
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        try require(png?["Description"] as? String == "Original source policy",
                    "Decoding a preview intermediary must preserve the source metadata policy")
        config.targetDimensions = CGSize(width: 16, height: 24)
        let scaled = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: scaled.url) }
        try require(scaled.dimensions == config.targetDimensions, "Fallback conversion must honor selected dimensions")
        try require(try Data(contentsOf: url) == original, "Fallback inspection and conversion must not modify the source")
        log("FFmpeg image fallback: import, dimensions, rotation, scaling, PNG baseline and metadata passed")
    }

    /// Portrait camera photos store sideways pixels with a "rotate 90° clockwise"
    /// tag. Inspection, crop and export must all use the displayed orientation.
    private static func verifyEXIFOrientation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        // Stored 40×20 with a red left half and a blue right half; displayed 20×40, red on top.
        let context = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil),
              let image = context.makeImage() else { throw Failure(message: "Cannot create oriented fixture") }
        CGImageDestinationAddImage(destination, image, [kCGImagePropertyOrientation: 6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Cannot encode oriented fixture") }

        let input = try await MediaInspector.inspect(url: url)
        try require(input.dimensions == CGSize(width: 20, height: 40), "Inspection must report upright dimensions")
        var config = ConversionConfig(outputFormat: .png)
        // A retained source tag would turn the upright pixels a second time in viewers.
        config.metadata.stripAll = false
        config.metadata.retainedImageTags = [ImageMetadataEntry(scope: .tiff, dictionaryKey: "Orientation",
            value: "6", imagePropertyKey: "tiff|Orientation")]
        let baseline = try await ImageConverter().measurePNGBaselineWithFallback(input: input, config: config)
        try require(baseline.dimensions == CGSize(width: 20, height: 40), "PNG baseline must measure upright pixels")
        let output = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }
        try require(output.dimensions == CGSize(width: 20, height: 40), "Export must keep upright dimensions")
        let source = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        try require((properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1, "Export must not keep the source orientation tag")
        let exported = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try require(isRed(pixel(of: exported, x: 10, y: 5)) && !isRed(pixel(of: exported, x: 10, y: 35)),
                    "Export must apply the orientation tag to the pixels")

        config.cropRegion = CropRegion(x: 0, y: 0, width: 20, height: 20)
        let cropped = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: cropped.url) }
        let croppedImage = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(cropped.url as CFURL, nil)!, 0, nil)!
        try require(cropped.dimensions == CGSize(width: 20, height: 20)
                    && isRed(pixel(of: croppedImage, x: 10, y: 18)),
                    "Crop coordinates must refer to the upright image")
        log("EXIF orientation: inspection, PNG baseline, export pixels, crop and metadata passed")
    }

    private static func pixel(of image: CGImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let offset = (y * image.width + x) * 4
        return Array(bytes[offset..<offset + 3])
    }

    private static func isRed(_ rgb: [UInt8]) -> Bool { rgb[0] > 200 && rgb[2] < 60 }

    private static func log(_ message: String) {
        FileHandle.standardOutput.write(Data((message + "\n").utf8))
    }

    private static func makeHEIC(width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        let color = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: width * 4, space: color,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var random: UInt32 = 42
        for index in 0..<(width * height) {
            random = random &* 1_664_525 &+ 1_013_904_223
            pixels[index * 4] = UInt8(truncatingIfNeeded: random >> 24)
            pixels[index * 4 + 1] = UInt8(truncatingIfNeeded: random >> 16)
            pixels[index * 4 + 2] = UInt8(truncatingIfNeeded: random >> 8)
            pixels[index * 4 + 3] = 255
        }
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil),
              let image = context.makeImage() else { throw Failure(message: "Cannot create HEIC fixture") }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure(message: "Cannot encode HEIC fixture") }
        return url
    }

    private static func conversionFiles() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: TempStorage.directory, includingPropertiesForKeys: nil))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    private struct Failure: Error { let message: String }

    private final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var progress: [Double] = []
        private var encoding: [FFmpegEncodingDisplayStats] = []
        func append(_ value: Double) { lock.lock(); progress.append(value); lock.unlock() }
        func append(_ value: FFmpegEncodingDisplayStats) { lock.lock(); encoding.append(value); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return progress }
        var stats: [FFmpegEncodingDisplayStats] { lock.lock(); defer { lock.unlock() }; return encoding }
    }
}
