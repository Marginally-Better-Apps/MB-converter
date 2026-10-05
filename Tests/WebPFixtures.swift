import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Accelerate

/// Deterministic fixtures. "photo" is synthetic texture, not a camera photograph.
enum WebPFixtures {
    struct Failure: Error { let message: String }
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    static func image(kind: String, width: Int, height: Int) throws -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
        let pixels = ctx.data!.assumingMemoryBound(to: UInt8.self)
        var seed: UInt32 = 42
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let i = (y * width + x) * 4
            let alpha = kind == "alpha" ? (x * 255 / max(1, width - 1)) : 255
            for c in 0..<3 {
                let value: Int
                switch kind {
                case "alpha": value = [200, 100, 50][c]
                case "gradient": value = min(255, (x + y) * 255 / max(1, width + height - 2))
                case "text": value = y % 32 < 5 && x % 19 < 13 ? 0 : 255
                case "photo":
                    let smooth = 128 + 55 * sin(Double(x) / Double(17 + c * 13))
                                     + 45 * cos(Double(y) / Double(23 + c * 9))
                    value = min(255, max(0, Int(smooth) + Int((seed >> 24) & 31) - 16))
                default: value = Int((seed >> (c * 8)) & 255)
                }
                pixels[i + c] = UInt8(value * alpha / 255)
            }
            pixels[i + 3] = UInt8(alpha)
        }}
        return ctx.makeImage()!
    }

    static func write(_ image: CGImage, to url: URL, heic: Bool = false) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                (heic ? UTType.heic : UTType.png).identifier as CFString, 1, nil) else {
            throw Failure(message: "Cannot create fixture")
        }
        CGImageDestinationAddImage(destination, image,
                                  heic ? [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary : nil)
        try require(CGImageDestinationFinalize(destination), "Cannot write fixture")
    }

    static func input(_ url: URL) throws -> MediaFile {
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)!
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)! as NSDictionary
        return MediaFile(url: url, originalFilename: url.lastPathComponent, category: .image,
                         sizeOnDisk: (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value,
                         dimensions: CGSize(width: props[kCGImagePropertyPixelWidth] as! Int,
                                            height: props[kCGImagePropertyPixelHeight] as! Int),
                         containerFormat: url.pathExtension)
    }

    static func read(_ url: URL) -> CGImage {
        CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(url as CFURL, nil)!, 0, nil)!
    }

    static func rgba(_ image: CGImage) throws -> [UInt8] {
        let row = image.width * 4
        var bytes = [UInt8](repeating: 0, count: row * image.height)
        try bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: row, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var source = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(image.height),
                                       width: vImagePixelCount(image.width), rowBytes: row)
            var destination = source
            try require(vImageUnpremultiplyData_RGBA8888(&source, &destination, 0) == kvImageNoError,
                        "Cannot unpremultiply reference pixels")
        }
        return bytes
    }
}
