// Minimal host adapters for UIKit and unrelated services. Never reads/writes the
// real macOS/iOS clipboard. ImportService and HomeViewModel compile unmodified
// apart from removing their UIKit import in the host runner.
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

final class UIPasteboard {
    static let general = UIPasteboard()
    var changeCount = 0
    var itemProviders: [NSItemProvider] = []
    var payloads: [String: Data] = [:]
    var types: [String] { Array(payloads.keys).sorted() + itemProviders.flatMap(\.registeredTypeIdentifiers) }
    var image: UIImage?
    var hasImages: Bool { image != nil || types.contains { UTType($0)?.conforms(to: .image) == true } }
    var url: URL?
    var urls: [URL]?
    func data(forPasteboardType type: String) -> Data? { payloads[type] }
    func reset(providers: [NSItemProvider] = [], data: [String: Data] = [:]) {
        itemProviders = providers
        payloads = data
        image = nil
        url = nil
        urls = nil
        changeCount += 1
    }
}

final class UIImage {
    let cgImage: CGImage
    var size: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
    let scale: CGFloat = 1
    init(cgImage: CGImage) { self.cgImage = cgImage }
    convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        self.init(cgImage: image)
    }
    func pngData() -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
    func draw(in rect: CGRect) { UIGraphicsImageRenderer.context?.draw(cgImage, in: rect) }
}
final class UIGraphicsImageRendererFormat { var scale: CGFloat = 1 }
final class UIGraphicsImageRenderer {
    static var context: CGContext?
    let size: CGSize
    init(size: CGSize, format: UIGraphicsImageRendererFormat) { self.size = size }
    func image(actions: (Int) -> Void) -> UIImage {
        let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
                                bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        Self.context = context
        actions(0)
        Self.context = nil
        return UIImage(cgImage: context.makeImage()!)
    }
}

enum MediaCategory: String, Sendable { case image, animatedImage, audio, video }
enum ConversionError: Error { case engineFailed(String), cancelled }
enum OutputFormat { case mp4_h264, mp4_hevc, mov, webm, m4a, mp3, wav, aac, flac, ogg, opus, jpg, png, heic, webpImage, tiff }
struct MediaFile { let url: URL }
enum MediaInspector {
    static func inspect(url: URL) async throws -> MediaFile {
        guard UIImage(data: try Data(contentsOf: url)) != nil else { throw ImportError.unsupportedType }
        return MediaFile(url: url)
    }
}
enum CodecCapability {
    static func canEncode(_ format: OutputFormat) -> Bool { true }
    static func decodeIssue(for media: MediaFile) -> (codecLabel: String, reason: String)? { nil }
}
enum TempStorage { static func allowAccessWhileLocked(at url: URL) {} }
struct RemoteDownloadProgress { let bytesReceived: Int64; let totalBytes: Int64? }
struct RemoteFileDownloader {
    static let maxBytes: Int64 = 150_000_000
    func download(_ string: String, progress: ((RemoteDownloadProgress) async -> Void)?) async throws -> URL {
        throw ImportError.invalidRemoteURL
    }
}
enum Haptics { static func success() {}; static func error() {} }
final class DiagnosticsLog {
    static let shared = DiagnosticsLog()
    func record(error: Error, context: String, metadata: [String: String]) {}
    func record(message: String, context: String, metadata: [String: String], details: String) {}
}
