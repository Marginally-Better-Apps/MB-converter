import CoreGraphics
import Foundation

/// Format-neutral document tree. Readers produce it, writers consume it — the same hub-and-spoke
/// approach Pandoc uses, so N formats need N readers + N writers rather than N² converters.
struct RichDocument: Hashable, Sendable {
    var metadata = DocumentMetadata()
    var blocks: [Block] = []

    init(metadata: DocumentMetadata = DocumentMetadata(), blocks: [Block] = []) {
        self.metadata = metadata
        self.blocks = blocks
    }
}

struct DocumentMetadata: Hashable, Sendable {
    var title: String?
    var author: String?
    var subject: String?
    var keywords: [String] = []
    var language: String?
}

indirect enum Block: Hashable, Sendable {
    case heading(level: Int, runs: [Run])
    case paragraph(runs: [Run], alignment: TextAlignment = .natural)
    case list(ordered: Bool, items: [[Block]])
    case table(TableBlock)
    case image(ImageBlock)
    /// Pictures that sit side by side (e.g. a grid of photos in a PDF), scaled together to fit the line.
    case imageRow([ImageBlock])
    case quote([Block])
    case code(String)
    case rule
    case pageBreak
}

enum TextAlignment: String, Hashable, Sendable {
    case natural, left, center, right, justified
}

struct TableBlock: Hashable, Sendable {
    var rows: [[[Block]]]
    var hasHeaderRow: Bool

    init(rows: [[[Block]]], hasHeaderRow: Bool = false) {
        self.rows = rows
        self.hasHeaderRow = hasHeaderRow
    }

    /// Convenience for plain-text cells.
    init(textRows: [[String]], hasHeaderRow: Bool = false) {
        self.rows = textRows.map { row in
            row.map { cell in cell.isEmpty ? [] : [Block.paragraph(runs: [Run(cell)])] }
        }
        self.hasHeaderRow = hasHeaderRow
    }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }
}

struct ImageBlock: Hashable, Sendable {
    var data: Data
    var mimeType: String
    /// Intrinsic display size in points, when known.
    var size: CGSize?
    var altText: String?

    var fileExtension: String {
        switch mimeType {
        case "image/png": "png"
        case "image/gif": "gif"
        case "image/svg+xml": "svg"
        case "image/webp": "webp"
        case "image/tiff": "tiff"
        case "image/bmp": "bmp"
        default: "jpeg"
        }
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": "image/png"
        case "gif": "image/gif"
        case "svg": "image/svg+xml"
        case "webp": "image/webp"
        case "tif", "tiff": "image/tiff"
        case "bmp": "image/bmp"
        case "emf", "wmf": "image/x-\(ext.lowercased())"
        default: "image/jpeg"
        }
    }

    /// Sniffs common magic numbers so embedded images keep a correct type even with wrong extensions.
    static func sniffMimeType(_ data: Data) -> String? {
        let bytes = [UInt8](data.prefix(12))
        guard bytes.count >= 4 else { return nil }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: [0x47, 0x49, 0x46]) { return "image/gif" }
        if bytes.starts(with: [0x42, 0x4D]) { return "image/bmp" }
        if bytes.starts(with: [0x49, 0x49, 0x2A, 0x00]) || bytes.starts(with: [0x4D, 0x4D, 0x00, 0x2A]) { return "image/tiff" }
        if bytes.count >= 12, bytes[0 ..< 4] == [0x52, 0x49, 0x46, 0x46], bytes[8 ..< 12] == [0x57, 0x45, 0x42, 0x50] {
            return "image/webp"
        }
        return nil
    }
}

struct Run: Hashable, Sendable {
    var text: String
    var style: RunStyle

    init(_ text: String, _ style: RunStyle = RunStyle()) {
        self.text = text
        self.style = style
    }
}

struct RunStyle: Hashable, Sendable {
    var bold = false
    var italic = false
    var underline = false
    var strikethrough = false
    var code = false
    var superscript = false
    var `subscript` = false
    var link: String?

    static let plain = RunStyle()
    static let bold = RunStyle(bold: true)
    static let italic = RunStyle(italic: true)
}

// MARK: - Normalization & queries

extension RichDocument {
    /// All visible text, block by block, for search, tests and plain-text export.
    var plainText: String {
        PlainTextWriter.render(self)
    }

    /// Text of the first top-level heading, used as a fallback title.
    var firstHeadingText: String? {
        for block in blocks {
            if case .heading(_, let runs) = block {
                let text = runs.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { return text }
            }
        }
        return nil
    }

    var resolvedTitle: String? {
        metadata.title?.nilIfBlank ?? firstHeadingText
    }

    /// Every picture in document order, including inside lists, tables and quotes.
    var allImages: [ImageBlock] {
        func images(in blocks: [Block]) -> [ImageBlock] {
            blocks.flatMap { block -> [ImageBlock] in
                switch block {
                case .image(let image): [image]
                case .imageRow(let row): row
                case .list(_, let items): items.flatMap(images(in:))
                case .table(let table): table.rows.flatMap { $0.flatMap(images(in:)) }
                case .quote(let children): images(in: children)
                default: []
                }
            }
        }
        return images(in: blocks)
    }

    var isEffectivelyEmpty: Bool {
        plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !blocks.contains { block in
                switch block {
                case .image, .imageRow: true
                default: false
                }
            }
    }

    /// Splits the document into chapters at level-1 headings (or page breaks when there are none).
    func chapters() -> [[Block]] {
        var result: [[Block]] = [[]]
        let splitsOnHeadings = blocks.contains { if case .heading(1, _) = $0 { true } else { false } }
        for block in blocks {
            switch block {
            case .heading(1, _) where splitsOnHeadings:
                if !(result.last?.isEmpty ?? true) { result.append([]) }
                result[result.count - 1].append(block)
            case .pageBreak where !splitsOnHeadings:
                if !(result.last?.isEmpty ?? true) { result.append([]) }
            case .pageBreak:
                continue
            default:
                result[result.count - 1].append(block)
            }
        }
        return result.filter { !$0.isEmpty }
    }
}

extension Array where Element == Run {
    var plainText: String { map(\.text).joined() }

    /// Merges adjacent runs with identical styles and drops empty runs.
    func coalesced() -> [Run] {
        var result: [Run] = []
        for run in self where !run.text.isEmpty {
            if let last = result.last, last.style == run.style {
                result[result.count - 1].text += run.text
            } else {
                result.append(run)
            }
        }
        return result
    }

    /// Trims leading/trailing whitespace across the run list while keeping styles.
    func trimmed() -> [Run] {
        var runs = coalesced()
        while let first = runs.first {
            let trimmed = String(first.text.drop { $0 == " " || $0 == "\t" || $0 == "\n" })
            if trimmed.isEmpty { runs.removeFirst(); continue }
            runs[0].text = trimmed
            break
        }
        while let last = runs.last {
            var text = last.text
            while let ch = text.last, ch == " " || ch == "\t" || ch == "\n" { text.removeLast() }
            if text.isEmpty { runs.removeLast(); continue }
            runs[runs.count - 1].text = text
            break
        }
        return runs
    }
}

extension Block {
    /// Plain text of a block (used for table cells and tests).
    var plainText: String {
        PlainTextWriter.render(RichDocument(blocks: [self])).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Collapses runs of whitespace (including newlines) to single spaces, like HTML rendering.
    var collapsingWhitespace: String {
        var result = ""
        var lastWasSpace = false
        for ch in self {
            if ch.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(ch)
                lastWasSpace = false
            }
        }
        return result
    }
}

/// Shared sizing for `Block.imageRow`: natural sizes, scaled uniformly when the row is wider than the line.
enum ImageRowLayout {
    static func sizes(for images: [ImageBlock], available width: CGFloat, gap: CGFloat) -> [CGSize] {
        let natural = images.map { $0.size ?? EmbeddedImageSizing.pointSize(of: $0.data) ?? CGSize(width: 150, height: 150) }
        let total = natural.map(\.width).reduce(0, +) + gap * CGFloat(max(0, images.count - 1))
        let scale = total > width && total > 0 ? max(0.05, (width - gap * CGFloat(max(0, images.count - 1))) / natural.map(\.width).reduce(0, +)) : 1
        return natural.map { CGSize(width: $0.width * scale, height: $0.height * scale) }
    }
}
