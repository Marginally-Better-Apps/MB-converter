import ExpoModulesCore
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

#if canImport(MobileCoreServices)
import MobileCoreServices
#endif

/**
 Image encode via ImageIO for JPEG / PNG / HEIC / TIFF.
 WebP is best-effort through UTType.webP when the system destination supports it
 (no vendored libwebp — keeps CI free of extra downloads).
 */
public class ImageEncodeModule: Module {
  public func definition() -> ModuleDefinition {
    Name("ImageEncodeModule")

    AsyncFunction("encode") { (params: [String: Any]) -> [String: Any] in
      try Self.encode(params: params)
    }
  }

  private static func encode(params: [String: Any]) throws -> [String: Any] {
    guard let uriString = params["uri"] as? String,
          let format = params["format"] as? String,
          let outputUriString = params["outputUri"] as? String else {
      throw Exception(name: "InvalidParams", description: "encode() requires uri, format, and outputUri")
    }

    let quality = clampQuality((params["quality"] as? Double) ?? 0.92)
    let maxPixel = intValue(params["maxPixel"])
    let crop = cropRegion(from: params["crop"] as? [String: Any])
    let inputURL = try url(from: uriString)
    let outputURL = try url(from: outputUriString)

    guard let source = CGImageSourceCreateWithURL(inputURL as CFURL, nil) else {
      throw Exception(name: "InvalidInput", description: "Couldn't read image at \(inputURL.path)")
    }

    let sourceDimensions = try imageDimensions(from: source)
    var workingImage: CGImage

    if crop == nil, let maxPixel, maxPixel > 0 {
      workingImage = try decodeThumbnail(source: source, maxPixelSize: maxPixel)
    } else {
      guard let full = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw Exception(name: "InvalidInput", description: "Couldn't decode image")
      }
      workingImage = full
    }

    if let crop {
      let clamped = clamp(crop: crop, to: sourceDimensions)
      workingImage = try croppedImage(workingImage, to: clamped)
      if let maxPixel, maxPixel > 0,
         max(workingImage.width, workingImage.height) > maxPixel {
        workingImage = try resizedImage(workingImage, maxPixel: maxPixel)
      }
    }

    let utType = try utType(for: format)
    let data = try encodeImage(workingImage, utType: utType, quality: quality)

    let parent = outputURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    try data.write(to: outputURL, options: .atomic)

    return [
      "outputUri": outputURL.absoluteString,
      "byteSize": data.count,
      "width": workingImage.width,
      "height": workingImage.height,
    ]
  }

  // MARK: - Encode

  private static func encodeImage(_ image: CGImage, utType: UTType, quality: Double) throws -> Data {
    let data = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      data as CFMutableData,
      utType.identifier as CFString,
      1,
      nil
    ) else {
      throw Exception(
        name: "EncodeFailed",
        description: "Couldn't create image destination for \(utType.identifier)"
      )
    }

    let options: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality,
      kCGImageDestinationEmbedThumbnail: false,
    ]
    CGImageDestinationAddImage(dest, image, options as CFDictionary)
    guard CGImageDestinationFinalize(dest) else {
      throw Exception(
        name: "EncodeFailed",
        description: "ImageIO finalize failed for \(utType.identifier). WebP encode may be unavailable on this OS build."
      )
    }
    return data as Data
  }

  private static func utType(for format: String) throws -> UTType {
    switch format {
    case "jpg", "jpeg":
      return .jpeg
    case "png":
      return .png
    case "heic":
      return .heic
    case "tiff", "tif":
      return .tiff
    case "webpImage", "webp":
      if let webp = UTType(filenameExtension: "webp") {
        return webp
      }
      if let webp = UTType("org.webmproject.webp") {
        return webp
      }
      throw Exception(
        name: "UnsupportedFormat",
        description: "WebP encode is not available via ImageIO on this device."
      )
    default:
      throw Exception(name: "UnsupportedFormat", description: "Unsupported image format: \(format)")
    }
  }

  // MARK: - Decode / geometry

  private static func imageDimensions(from source: CGImageSource) throws -> (width: Int, height: Int) {
    guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0 else {
      throw Exception(name: "InvalidInput", description: "Couldn't read image dimensions")
    }
    return (w, h)
  }

  private static func decodeThumbnail(source: CGImageSource, maxPixelSize: Int) throws -> CGImage {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
      throw Exception(name: "InvalidInput", description: "Couldn't create thumbnail")
    }
    return image
  }

  private static func croppedImage(_ image: CGImage, to crop: Crop) throws -> CGImage {
    let rect = CGRect(x: crop.x, y: crop.y, width: crop.width, height: crop.height)
    guard let cropped = image.cropping(to: rect) else {
      throw Exception(name: "InvalidInput", description: "Crop region is invalid")
    }
    return cropped
  }

  private static func resizedImage(_ image: CGImage, maxPixel: Int) throws -> CGImage {
    let w = image.width
    let h = image.height
    let longest = max(w, h)
    guard longest > maxPixel, longest > 0 else { return image }
    let scale = Double(maxPixel) / Double(longest)
    let targetW = max(1, Int((Double(w) * scale).rounded()))
    let targetH = max(1, Int((Double(h) * scale).rounded()))

    guard let context = CGContext(
      data: nil,
      width: targetW,
      height: targetH,
      bitsPerComponent: image.bitsPerComponent,
      bytesPerRow: 0,
      space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: image.bitmapInfo.rawValue
    ) else {
      throw Exception(name: "EncodeFailed", description: "Couldn't create resize context")
    }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
    guard let scaled = context.makeImage() else {
      throw Exception(name: "EncodeFailed", description: "Resize failed")
    }
    return scaled
  }

  // MARK: - Helpers

  private struct Crop {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
  }

  private static func cropRegion(from dict: [String: Any]?) -> Crop? {
    guard let dict else { return nil }
    guard let x = numberValue(dict["x"]),
          let y = numberValue(dict["y"]),
          let width = numberValue(dict["width"]),
          let height = numberValue(dict["height"]) else {
      return nil
    }
    return Crop(x: Int(x.rounded()), y: Int(y.rounded()), width: Int(width.rounded()), height: Int(height.rounded()))
  }

  private static func clamp(crop: Crop, to dimensions: (width: Int, height: Int)) -> Crop {
    let x = max(0, min(crop.x, dimensions.width - 1))
    let y = max(0, min(crop.y, dimensions.height - 1))
    let width = max(1, min(crop.width, dimensions.width - x))
    let height = max(1, min(crop.height, dimensions.height - y))
    return Crop(x: x, y: y, width: width, height: height)
  }

  private static func url(from uri: String) throws -> URL {
    if uri.hasPrefix("file://"), let url = URL(string: uri) {
      return url
    }
    if uri.hasPrefix("/") {
      return URL(fileURLWithPath: uri)
    }
    if let url = URL(string: uri), url.isFileURL {
      return url
    }
    throw Exception(name: "InvalidParams", description: "Invalid file URI: \(uri)")
  }

  private static func clampQuality(_ q: Double) -> Double {
    min(1, max(0, q))
  }

  private static func intValue(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let d = value as? Double { return Int(d) }
    if let n = value as? NSNumber { return n.intValue }
    return nil
  }

  private static func numberValue(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let i = value as? Int { return Double(i) }
    if let n = value as? NSNumber { return n.doubleValue }
    return nil
  }
}
