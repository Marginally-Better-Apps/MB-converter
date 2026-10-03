import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import Vision
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

final class DocumentConverter: Converter {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func check() throws {
        try Task.checkCancellation(); lock.lock(); let stopped = cancelled; lock.unlock()
        if stopped { throw ConversionError.cancelled }
    }

    func convert(input: MediaFile, config: ConversionConfig, progress: @escaping @Sendable (Double) -> Void,
                 encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?) async throws -> ConversionResult {
        try check(); progress(0.02)
        if input.category == .document, input.containerFormat != "pdf", [.jpg, .png].contains(config.outputFormat) {
            let intermediate = TempStorage.url(for: .pdf)
            defer { try? FileManager.default.removeItem(at: intermediate) }
            let text = try await readText(input, settings: config.document)
            try writeText(text, format: .pdf, to: intermediate)
            let pdf = MediaFile(url: intermediate, originalFilename: input.originalFilename, category: .document, sizeOnDisk: 0, containerFormat: "pdf")
            return try await convert(input: pdf, config: config, progress: progress, encodingStats: encodingStats)
        }
        encodingStats?(FFmpegEncodingDisplayStats(activity: "Reading document…"))
        let output = TempStorage.url(for: config.outputFormat)
        var completed = false
        var finalURL = output
        defer { if !completed { try? FileManager.default.removeItem(at: output); try? FileManager.default.removeItem(at: finalURL) } }
        var actualFormat = config.outputFormat
        if input.containerFormat == "pdf", config.outputFormat == .pdf {
            try exportPDF(input.url, to: output, settings: config.document, progress: progress)
        } else if input.containerFormat == "pdf", [.jpg, .png].contains(config.outputFormat) {
            let (document, pages) = try pdfPages(input.url, selection: config.document.pages)
            defer { withExtendedLifetime(document) {} }
            let work = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            var exports: [FileArchive.Entry] = []
            for (index, page) in pages.enumerated() {
                try autoreleasepool {
                    try check()
                    let image = try raster(page, dpi: config.document.rasterDPI, rotation: config.document.rotation)
                    let url = pages.count == 1 ? output : work.appendingPathComponent("page-\(index + 1).\(config.outputFormat.fileExtension)")
                    try writeImage(image, to: url, format: config.outputFormat)
                    exports.append(.init(name: url.lastPathComponent, url: url))
                    progress(0.05 + 0.85 * Double(index + 1) / Double(pages.count))
                }
            }
            if pages.count > 1 {
                let zip = output.deletingPathExtension().appendingPathExtension("zip")
                do { try FileArchive.zip(exports, to: zip, check: check) }
                catch { try? FileManager.default.removeItem(at: zip); throw error }
                try FileManager.default.moveItem(at: zip, to: output)
                actualFormat = .zip
            }
        } else if input.category == .image, config.outputFormat == .pdf {
            guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 4096,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) else { throw ConversionError.invalidInput("Couldn't read image") }
            let dimensions = CGSize(width: image.width, height: image.height)
            let factor = min(1, 1440 / max(dimensions.width, dimensions.height))
            var bounds = CGRect(origin: .zero, size: CGSize(width: dimensions.width * factor, height: dimensions.height * factor))
            guard let context = CGContext(output as CFURL, mediaBox: &bounds, nil) else { throw ConversionError.engineFailed("Couldn't create PDF") }
            context.beginPDFPage(nil); context.draw(image, in: bounds); context.endPDFPage(); context.closePDF()
        } else {
            let text = try await readText(input, settings: config.document)
            try check(); progress(0.55)
            encodingStats?(FFmpegEncodingDisplayStats(activity: "Writing \(config.outputFormat.displayName)…"))
            try writeText(text, format: config.outputFormat, to: output)
        }
        try check()
        // Page bundles are correctly named and shared as ZIP files.
        if actualFormat != config.outputFormat {
            finalURL = output.deletingPathExtension().appendingPathExtension(actualFormat.fileExtension)
            try FileManager.default.moveItem(at: output, to: finalURL)
        }
        let size = (try FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        completed = true; progress(1)
        return ConversionResult(url: finalURL, outputFormat: actualFormat, sizeOnDisk: size)
    }

    func mergePDFs(_ urls: [URL], progress: @escaping @Sendable (Double) -> Void) throws -> ConversionResult {
        guard !urls.isEmpty else { throw ConversionError.invalidInput("Choose PDFs to merge") }
        let output = TempStorage.url(for: .pdf)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        var initial = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &initial, nil) else { throw ConversionError.engineFailed("Couldn't create PDF") }
        var pageCount = 0
        do {
            for (index, url) in urls.enumerated() {
                try check()
                guard let document = CGPDFDocument(url as CFURL), !document.isEncrypted, document.numberOfPages > 0 else {
                    throw ConversionError.invalidInput("Unreadable or encrypted PDF")
                }
                for pageIndex in 1...document.numberOfPages {
                    try check()
                    guard let page = document.page(at: pageIndex) else { throw ConversionError.invalidInput("Unreadable PDF page") }
                    var bounds = page.getBoxRect(.mediaBox)
                    let data = withUnsafeBytes(of: &bounds) { Data($0) } as CFData
                    context.beginPDFPage([kCGPDFContextMediaBox: data] as CFDictionary)
                    context.drawPDFPage(page); context.endPDFPage(); pageCount += 1
                }
                progress(Double(index + 1) / Double(urls.count))
            }
            context.closePDF(); try check()
        } catch { context.closePDF(); throw error }
        guard pageCount > 0 else { throw ConversionError.invalidInput("No pages to merge") }
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        completed = true
        return ConversionResult(url: output, outputFormat: .pdf, sizeOnDisk: size)
    }

    static func validate(_ url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            guard let pdf = PDFDocument(url: url), pdf.pageCount > 0, !pdf.isLocked else {
                throw ConversionError.invalidInput("Unreadable or password-protected PDF")
            }
        } else if ext == "docx" || ext == "odt" {
            let bytes = try FileArchive.read(ext == "docx" ? "word/document.xml" : "content.xml", from: url)
            guard let xml = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16),
                  xml.range(of: "<!DOCTYPE", options: .caseInsensitive) == nil else {
                throw ConversionError.invalidInput("Document XML must not contain entity declarations")
            }
            let parser = XMLParser(data: bytes); parser.shouldResolveExternalEntities = false
            guard parser.parse() else { throw ConversionError.invalidInput("Unreadable document XML") }
        } else {
            let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 16 * 1024 * 1024 else { throw ConversionError.invalidInput("Text documents are limited to 16 MB") }
            guard size > 0 else { throw ConversionError.invalidInput("Empty document") }
        }
    }

    private func readText(_ input: MediaFile, settings: DocumentExportSettings) async throws -> NSAttributedString {
        if input.category == .image {
            guard let source = CGImageSourceCreateWithURL(input.url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                         kCGImageSourceThumbnailMaxPixelSize: 4096, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else {
                throw ConversionError.invalidInput("Couldn't read image")
            }
            return styled(try recognize(image))
        }
        if input.containerFormat == "pdf" {
            var chunks: [String] = []
            let (document, pages) = try pdfPages(input.url, selection: settings.pages)
            defer { withExtendedLifetime(document) {} }
            var byteCount = 0
            for page in pages {
                try autoreleasepool {
                    try check()
                    var text = page.string ?? ""
                    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && settings.recognizeText {
                        text = try recognize(raster(page, dpi: 144, rotation: settings.rotation))
                    }
                    chunks.append(text)
                    byteCount += text.utf8.count
                    guard byteCount <= 16 * 1024 * 1024 else {
                        throw ConversionError.invalidInput("Extracted document text is too large")
                    }
                }
            }
            return styled(chunks.joined(separator: "\n\n"))
        }
        try Self.validate(input.url)
        if input.containerFormat == "docx" || input.containerFormat == "odt" {
            let data = try FileArchive.read(input.containerFormat == "docx" ? "word/document.xml" : "content.xml", from: input.url)
            let collector = DocumentXMLText(); let parser = XMLParser(data: data)
            parser.shouldResolveExternalEntities = false; parser.delegate = collector
            guard parser.parse() else { throw ConversionError.invalidInput("Unreadable document") }
            return styled(collector.text)
        }
        let bytes = try Data(contentsOf: input.url, options: .mappedIfSafe)
        if input.containerFormat == "rtf" {
            return try NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        }
        guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) else {
            throw ConversionError.invalidInput("Use UTF-8 or UTF-16 text")
        }
        if ["html", "htm"].contains(input.containerFormat) {
            // Parse local HTML without loading external CSS, images, scripts or URLs.
            let plain = text.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "(?i)<br\\s*/?>|</(?:p|div|h[1-6]|li|tr)>", with: "\n", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&quot;", with: "\"")
                .replacingOccurrences(of: "&apos;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
            return styled(plain)
        }
        if ["md", "markdown"].contains(input.containerFormat) {
            return (try? NSAttributedString(markdown: text)) ?? styled(text)
        }
        return styled(text)
    }

    func writeText(_ text: NSAttributedString, format: OutputFormat, to url: URL) throws {
        try check()
        switch format {
        case .pdf: try paginate(text, to: url)
        case .txt, .markdown: try Data(text.string.utf8).write(to: url, options: .atomic)
        case .rtf:
            try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: url, options: .atomic)
        case .html:
            try Data("<!doctype html><html><head><meta charset=\"utf-8\"></head><body><pre>\(xml(text.string))</pre></body></html>".utf8).write(to: url, options: .atomic)
        case .docx, .odt:
            // Bound escaped text and paragraph markup before building XML strings.
            let paragraphBytes = format == .docx ? 64 : 17
            var xmlBytes = 1024 + paragraphBytes
            for byte in text.string.utf8 {
                switch byte {
                case 10: xmlBytes += paragraphBytes
                case 38: xmlBytes += 5
                case 60, 62: xmlBytes += 4
                case 34: xmlBytes += 6
                default: xmlBytes += 1
                }
                guard xmlBytes <= 16 * 1024 * 1024 else {
                    throw ConversionError.invalidInput("Document XML would exceed 16 MB; split this document")
                }
            }
            let work = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: work) }
            let files: [(String, String)]
            if format == .docx {
                let paragraphs = text.string.components(separatedBy: "\n").map { "<w:p><w:r><w:t xml:space=\"preserve\">\(xml($0))</w:t></w:r></w:p>" }.joined()
                files = [
                    ("[Content_Types].xml", "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>"),
                    ("_rels/.rels", "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>"),
                    ("word/document.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\"><w:body>\(paragraphs)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/></w:sectPr></w:body></w:document>")
                ]
            } else {
                let paragraphs = text.string.components(separatedBy: "\n").map { "<text:p>\(xml($0))</text:p>" }.joined()
                files = [("mimetype", "application/vnd.oasis.opendocument.text"),
                         ("content.xml", "<?xml version=\"1.0\" encoding=\"UTF-8\"?><office:document-content xmlns:office=\"urn:oasis:names:tc:opendocument:xmlns:office:1.0\" xmlns:text=\"urn:oasis:names:tc:opendocument:xmlns:text:1.0\" office:version=\"1.2\"><office:body><office:text>\(paragraphs)</office:text></office:body></office:document-content>"),
                         ("META-INF/manifest.xml", "<?xml version=\"1.0\"?><manifest:manifest xmlns:manifest=\"urn:oasis:names:tc:opendocument:xmlns:manifest:1.0\" manifest:version=\"1.2\"><manifest:file-entry manifest:full-path=\"/\" manifest:media-type=\"application/vnd.oasis.opendocument.text\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/></manifest:manifest>")]
            }
            var entries: [FileArchive.Entry] = []
            for (index, file) in files.enumerated() {
                let entryURL = work.appendingPathComponent(String(index)); try Data(file.1.utf8).write(to: entryURL)
                entries.append(.init(name: file.0, url: entryURL))
            }
            try FileArchive.zip(entries, to: url, check: check)
        default: throw ConversionError.unsupportedConversion
        }
    }

    private func styled(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 12, nil)])
    }
    private func xml(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
    private func recognize(_ image: CGImage) throws -> String {
        try check()
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image).perform([request]); try check()
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func pageIndices(_ selection: String, count: Int) throws -> [Int] {
        let value = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return Array(0..<count) }
        var indices: [Int] = []
        for part in value.split(separator: ",", omittingEmptySubsequences: false) {
            let range = part.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(range.count), let first = Int(range[0]), first >= 1,
                  let last = range.count == 2 ? Int(range[1]) : first,
                  last >= first, last <= count else { throw ConversionError.invalidInput("Use page numbers such as 1-3, 5") }
            for index in first...last where !indices.contains(index - 1) { indices.append(index - 1) }
        }
        guard !indices.isEmpty else { throw ConversionError.invalidInput("Select at least one page") }
        return indices
    }

    private func pdfPages(_ url: URL, selection: String) throws -> (PDFDocument, [PDFPage]) {
        guard let document = PDFDocument(url: url), !document.isLocked, document.pageCount > 0 else {
            throw ConversionError.invalidInput("Unreadable or password-protected PDF")
        }
        return (document, try Self.pageIndices(selection, count: document.pageCount).compactMap { document.page(at: $0) })
    }

    private func raster(_ page: PDFPage, dpi: Double, rotation: MediaRotation) throws -> CGImage {
        let rect = page.bounds(for: .mediaBox)
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { throw ConversionError.invalidInput("Invalid PDF page size") }
        let scale = min(max(dpi, 72), 300) / 72
        let maximumPixels = Double(ConversionResourceBudget.maximumRasterPixels)
        let limited = min(scale, sqrt(maximumPixels / Double(rect.width * rect.height)))
        let size = rotation.applied(to: rect.size)
        let width = max(1, Int((size.width * limited).rounded())), height = max(1, Int((size.height * limited).rounded()))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError.engineFailed("Couldn't allocate PDF page")
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: limited, y: limited)
        apply(rotation, context: context, bounds: rect)
        page.draw(with: .mediaBox, to: context)
        guard let image = context.makeImage() else { throw ConversionError.engineFailed("Couldn't render PDF") }
        return image
    }
    private func apply(_ rotation: MediaRotation, context: CGContext, bounds: CGRect) {
        switch rotation {
        case .none: break
        case .clockwise90: context.translateBy(x: 0, y: bounds.width); context.rotate(by: -.pi / 2)
        case .clockwise180: context.translateBy(x: bounds.width, y: bounds.height); context.rotate(by: .pi)
        case .clockwise270: context.translateBy(x: bounds.height, y: 0); context.rotate(by: .pi / 2)
        }
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
    }
    private func writeImage(_ image: CGImage, to url: URL, format: OutputFormat) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, (format == .png ? UTType.png : .jpeg).identifier as CFString, 1, nil) else {
            throw ConversionError.engineFailed("Couldn't create image")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.engineFailed("Couldn't write image") }
    }

    private func exportPDF(_ input: URL, to output: URL, settings: DocumentExportSettings, progress: @escaping @Sendable (Double) -> Void) throws {
        try renderPDF(input, to: output, settings: settings, progress: progress)
        guard settings.compress else { return }
        let plain = TempStorage.url(for: .pdf)
        defer { try? FileManager.default.removeItem(at: plain) }
        let baseline: URL
        if settings.pages.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && settings.rotation == .none {
            baseline = input
        } else {
            var uncompressed = settings; uncompressed.compress = false
            try renderPDF(input, to: plain, settings: uncompressed, progress: { _ in })
            baseline = plain
        }
        try check()
        let size = try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber
        let originalSize = try FileManager.default.attributesOfItem(atPath: baseline.path)[.size] as? NSNumber
        if (originalSize?.int64Value ?? .max) <= (size?.int64Value ?? 0) {
            try FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: baseline, to: output)
        }
    }

    private func renderPDF(_ input: URL, to output: URL, settings: DocumentExportSettings, progress: @escaping @Sendable (Double) -> Void) throws {
        let (document, pages) = try pdfPages(input, selection: settings.pages)
        defer { withExtendedLifetime(document) {} }
        var first = CGRect(origin: .zero, size: settings.rotation.applied(to: pages[0].bounds(for: .mediaBox).size))
        guard let context = CGContext(output as CFURL, mediaBox: &first, nil) else { throw ConversionError.engineFailed("Couldn't create PDF") }
        defer { context.closePDF() }
        for (index, page) in pages.enumerated() {
            try autoreleasepool {
                try check()
                let original = page.bounds(for: .mediaBox)
                let bounds = CGRect(origin: .zero, size: settings.rotation.applied(to: original.size))
                var pageBounds = bounds
                let box = withUnsafeBytes(of: &pageBounds) { Data($0) } as CFData
                context.beginPDFPage([kCGPDFContextMediaBox: box] as CFDictionary)
                if settings.compress {
                    let image = try raster(page, dpi: 110, rotation: settings.rotation)
                    // Reopen the JPEG so the PDF writer can embed a compressed image stream.
                    let jpeg = NSMutableData()
                    if let destination = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) {
                        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.65] as CFDictionary)
                        if CGImageDestinationFinalize(destination), let source = CGImageSourceCreateWithData(jpeg, nil), let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                            context.draw(decoded, in: bounds)
                        } else { throw ConversionError.engineFailed("Couldn't compress PDF page") }
                    } else { throw ConversionError.engineFailed("Couldn't compress PDF page") }
                } else {
                    context.saveGState(); apply(settings.rotation, context: context, bounds: original)
                    page.draw(with: .mediaBox, to: context); context.restoreGState()
                }
                context.endPDFPage(); progress(0.05 + 0.9 * Double(index + 1) / Double(pages.count))
            }
        }
    }

    private func paginate(_ text: NSAttributedString, to output: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(output as CFURL, mediaBox: &bounds, nil) else { throw ConversionError.engineFailed("Couldn't create PDF") }
        defer { context.closePDF() }
        let setter = CTFramesetterCreateWithAttributedString(text)
        let path = CGPath(rect: bounds.insetBy(dx: 48, dy: 48), transform: nil)
        var position = 0
        repeat {
            try check(); context.beginPDFPage(nil)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: position, length: 0), path, nil)
            CTFrameDraw(frame, context); context.endPDFPage()
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 || text.length == 0 else { throw ConversionError.invalidInput("Document cannot be paginated") }
            position += visible.length
        } while position < text.length
    }
}

private final class DocumentXMLText: NSObject, XMLParserDelegate {
    var text = ""
    private var textDepth = 0
    private var byteCount = 0
    private func append(_ string: String, parser: XMLParser) {
        byteCount += string.utf8.count
        guard byteCount <= 16 * 1024 * 1024 else { parser.abortParsing(); return }
        text += string
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String]) {
        if name == "w:t" || name == "text:p" || name == "text:h" { textDepth += 1 }
        if name == "w:tab" || name == "text:tab" { append("\t", parser: parser) }
        if name == "w:br" || name == "text:line-break" { append("\n", parser: parser) }
        if name == "text:s" {
            guard let count = Int(attributes["text:c"] ?? "1"), count > 0 else { parser.abortParsing(); return }
            append(String(repeating: " ", count: min(1000, count)), parser: parser)
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if textDepth > 0 { append(string, parser: parser) }
    }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
        if name == "w:t" || name == "text:p" || name == "text:h" { textDepth -= 1 }
        if name == "w:p" || name == "text:p" || name == "text:h" { append("\n", parser: parser) }
    }
}

enum ConversionResourceBudget {
    static var maximumImagePixels: Int {
        Int(min(UInt64(768 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 8) / 16)
    }
    static var maximumRasterPixels: Int {
        let budget = min(UInt64(256 * 1024 * 1024), max(UInt64(96 * 1024 * 1024), ProcessInfo.processInfo.physicalMemory / 8))
        return Int(budget / 24)
    }
}
