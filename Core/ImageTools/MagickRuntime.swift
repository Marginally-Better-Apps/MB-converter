import Foundation
#if canImport(MBImageMagickBridge)
import MBImageMagickBridge
#endif

/// ImageMagick, for image formats Apple's ImageIO doesn't read or write
/// (PSD, TGA, ICO, PCX, QOI, JPEG XL, JPEG 2000, EPS output, DDS, SGI, XPM, HDR…).
enum Magick {
    struct Info: Decodable, Hashable {
        let width: Int
        let height: Int
        let frames: Int
        let format: String
    }

    static var isAvailable: Bool {
        #if canImport(MBImageMagickBridge)
        true
        #else
        false
        #endif
    }

    private static let setup: Void = {
        #if canImport(MBImageMagickBridge)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("magick", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let memory = ProcessInfo.processInfo.physicalMemory
        temporary.path.withCString { path in
            // Leave headroom for the UI and other converters; spill to disk beyond this.
            var limits = mbim_limits(
                memory_bytes: min(512 << 20, memory / 6),
                disk_bytes: 2 << 30,
                max_pixels: 200_000_000,
                max_dimension: 32_768,
                time_seconds: 240,
                threads: UInt64(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount / 2))),
                temporary_path: path
            )
            _ = mbim_initialize(&limits)
        }
        #endif
    }()

    static var version: String {
        _ = setup
        #if canImport(MBImageMagickBridge)
        return String(cString: mbim_version())
        #else
        return ""
        #endif
    }

    static let readableFormats: Set<String> = formats(writable: false)
    static let writableFormats: Set<String> = formats(writable: true)

    private static func formats(writable: Bool) -> Set<String> {
        _ = setup
        #if canImport(MBImageMagickBridge)
        guard let list = mbim_formats(writable ? 1 : 0) else { return [] }
        defer { mbim_free_string(list) }
        return Set(String(cString: list).split(separator: ",").map(String.init))
        #else
        return []
        #endif
    }

    /// ImageMagick would read these through an external Ghostscript program, which iOS can't run;
    /// the app reads them with the bundled Ghostscript library instead (see `Ghostscript`).
    private static let ghostscriptCoders: Set<String> = ["eps", "epsf", "epsi", "epi", "ept", "ps", "ps2", "ps3", "pdf", "pdfa", "ai", "xps"]

    static func canRead(_ ext: String) -> Bool {
        let coder = ext.lowercased()
        return readableFormats.contains(coder) && !ghostscriptCoders.contains(coder)
    }
    static func canWrite(_ format: String) -> Bool { writableFormats.contains(format.lowercased()) }

    /// Converts a file. `format` is an ImageMagick coder name such as "psd" or "jxl".
    static func convert(_ input: URL, to output: URL, format: String, quality: Int = 0, flatten: Bool = false, background: String? = nil) throws {
        _ = setup
        #if canImport(MBImageMagickBridge)
        try? FileManager.default.removeItem(at: output)
        var message: UnsafeMutablePointer<CChar>?
        let status = input.path.withCString { inputPath in
            output.path.withCString { outputPath in
                format.withCString { formatName in
                    if let background {
                        return background.withCString { color in
                            mbim_convert(inputPath, outputPath, formatName, Int32(quality), flatten ? 1 : 0, color, &message)
                        }
                    }
                    return mbim_convert(inputPath, outputPath, formatName, Int32(quality), flatten ? 1 : 0, nil, &message)
                }
            }
        }
        let detail = message.map { String(cString: $0) }
        if let message { mbim_free_string(message) }
        guard status == 0 else {
            try? FileManager.default.removeItem(at: output)
            throw DocumentError.writeFailed(detail ?? "ImageMagick couldn't convert the image.")
        }
        #else
        throw DocumentError.unsupportedFormat(format.uppercased())
        #endif
    }

    static func identify(_ url: URL) throws -> Info {
        _ = setup
        #if canImport(MBImageMagickBridge)
        var message: UnsafeMutablePointer<CChar>?
        guard let json = url.path.withCString({ mbim_identify($0, &message) }) else {
            let detail = message.map { String(cString: $0) }
            if let message { mbim_free_string(message) }
            throw DocumentError.unreadable(detail ?? "ImageMagick couldn't read the image.")
        }
        defer { mbim_free_string(json) }
        return try JSONDecoder().decode(Info.self, from: Data(String(cString: json).utf8))
        #else
        throw DocumentError.unsupportedFormat(url.pathExtension.uppercased())
        #endif
    }

    /// Decodes any ImageMagick-readable file to a temporary PNG that ImageIO can open.
    static func pngProxy(for url: URL) throws -> URL {
        let proxy = FileManager.default.temporaryDirectory.appendingPathComponent("magick-\(UUID().uuidString).png")
        try convert(url, to: proxy, format: "png", flatten: true)
        return proxy
    }
}
