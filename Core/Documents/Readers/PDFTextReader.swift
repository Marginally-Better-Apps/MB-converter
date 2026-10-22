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
    }

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
        var blocks: [Block] = []
        for (index, pageLines) in lines.enumerated() {
            var pageBlocks = paragraphs(from: pageLines, baseSize: baseSize)
            if pageBlocks.isEmpty, options.imagesForScannedPages, let page = document.page(at: index),
               let image = PDFRasterizer.jpegData(page: page, dpi: 110, quality: 0.7) {
                let bounds = page.bounds(for: .cropBox)
                pageBlocks = [.image(ImageBlock(data: image, mimeType: "image/jpeg", size: bounds.size, altText: "Page \(index + 1)"))]
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

    struct Line {
        let text: NSAttributedString
        let bounds: CGRect
        let fontSize: CGFloat

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
            return Line(text: trimmed, bounds: bounds, fontSize: size > 0 ? size : bounds.height * 0.8)
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
