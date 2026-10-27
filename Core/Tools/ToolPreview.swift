import AVFoundation
import Foundation
import ImageIO
import Observation
import PDFKit
import UIKit

/// What a tool's live preview shows while you change its options.
enum ToolPreviewKind: Sendable {
    /// Output pictures (filters, crop, text, borders, compression…).
    case image
    /// A page of the output PDF (watermark, page numbers, crop, redaction…).
    case pdf
    /// An animated GIF/WebP, played in place.
    case animation
    /// A short clip of the output video.
    case video
    /// The output audio with its waveform.
    case audio
}

extension ToolDefinition {
    var previewKind: ToolPreviewKind? { ToolPreview.kinds[id.rawValue] }
}

enum ToolPreview {
    /// Tools whose effect is visual or audible enough to preview. Structural tools (merge, split,
    /// reorder) and conversions to text formats are left out: their result isn't something you tune by eye.
    static let kinds: [String: ToolPreviewKind] = [
        "image.convert": .image, "image.compress": .image, "image.resize": .image, "image.crop": .image,
        "image.rotate": .image, "image.removebg": .image, "image.blurfaces": .image, "image.text": .image,
        "image.meme": .image, "image.border": .image, "image.round": .image, "image.adjust": .image,
        "image.pixelate": .image, "image.upscale": .image, "image.split": .image, "image.combine": .image,
        "pdf.watermark": .pdf, "pdf.pagenumbers": .pdf, "pdf.crop": .pdf, "pdf.rotate": .pdf, "pdf.grayscale": .pdf,
        "pdf.redact": .pdf, "pdf.flatten": .pdf, "pdf.compress": .pdf, "pdf.edit": .pdf, "pdf.sign": .pdf,
        "video.gif": .animation, "video.webp": .animation, "image.animated": .animation, "image.gif": .animation,
        "video.speed": .video, "video.rotate": .video, "video.loop": .video,
        "audio.adjust": .audio,
        "util.qr": .image
    ]

    /// How long to wait after the last change before re-rendering: quick for pictures, longer for media.
    static func delay(for kind: ToolPreviewKind) -> Duration {
        switch kind {
        case .image, .pdf: .milliseconds(250)
        case .animation, .audio: .milliseconds(450)
        case .video: .milliseconds(600)
        }
    }

    /// Pictures larger than this preview on a scaled copy; sizes are then shown as estimates.
    static let maximumPreviewPixels = 24_000_000
    /// Long media previews a leading excerpt rather than the whole file.
    static let videoExcerpt: Double = 5
    static let audioExcerpt: Double = 30
}

struct ToolPreviewResult: Sendable {
    var images: [CGImage] = []
    var frames: [CGImage] = []
    var frameDelay: Double = 0.1
    var mediaURL: URL?
    var waveform: [Float] = []
    var caption = ""
    /// The tool's real output file, for full-screen viewing.
    var outputURL: URL?
}

/// Re-runs a tool's real processing on (a lightweight copy of) its inputs whenever the options
/// change, so the preview is exactly what Export will produce.
@MainActor
@Observable
final class ToolPreviewModel {
    private(set) var result: ToolPreviewResult?
    /// The unprocessed input, for press-and-hold comparison.
    private(set) var original: CGImage?
    private(set) var isUpdating = false
    private(set) var message: String?
    /// Previews of very large inputs run on a scaled copy.
    private(set) var isApproximate = false

    private var task: Task<Void, Never>?
    private var generation = 0
    private var proxies: (key: [UUID], files: [ToolInputFile], sizeRatio: Double)?
    private var runDirectories: [URL] = []

    func schedule(tool: ToolDefinition, inputs: [ToolInputFile], options: ToolOptionValues, editor: ToolEditorState) {
        // Generators (QR codes) have no input file; their preview is the thing they make.
        guard let kind = tool.previewKind, !inputs.isEmpty || !tool.input.acceptsFiles else {
            reset()
            return
        }
        task?.cancel()
        generation += 1
        let current = generation
        isUpdating = true
        task = Task { [weak self] in
            // Wait for a pause in slider movement; a newer change cancels this one.
            if self?.result != nil { try? await Task.sleep(for: ToolPreview.delay(for: kind)) }
            guard !Task.isCancelled, let self else { return }
            await self.render(kind: kind, tool: tool, inputs: inputs, options: options, editor: editor, generation: current)
        }
    }

    func reset() {
        task?.cancel()
        result = nil
        original = nil
        message = nil
        isUpdating = false
        proxies = nil
        cleanUp(keeping: nil)
    }

    func tearDown() {
        reset()
    }

    private func render(kind: ToolPreviewKind, tool: ToolDefinition, inputs: [ToolInputFile],
                        options: ToolOptionValues, editor: ToolEditorState, generation current: Int) async {
        do {
            let (files, ratio) = try await proxyInputs(for: kind, inputs: inputs)
            guard current == generation else { return }
            if original == nil, let first = files.first { original = try? await Self.originalImage(kind: kind, file: first) }
            let directory = ToolStorage.newRunDirectory()
            runDirectories.append(directory)
            let context = ToolContext(inputs: files, options: options, editor: editor, outputDirectory: directory)
            let output = try await tool.run(context)
            guard current == generation, !Task.isCancelled else { return }
            let page = Self.previewPage(editor: editor)
            let built = try await Self.build(kind: kind, output: output, sizeRatio: ratio, approximate: isApproximate, page: page)
            guard current == generation else { return }
            result = built
            message = nil
            isUpdating = false
            cleanUp(keeping: directory)
        } catch is CancellationError {
            return
        } catch {
            guard current == generation else { return }
            // Keep the last good preview on screen; explain what's missing.
            message = error.localizedDescription
            isUpdating = false
        }
    }

    private func cleanUp(keeping directory: URL?) {
        for old in runDirectories where old != directory {
            try? FileManager.default.removeItem(at: old)
        }
        runDirectories = directory.map { [$0] } ?? []
    }

    // MARK: Lightweight inputs

    private func proxyInputs(for kind: ToolPreviewKind, inputs: [ToolInputFile]) async throws -> ([ToolInputFile], Double) {
        let key = inputs.map(\.id)
        if let proxies, proxies.key == key { return (proxies.files, proxies.sizeRatio) }
        var files: [ToolInputFile] = []
        var ratio = 1.0
        var approximate = false
        for input in inputs {
            let made = try await Self.proxy(for: kind, input: input)
            files.append(made.file)
            if made.approximate { approximate = true; ratio = made.sizeRatio }
        }
        isApproximate = approximate
        proxies = (key, files, ratio)
        return (files, ratio)
    }

    /// A smaller stand-in only where the full file would make previews sluggish.
    private static func proxy(for kind: ToolPreviewKind, input: ToolInputFile) async throws -> (file: ToolInputFile, approximate: Bool, sizeRatio: Double) {
        let folder = ToolStorage.newRunDirectory()
        let destination = folder.appendingPathComponent(input.url.lastPathComponent)
        switch kind {
        case .image:
            guard input.format.family == .image,
                  let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width * height > ToolPreview.maximumPreviewPixels
            else { return (input, false, 1) }
            let url = input.url
            let scaled = try await background { try ImageToolkit.load(url, maxPixelSize: 4096) }
            let proxyURL = destination.deletingPathExtension().appendingPathExtension("png")
            try await background { try ImageToolkit.encode(scaled, as: .png).write(to: proxyURL) }
            return (try ToolInputFile(url: proxyURL), true, Double(width * height) / Double(scaled.width * scaled.height))
        case .pdf:
            guard let document = PDFDocument(url: input.url), document.pageCount > 6 else { return (input, false, 1) }
            let excerpt = PDFDocument()
            for index in 0 ..< 3 { if let page = document.page(at: index)?.copy() as? PDFPage { excerpt.insert(page, at: excerpt.pageCount) } }
            guard excerpt.write(to: destination) else { return (input, false, 1) }
            let original = Double(input.byteCount), excerptSize = Double((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1)
            return (try ToolInputFile(url: destination), true, max(1, original / max(excerptSize, 1)))
        case .video:
            let asset = AVURLAsset(url: input.url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > ToolPreview.videoExcerpt + 1 else { return (input, false, 1) }
            try await MediaToolkit.trim(input.url, start: 0, end: ToolPreview.videoExcerpt, precise: false, output: destination)
            return (try ToolInputFile(url: destination), true, duration / ToolPreview.videoExcerpt)
        case .audio:
            let asset = AVURLAsset(url: input.url)
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration > ToolPreview.audioExcerpt + 5 else { return (input, false, 1) }
            let excerptURL = destination.deletingPathExtension().appendingPathExtension("m4a")
            try await MediaToolkit.trim(input.url, start: 0, end: ToolPreview.audioExcerpt, precise: true, output: excerptURL)
            return (try ToolInputFile(url: excerptURL), true, duration / ToolPreview.audioExcerpt)
        case .animation:
            return (input, false, 1)
        }
    }

    private static func originalImage(kind: ToolPreviewKind, file: ToolInputFile) async throws -> CGImage? {
        let url = file.url
        switch kind {
        case .image:
            return try await background { try ImageToolkit.load(url, maxPixelSize: 1600) }
        case .pdf:
            return try await background {
                guard let page = PDFDocument(url: url)?.page(at: 0) else { return nil }
                return PDFRasterizer.image(page: page, dpi: 110)
            }
        default:
            return nil
        }
    }

    /// The page the user is working on: where their first overlay sits, else the first page.
    private static func previewPage(editor: ToolEditorState) -> Int {
        if case .overlays(let items) = editor, let first = items.first { return first.pageIndex }
        return 0
    }

    // MARK: Building the result

    private static func build(kind: ToolPreviewKind, output: ToolOutput, sizeRatio: Double, approximate: Bool, page: Int) async throws -> ToolPreviewResult {
        guard let first = output.files.first else { throw DocumentError.empty("Nothing to preview yet.") }
        let url = first.url
        let size = Double(first.byteCount) * (approximate ? sizeRatio : 1)
        let sizeText = (approximate ? "≈ " : "") + Int64(size).formattedBytes
        var result = ToolPreviewResult(outputURL: url)
        switch kind {
        case .image:
            let urls = output.files.prefix(6).map(\.url)
            result.images = try await background { try urls.map { try ImageToolkit.load($0, maxPixelSize: 1600) } }
            let dimensions = (try? await background { () -> String in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let width = properties[kCGImagePropertyPixelWidth] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight] as? Int else { return "" }
                return "\(width) × \(height)"
            }) ?? ""
            let count = output.files.count > 1 ? "\(output.files.count) images · " : ""
            result.caption = [count + dimensions, first.format?.badge, sizeText].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · ")
        case .pdf:
            let image = try await background { () -> CGImage? in
                guard let document = PDFDocument(url: url), let page = document.page(at: min(page, max(0, document.pageCount - 1))) else { return nil }
                return PDFRasterizer.image(page: page, dpi: 110)
            }
            result.images = image.map { [$0] } ?? []
            let pages = PDFDocument(url: url)?.pageCount ?? 0
            result.caption = "Page \(page + 1) of \(pages) · \(sizeText)"
        case .animation:
            let decoded = try await background { () -> ([CGImage], Double, Int, Int) in
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return ([], 0.1, 0, 0) }
                let count = CGImageSourceGetCount(source)
                let step = max(1, count / 90)
                var frames: [CGImage] = []
                var delays = 0.0
                for index in stride(from: 0, to: count, by: step) {
                    // Thumbnail generation returns only the first frame of animated WebP; decode each frame.
                    if let frame = CGImageSourceCreateImageAtIndex(source, index, nil) { frames.append(Self.scaled(frame, maxSide: 800)) }
                    delays += Self.frameDelay(source, index) * Double(step)
                }
                let first = frames.first
                return (frames, frames.isEmpty ? 0.1 : delays / Double(frames.count), first?.width ?? 0, count)
            }
            result.frames = decoded.0
            result.frameDelay = decoded.1
            result.caption = "\(decoded.3) frames · \(first.format?.badge ?? "") · \(sizeText)"
        case .video:
            result.mediaURL = url
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            result.caption = [MetadataFormatter.durationText(duration * (approximate ? sizeRatio : 1)), first.format?.badge, sizeText]
                .compactMap { $0 }.joined(separator: " · ") + (approximate ? " · first \(Int(ToolPreview.videoExcerpt)) s" : "")
        case .audio:
            result.mediaURL = url
            result.waveform = (try? await background { AudioWaveformThumbnail.samples(from: url, barCount: 64) ?? [] }) ?? []
            let duration = (try? await AVURLAsset(url: url).load(.duration).seconds) ?? 0
            result.caption = [MetadataFormatter.durationText(duration), sizeText].joined(separator: " · ") + (approximate ? " · first \(Int(ToolPreview.audioExcerpt)) s" : "")
        }
        return result
    }

    nonisolated private static func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let largest = max(image.width, image.height)
        guard largest > maxSide else { return image }
        let scale = Double(maxSide) / Double(largest)
        let width = max(1, Int(Double(image.width) * scale)), height = max(1, Int(Double(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage() ?? image
    }

    nonisolated private static func frameDelay(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return 0.1 }
        for (dictionaryKey, unclamped, clamped) in [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime)
        ] {
            if let dictionary = properties[dictionaryKey] as? [CFString: Any] {
                let delay = (dictionary[unclamped] as? Double) ?? (dictionary[clamped] as? Double) ?? 0.1
                return delay > 0.011 ? delay : 0.1
            }
        }
        return 0.1
    }
}
