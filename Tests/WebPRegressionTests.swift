import Foundation
import CoreGraphics
import libwebp

enum WebPRegressionTests {
    static func run() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for kind in ["alpha", "text", "gradient", "photo"] {
            let url = directory.appendingPathComponent(kind + ".png")
            try WebPFixtures.write(WebPFixtures.image(kind: kind, width: 511, height: 383), to: url)
            let input = try WebPFixtures.input(url)
            for quality in [0.6, 0.82, 0.95] {
                let result = try await ImageConverter().convert(input: input,
                    config: ConversionConfig(outputFormat: .webpImage, imageQuality: quality), progress: { _ in })
                defer { try? FileManager.default.removeItem(at: result.url) }
                let data = try Data(contentsOf: result.url)
                var width: Int32 = 0, height: Int32 = 0
                let decoded = data.withUnsafeBytes {
                    WebPDecodeRGBA($0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, &width, &height)
                }
                try WebPFixtures.require(decoded != nil && width == 511 && height == 383, "Odd-sized WebP decodes")
                defer { WebPFree(decoded) }
                if kind == "alpha" {
                    let reference = try WebPFixtures.rgba(WebPFixtures.read(url))
                    var colorError = 0.0, samples = 0
                    for i in stride(from: 0, to: reference.count, by: 4) {
                        try WebPFixtures.require(decoded![i + 3] == reference[i + 3], "Alpha must remain lossless")
                        if reference[i + 3] >= 32 {
                            for c in 0..<3 {
                                colorError += abs(Double(decoded![i+c]) - Double(reference[i+c]))
                                samples += 1
                            }
                        }
                    }
                    try WebPFixtures.require(colorError / Double(samples) < 5,
                                             "Transparent colors must not be darkened by premultiplication")
                }
            }
        }
        let input = try WebPFixtures.input(directory.appendingPathComponent("photo.png"))
        for dimensions in [CGSize(width: 1, height: 1), CGSize(width: 7, height: 5), CGSize(width: 128, height: 96)] {
            var config = ConversionConfig(outputFormat: .webpImage, targetDimensions: dimensions)
            config.mediaRotation = .clockwise90
            config.cropRegion = CropRegion(x: 10, y: 20, width: 256, height: 192)
            let result = try await ImageConverter().convert(input: input, config: config, progress: { _ in })
            defer { try? FileManager.default.removeItem(at: result.url) }
            let bytes = try Data(contentsOf: result.url)
            var w: Int32 = 0, h: Int32 = 0
            let valid = bytes.withUnsafeBytes {
                WebPGetInfo($0.baseAddress!.assumingMemoryBound(to: UInt8.self), bytes.count, &w, &h)
            }
            try WebPFixtures.require(valid != 0 && Int(w) == Int(dimensions.width) && Int(h) == Int(dimensions.height),
                                     "Crop, rotation and selected WebP dimensions must agree")
        }
        let baseline = Set(try FileManager.default.contentsOfDirectory(at: TempStorage.directory, includingPropertiesForKeys: nil))
        for phase in ["Preparing pixels…", "Encoding WebP · 0%"] {
            let converter = ImageConverter()
            do {
                _ = try await converter.convert(input: input, config: ConversionConfig(outputFormat: .webpImage),
                    progress: { _ in }, encodingStats: { if $0.activity == phase { converter.cancel() } })
                throw WebPFixtures.Failure(message: "Cancellation at \(phase) must abort")
            } catch ConversionError.cancelled {}
        }
        let oversized = directory.appendingPathComponent("oversized.png")
        try WebPFixtures.write(WebPFixtures.image(kind: "gradient", width: 16384, height: 1), to: oversized)
        do {
            _ = try await ImageConverter().convert(input: WebPFixtures.input(oversized),
                config: ConversionConfig(outputFormat: .webpImage), progress: { _ in })
            throw WebPFixtures.Failure(message: "Oversized WebP must fail")
        } catch ConversionError.invalidInput {}
        let after = Set(try FileManager.default.contentsOfDirectory(at: TempStorage.directory, includingPropertiesForKeys: nil))
        try WebPFixtures.require(baseline == after, "Cancellation and invalid dimensions leave no partial output")
        print("WebP alpha, color, dimensions, edits, cancellation and failure regressions passed")
    }
}
