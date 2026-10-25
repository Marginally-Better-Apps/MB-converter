#if SELF_TEST
import AVFoundation
import Foundation
import ImageIO
import PDFKit
import UIKit
import ZIPFoundation

/// Opens a tool's output the way a user would and checks it actually contains something
/// sensible — not just that a non-empty file exists.
enum OutputValidator {
    struct Expectations {
        /// Words from the input that should survive into text-bearing outputs.
        var text: [String] = []
        /// The output may legitimately be a single flat color (e.g. a solid background).
        var allowsFlatImage = false
        /// The output intentionally drops the text layer (e.g. rasterized pages).
        var allowsTextLoss = false
    }

    /// Returns human-readable problems; empty means the file looks right.
    static func problems(in url: URL, expecting expectations: Expectations = Expectations()) async -> [String] {
        let name = url.lastPathComponent
        guard let format = FileFormat(url: url) else { return ["\(name): unrecognized output type"] }
        do {
            switch format.family {
            case .pdf:
                return try pdfProblems(url, name: name, expectations: expectations)
            case .image:
                return try imageProblems(url, name: name, format: format, expectations: expectations)
            case .video:
                return try await mediaProblems(url, name: name, video: true)
            case .audio:
                return try await mediaProblems(url, name: name, video: false)
            case .spreadsheet:
                let workbook = try SpreadsheetConverter.read(url, format: format)
                if workbook.isEmpty { return ["\(name): spreadsheet has no cells"] }
                return textProblems(workbook.asDocument().plainText, name: name, expectations: expectations)
            case .archive:
                let archive = try Archive(url: url, accessMode: .read)
                return Array(archive).isEmpty ? ["\(name): archive is empty"] : []
            default:
                return try documentProblems(url, name: name, format: format, expectations: expectations)
            }
        } catch {
            return ["\(name): couldn't be opened (\(error.localizedDescription))"]
        }
    }

    /// Text content of text-bearing outputs (nil for pictures, media and archives).
    static func text(of url: URL) -> String? {
        guard let format = FileFormat(url: url) else { return nil }
        switch format.family {
        case .pdf:
            return PDFDocument(url: url)?.string
        case .spreadsheet:
            return (try? SpreadsheetConverter.read(url, format: format))?.asDocument().plainText
        case .document, .presentation:
            return (try? DocumentConverter.read(url, format: format))?.plainText
        default:
            return nil
        }
    }

    // MARK: - Formats

    private static func pdfProblems(_ url: URL, name: String, expectations: Expectations) throws -> [String] {
        guard let document = PDFDocument(url: url) else { return ["\(name): not a readable PDF"] }
        if document.isLocked { return [] } // Protected output: covered by the unlock round trip.
        guard document.pageCount > 0, let page = document.page(at: 0) else { return ["\(name): PDF has no pages"] }
        var problems: [String] = []
        if let image = PDFRasterizer.image(page: page, dpi: 50), ImageStats(image, side: 160).inkFraction < 0.0005 {
            problems.append("\(name): first page renders blank")
        }
        if !expectations.allowsTextLoss {
            let text = (0 ..< document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
            problems += textProblems(text, name: name, expectations: expectations)
        }
        return problems
    }

    private static func imageProblems(_ url: URL, name: String, format: FileFormat, expectations: Expectations) throws -> [String] {
        let image: CGImage
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            image = decoded
        } else {
            image = try ImageToolkit.load(url)
        }
        guard image.width > 0, image.height > 0 else { return ["\(name): image has no pixels"] }
        let stats = ImageStats(image)
        if stats.isFullyTransparent { return ["\(name): image is fully transparent"] }
        if stats.isFlat, !expectations.allowsFlatImage { return ["\(name): image is a single flat color \(stats.mean)"] }
        return []
    }

    private static func mediaProblems(_ url: URL, name: String, video: Bool) async throws -> [String] {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        // Formats AVFoundation can't open (WebM, OGG…) are probed through the FFmpeg runtime instead.
        if !(duration > 0) {
            let info = try await MediaToolkit.probe(url)
            return info.duration > 0.05 ? [] : ["\(name): media has no duration"]
        }
        guard duration > 0.05 else { return ["\(name): media is only \(duration)s long"] }
        if video {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard !tracks.isEmpty else { return ["\(name): video has no video track"] }
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            let time = min(duration / 2, 0.5)
            let frame: CGImage
            if let decoded = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                frame = decoded
            } else {
                // AVFoundation lacks some decoders (AV1 before A17 Pro, and on the simulator); use FFmpeg.
                frame = try frameWithFFmpeg(url, at: time)
            }
            if ImageStats(frame).isFlat { return ["\(name): video frame is a single flat color"] }
        } else {
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard !tracks.isEmpty else { return ["\(name): audio file has no audio track"] }
        }
        return []
    }

    private static func frameWithFFmpeg(_ url: URL, at seconds: Double) throws -> CGImage {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("frame-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: output) }
        try FFmpegCommandRunner.runBlocking("-y -ss \(seconds) -i \(FFmpegCommandRunner.quoted(url.path)) -frames:v 1 -an -c:v png \(FFmpegCommandRunner.quoted(output.path))")
        return try ImageToolkit.load(output)
    }

    private static func documentProblems(_ url: URL, name: String, format: FileFormat, expectations: Expectations) throws -> [String] {
        let document = try DocumentConverter.read(url, format: format)
        if document.isEffectivelyEmpty { return ["\(name): document is empty"] }
        return textProblems(document.plainText, name: name, expectations: expectations)
    }

    private static func textProblems(_ text: String, name: String, expectations: Expectations) -> [String] {
        let normalized = text.lowercased().replacingOccurrences(of: "\u{00AD}", with: "")
        return expectations.text.filter { !normalized.contains($0.lowercased()) }.map { "\(name): lost the text “\($0)”" }
    }
}

/// Mean color and spread over a small thumbnail.
struct ImageStats {
    let mean: (r: Double, g: Double, b: Double)
    let spread: Double
    let maxAlpha: Int
    /// Share of pixels that clearly differ from the average color (text on a page, a subject on a background).
    let inkFraction: Double

    var isFlat: Bool { spread < 2 }
    var isFullyTransparent: Bool { maxAlpha == 0 }

    /// RGBA pixels of an image scaled to `side`×`side`, composited on white.
    static func pixels(_ image: CGImage, side: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: side * side * 4)
        guard let context = CGContext(data: &buffer, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return buffer }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return buffer
    }

    init(_ image: CGImage, side: Int = 32) {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var sums = (0.0, 0.0, 0.0)
        var alpha = 0
        let count = Double(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            sums.0 += Double(pixels[index]); sums.1 += Double(pixels[index + 1]); sums.2 += Double(pixels[index + 2])
            alpha = max(alpha, Int(pixels[index + 3]))
        }
        let mean = (sums.0 / count, sums.1 / count, sums.2 / count)
        var variance = 0.0
        var ink = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let dr = Double(pixels[index]) - mean.0, dg = Double(pixels[index + 1]) - mean.1, db = Double(pixels[index + 2]) - mean.2
            let distance = (dr * dr + dg * dg + db * db) / 3
            variance += distance
            if distance > 24 * 24 { ink += 1 }
        }
        self.inkFraction = Double(ink) / count
        self.mean = mean
        self.spread = (variance / count).squareRoot()
        self.maxAlpha = alpha
    }
}
#endif
