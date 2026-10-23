import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Recovers paragraphs, headings and lists from a PDF's text layer using line geometry.
enum PDFTextReader {
    struct Options {
        var pageBreaks = true
        /// Rasterize pages that have no text layer (scans) so the output isn't empty.
        var imagesForScannedPages = true
        /// Keep embedded pictures, placed between paragraphs in reading order.
        var includeImages = true
    }

    /// Pictures smaller than this (points) are bullets, rules or logos' fragments — not content.
    static let minimumImageSide: CGFloat = 24

    static func read(url: URL, password: String? = nil, options: Options = Options()) throws -> RichDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.unreadable("The PDF is damaged or not a PDF.")
        }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                throw password == nil ? DocumentError.passwordRequired : DocumentError.wrongPassword
            }
        }
        return read(document: document, options: options)
    }

    static func read(document: PDFDocument, options: Options = Options()) -> RichDocument {
        var lines: [[Line]] = []
        var allLines: [Line] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageLines = Self.lines(on: page)
            lines.append(pageLines)
            allLines.append(contentsOf: pageLines)
        }
        let baseSize = dominantSize(allLines)
        let placed = options.includeImages
            ? Dictionary(grouping: PDFPageImages.images(in: document, minimumSide: Int(minimumImageSide)), by: \.pageIndex)
            : [:]
        var blocks: [Block] = []
        for (index, pageLines) in lines.enumerated() {
            guard let page = document.page(at: index) else { continue }
            let pageBox = page.bounds(for: .cropBox)
            var pageBlocks: [Block]
            if pageLines.isEmpty {
                // No text layer: a scan or vector art. The rendered page is the only faithful version.
                pageBlocks = []
                if options.imagesForScannedPages, let image = PDFRasterizer.jpegData(page: page, dpi: 110, quality: 0.7) {
                    pageBlocks = [.image(ImageBlock(data: image, mimeType: "image/jpeg", size: pageBox.size, altText: "Page \(index + 1)"))]
                }
            } else {
                let images = contentImages(placed[index] ?? [], pageBox: pageBox)
                pageBlocks = interleave(lines: pageLines, images: images, baseSize: baseSize)
            }
            if options.pageBreaks, !blocks.isEmpty, !pageBlocks.isEmpty { blocks.append(.pageBreak) }
            blocks.append(contentsOf: pageBlocks)
        }
        var result = RichDocument(blocks: blocks)
        let attributes = document.documentAttributes ?? [:]
        result.metadata.title = (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfBlank
        result.metadata.author = (attributes[PDFDocumentAttribute.authorAttribute] as? String)?.nilIfBlank
        result.metadata.subject = (attributes[PDFDocumentAttribute.subjectAttribute] as? String)?.nilIfBlank
        if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? [String] {
            result.metadata.keywords = keywords
        } else if let keywords = attributes[PDFDocumentAttribute.keywordsAttribute] as? String {
            result.metadata.keywords = keywords.split(separator: ",").compactMap { String($0).nilIfBlank }
        }
        return result
    }

    /// Drops decorations and full-page backgrounds (the picture behind a scanned page's OCR text).
    static func contentImages(_ images: [PDFPageImages.PlacedImage], pageBox: CGRect) -> [PDFPageImages.PlacedImage] {
        images.filter { image in
            guard let rect = image.rect?.intersection(pageBox), !rect.isNull else { return false }
            guard rect.width >= minimumImageSide, rect.height >= minimumImageSide else { return false }
            return rect.width * rect.height < pageBox.width * pageBox.height * 0.85
        }
    }

    /// Places each picture before the first line that sits below its center, left-to-right within a row.
    static func interleave(lines: [Line], images: [PDFPageImages.PlacedImage], baseSize: CGFloat) -> [Block] {
        let rowTolerance = max(baseSize, 6)
        var pending = images.sorted { first, second in
            let a = first.rect ?? .zero, b = second.rect ?? .zero
            if abs(a.maxY - b.maxY) < rowTolerance { return a.minX < b.minX }
            return a.maxY > b.maxY
        }
        var blocks: [Block] = []
        var segment: [Line] = []
        func imageBlock(_ image: PDFPageImages.PlacedImage) -> ImageBlock {
            ImageBlock(data: image.image.data, mimeType: image.image.mimeType, size: image.rect?.size, altText: nil)
        }
        /// Takes the next picture plus any others on the same row, as one block.
        func popRow() -> Block {
            let first = pending.removeFirst()
            var row = [first]
            while let next = pending.first, let a = first.rect, let b = next.rect, abs(a.maxY - b.maxY) < rowTolerance {
                row.append(pending.removeFirst())
            }
            return row.count == 1 ? .image(imageBlock(first)) : .imageRow(row.map(imageBlock))
        }
        for line in lines {
            while let next = pending.first, let rect = next.rect, rect.midY > line.bounds.midY {
                blocks += paragraphs(from: segment, baseSize: baseSize)
                segment = []
                blocks.append(popRow())
            }
            segment.append(line)
        }
        blocks += paragraphs(from: segment, baseSize: baseSize)
        while !pending.isEmpty { blocks.append(popRow()) }
        return blocks
    }

    struct Line {
        let text: NSAttributedString
        let bounds: CGRect
        let fontSize: CGFloat
        /// Character range in `page.string`, when PDFKit can report it.
        var range: NSRange?

        var plain: String { text.string }
    }

    static func lines(on page: PDFPage) -> [Line] {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return [] }
        return selection.selectionsByLine().compactMap { lineSelection -> Line? in
            guard let attributed = lineSelection.attributedString,
                  !attributed.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            let trimmed = trimNewlines(attributed)
            var size: CGFloat = 0
            trimmed.enumerateAttribute(.font, in: NSRange(location: 0, length: trimmed.length)) { value, _, _ in
                if let font = value as? UIFont { size = max(size, font.pointSize) }
            }
            let bounds = lineSelection.bounds(for: page)
            let range = lineSelection.numberOfTextRanges(on: page) > 0 ? lineSelection.range(at: 0, on: page) : nil
            return Line(text: trimmed, bounds: bounds, fontSize: size > 0 ? size : bounds.height * 0.8, range: range)
        }
    }

    private static func trimNewlines(_ attributed: NSAttributedString) -> NSAttributedString {
        let mutable = NSMutableAttributedString(attributedString: attributed)
        while let last = mutable.string.last, last.isNewline {
            mutable.deleteCharacters(in: NSRange(location: mutable.length - 1, length: 1))
        }
        while let first = mutable.string.first, first.isNewline {
            mutable.deleteCharacters(in: NSRange(location: 0, length: 1))
        }
        return mutable
    }

    private static func dominantSize(_ lines: [Line]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in lines { weights[line.fontSize.rounded(), default: 0] += line.plain.count }
        return weights.max { $0.value < $1.value }?.key ?? 11
    }

    /// Groups lines into paragraphs using vertical gaps, indentation and font changes.
    static func paragraphs(from lines: [Line], baseSize: CGFloat) -> [Block] {
        guard !lines.isEmpty else { return [] }
        let gaps = zip(lines, lines.dropFirst()).map { $0.bounds.minY - $1.bounds.maxY }.filter { $0 > -2 }
        let typicalGap = median(gaps) ?? baseSize * 0.3
        let leftEdge = lines.map(\.bounds.minX).min() ?? 0
        var flat: [FlatBlock] = []
        var current = NSMutableAttributedString()
        var currentSize: CGFloat = 0
        var previous: Line?

        func flush() {
            guard current.length > 0 else { return }
            flat.append(contentsOf: AttributedTextImporter.blocks(for: current, baseSize: baseSize))
            current = NSMutableAttributedString()
            currentSize = 0
        }

        for line in lines {
            if let previous {
                let gap = previous.bounds.minY - line.bounds.maxY
                let sizeChanged = abs(line.fontSize - currentSize) > max(1, baseSize * 0.12)
                let startsList = AttributedTextImporter.listMarker(in: line.plain) != nil
                let bigGap = gap > max(typicalGap * 1.6, baseSize * 0.55)
                let indented = line.bounds.minX - leftEdge > baseSize * 1.2 && previous.bounds.minX - leftEdge < baseSize * 0.5
                let previousEndsShort = previous.bounds.maxX < (lines.map(\.bounds.maxX).max() ?? 0) - baseSize * 6
                    && (previous.plain.trimmingCharacters(in: .whitespaces).last.map { ".:!?".contains($0) } ?? false)
                if bigGap || sizeChanged || startsList || indented || previousEndsShort || gap < -baseSize {
                    flush()
                } else {
                    // Join wrapped lines; de-hyphenate words broken across lines.
                    if current.string.hasSuffix("-"), let first = line.plain.first, first.isLowercase {
                        current.deleteCharacters(in: NSRange(location: current.length - 1, length: 1))
                    } else if !(current.string.last?.isWhitespace ?? true) {
                        current.append(NSAttributedString(string: " ", attributes: line.text.length > 0 ? line.text.attributes(at: 0, effectiveRange: nil) : [:]))
                    }
                }
            }
            current.append(line.text)
            currentSize = max(currentSize, line.fontSize)
            previous = line
        }
        flush()
        return ListAssembler.assemble(flat)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
