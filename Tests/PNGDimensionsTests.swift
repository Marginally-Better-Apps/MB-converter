import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Darwin

enum PNGDimensionsTests {
    static func run() async throws {
        try require(!OutputFormat.png.supportsTargetSize && !OutputFormat.png.isLossy, "PNG uses dimensions and stays lossless")
        for kind in ["photo", "gradient", "text", "flat", "noise", "alpha"] {
            let input = try fixture(kind: kind)
            defer { try? FileManager.default.removeItem(at: input.url) }
            let baseline = try ImageConverter().measurePNGBaseline(input: input, config: ConversionConfig(outputFormat: .png))
            for dimensions in [input.dimensions!, CGSize(width: 128, height: 96), CGSize(width: 1, height: 1)] {
                let config = ConversionConfig(outputFormat: .png, targetDimensions: dimensions)
                let output = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
                defer { try? FileManager.default.removeItem(at: output.url) }
                let decoded = try verify(output, dimensions: dimensions)
                if dimensions == input.dimensions {
                    try require(output.sizeOnDisk == baseline.bytes, "Full-size measurement matches export")
                    let source = CGImageSourceCreateWithURL(input.url as CFURL, nil)!
                    let original = CGImageSourceCreateImageAtIndex(source, 0, nil)!
                    try require(try rgba(original) == rgba(decoded), "Full-size PNG preserves color and alpha")
                }
                if kind == "alpha", dimensions.width > 1 {
                    let pixels = try rgba(decoded)
                    try require(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] < 255 }, "Resizing preserves transparency")
                }
            }
        }
        try await editsAndCancellation()
        try await firstFrame()
        let source = try fixture(kind: "photo")
        defer { try? FileManager.default.removeItem(at: source.url) }
        let jpeg = try await ImageConverter().convert(input: source, config: ConversionConfig(outputFormat: .jpg), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: jpeg.url) }
        let input = MediaFile(url: jpeg.url, originalFilename: "photo.jpg", category: .image,
                              sizeOnDisk: jpeg.sizeOnDisk, dimensions: jpeg.dimensions, containerFormat: "jpg")
        try await PNGViewModelTests.run(input: input)
        print("PNG dimensions, transparency, metadata, cancellation and estimates passed")
    }

    static func benchmark(input: MediaFile) async throws {
        let start = Date()
        let baseline = try ImageConverter().measurePNGBaseline(input: input, config: ConversionConfig(outputFormat: .png))
        let measured = Date()
        let dimensions = CGSize(width: (baseline.dimensions.width * 0.5).rounded(), height: (baseline.dimensions.height * 0.5).rounded())
        let output = try await ImageConverter().convert(input: input,
            config: ConversionConfig(outputFormat: .png, targetDimensions: dimensions), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }
        _ = try verify(output, dimensions: dimensions)
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print(String(format: "PNG %.0fMP: baseline %.2fs, single export %.2fs, process peak RSS %.0fMiB; estimate %lldB, actual %lldB",
                     baseline.dimensions.width * baseline.dimensions.height / 1_000_000,
                     measured.timeIntervalSince(start), Date().timeIntervalSince(measured),
                     Double(usage.ru_maxrss) / 1_048_576, baseline.bytes / 4, output.sizeOnDisk))
        fflush(stdout)
    }

    private static func editsAndCancellation() async throws {
        let input = try fixture(kind: "noise")
        defer { try? FileManager.default.removeItem(at: input.url) }
        var config = ConversionConfig(outputFormat: .png, targetDimensions: CGSize(width: 96, height: 128),
                                      cropRegion: CropRegion(x: 0, y: 0, width: 192, height: 256),
                                      mediaRotation: .clockwise90)
        config.metadata.stripAll = false
        config.metadata.retainedImageTags = [ImageMetadataEntry(scope: .png, dictionaryKey: "Description",
            value: "Retained description", imagePropertyKey: "PNG.Description")]
        let output = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }
        _ = try verify(output, dimensions: CGSize(width: 96, height: 128))
        let source = CGImageSourceCreateWithURL(output.url as CFURL, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [String: Any]
        let png = properties[kCGImagePropertyPNGDictionary as String] as? [String: Any]
        try require(png?["Description"] as? String == "Retained description", "Metadata survives export")
        config.targetDimensions = nil
        let baseline = try ImageConverter().measurePNGBaseline(input: input, config: config)
        let full = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: full.url) }
        try require(baseline.bytes == full.sizeOnDisk && baseline.dimensions == full.dimensions,
                    "Edited baseline includes metadata, crop and rotation")

        // A legacy byte target cannot trigger a PNG search or override dimensions.
        config.targetSizeBytes = 1
        config.targetDimensions = CGSize(width: 96, height: 128)
        let legacy = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: legacy.url) }
        _ = try verify(legacy, dimensions: CGSize(width: 96, height: 128))

        for format in [OutputFormat.jpg, .heic] {
            let output = try await ImageConverter().convert(input: input,
                config: ConversionConfig(outputFormat: format, targetSizeBytes: 60_000), progress: { _ in })
            defer { try? FileManager.default.removeItem(at: output.url) }
            _ = try verify(output, dimensions: input.dimensions!)
            try require(output.sizeOnDisk <= 60_000, "Lossy size targets still work")
        }
        let before = Set(try FileManager.default.contentsOfDirectory(at: TempStorage.directory, includingPropertiesForKeys: nil))
        let converter = ImageConverter()
        do {
            _ = try await converter.convert(input: input, config: config, progress: { if $0 == 1 { converter.cancel() } })
            throw Failure(message: "Cancellation must abort")
        } catch ConversionError.cancelled {}
        let after = Set(try FileManager.default.contentsOfDirectory(at: TempStorage.directory, includingPropertiesForKeys: nil))
        try require(before == after, "Cancelled PNG leaves no output")
    }

    private static func firstFrame() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
        defer { try? FileManager.default.removeItem(at: url) }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, try image(kind: "text", width: 128, height: 96), nil)
        CGImageDestinationAddImage(destination, try image(kind: "flat", width: 128, height: 96), nil)
        try require(CGImageDestinationFinalize(destination), "GIF fixture encodes")
        let input = MediaFile(url: url, originalFilename: "animated.gif", category: .animatedImage,
                              sizeOnDisk: Int64(try Data(contentsOf: url).count),
                              dimensions: CGSize(width: 128, height: 96), containerFormat: "gif")
        let baseline = try ImageConverter().measurePNGBaseline(input: input, config: ConversionConfig(outputFormat: .png))
        let output = try await ImageConverter().convert(input: input, config: ConversionConfig(outputFormat: .png), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: output.url) }
        let decoded = try verify(output, dimensions: input.dimensions!)
        let first = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
        try require(try rgba(first) == rgba(decoded), "GIF uses first frame")
        try require(baseline.bytes == output.sizeOnDisk, "GIF baseline measures first frame")
    }

    private static func verify(_ result: ConversionResult, dimensions: CGSize) throws -> CGImage {
        let data = try Data(contentsOf: result.url)
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw Failure(message: "Output must decode") }
        try require(result.dimensions == dimensions && CGSize(width: decoded.width, height: decoded.height) == dimensions,
                    "Selected, reported and actual dimensions match")
        try require(result.sizeOnDisk == Int64(data.count), "Reported bytes match file")
        return decoded
    }

    private static func encodeFixture(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        try require(CGImageDestinationFinalize(destination), "Fixture encodes")
        return data as Data
    }

    private static func fixture(kind: String) throws -> MediaFile {
        let image = try image(kind: kind, width: 256, height: 192)
        let data = try encodeFixture(image)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try data.write(to: url)
        return MediaFile(url: url, originalFilename: "\(kind).png", category: .image,
                         sizeOnDisk: Int64(data.count), dimensions: CGSize(width: 256, height: 192), containerFormat: "png")
    }

    private static func image(kind: String, width: Int, height: Int) throws -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: (kind == "alpha" ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue)!
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 42
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let alpha = kind == "alpha" ? x % 256 : 255
            let i = (y * width + x) * 4
            for channel in 0..<3 {
                let value: Int
                switch kind {
                case "flat": value = [40, 100, 190][channel]
                case "gradient": value = (x + y + channel * 30) % 256
                case "text": value = y % 16 < 3 && x % 11 < 7 ? 0 : 255
                case "photo": value = min(255, max(0, (x + y) / 2 + Int((seed >> 24) & 31) - 16))
                default: value = Int((seed >> (channel * 8)) & 255)
                }
                pixels[i + channel] = UInt8(value * alpha / 255)
            }
            pixels[i + 3] = UInt8(alpha)
        }}
        return context.makeImage()!
    }

    private static func rgba(_ image: CGImage) throws -> [UInt8] {
        let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: context.data!.assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
