import CoreGraphics
import Foundation

/// Reads OpenDocument Text (.odt) into a `RichDocument`.
struct ODTReader {
    static func read(url: URL) throws -> RichDocument {
        var reader = ODTReader(package: try ZipPackageReader(url: url))
        return try reader.read()
    }

    private let package: ZipPackageReader
    private var textStyles: [String: RunStyle] = [:]
    private var paragraphStyles: [String: ParagraphInfo] = [:]
    private var listStyles: [String: [Int: Bool]] = [:] // style -> level -> ordered

    private struct ParagraphInfo {
        var parent: String?
        var run = RunStyle()
        var alignment: TextAlignment = .natural
        var breakBefore = false
        var headingLevel: Int?
    }

    init(package: ZipPackageReader) {
        self.package = package
    }

    mutating func read() throws -> RichDocument {
        let content = try package.xml(at: "content.xml")
        if let styles = package.xmlIfPresent(at: "styles.xml") {
            loadStyles(from: styles.child("styles"))
            loadStyles(from: styles.child("automatic-styles"))
        }
        loadStyles(from: content.child("automatic-styles"))
        guard let text = content.child("body")?.child("text") else {
            throw DocumentError.unreadable("The document has no text body.")
        }
        var document = RichDocument(blocks: blocks(in: text, listLevel: 0))
        document.metadata = metadata()
        return document
    }

    private func metadata() -> DocumentMetadata {
        var metadata = DocumentMetadata()
        guard let meta = package.xmlIfPresent(at: "meta.xml")?.child("meta") else { return metadata }
        metadata.title = meta.child("title")?.text.nilIfBlank
        metadata.author = (meta.child("creator") ?? meta.child("initial-creator"))?.text.nilIfBlank
        metadata.subject = meta.child("subject")?.text.nilIfBlank
        metadata.keywords = meta.children("keyword").compactMap { $0.text.nilIfBlank }
        return metadata
    }

    private mutating func loadStyles(from container: XElement?) {
        guard let container else { return }
        for style in container.children("style") {
            guard let name = style.attribute("style:name") else { continue }
            let family = style.attribute("style:family")
            var run = RunStyle()
            if let props = style.child("text-properties") {
                run.bold = props.attribute("fo:font-weight").map { $0 == "bold" || (Int($0) ?? 400) >= 600 } ?? false
                run.italic = props.attribute("fo:font-style").map { $0 == "italic" || $0 == "oblique" } ?? false
                run.underline = props.attribute("style:text-underline-style").map { $0 != "none" } ?? false
                run.strikethrough = props.attribute("style:text-line-through-style").map { $0 != "none" } ?? false
                if let position = props.attribute("style:text-position") {
                    run.superscript = position.hasPrefix("super") || (Double(position.split(separator: "%").first ?? "") ?? 0) > 0
                    run.subscript = position.hasPrefix("sub") || (Double(position.split(separator: "%").first ?? "") ?? 0) < 0
                }
                let font = (props.attribute("style:font-name") ?? props.attribute("fo:font-family") ?? "").lowercased()
                run.code = font.contains("courier") || font.contains("mono") || font.contains("consolas")
            }
            if family == "text" {
                textStyles[name] = run
            } else if family == "paragraph" {
                var info = ParagraphInfo(parent: style.attribute("style:parent-style-name"), run: run)
                if let props = style.child("paragraph-properties") {
                    switch props.attribute("fo:text-align") {
                    case "center": info.alignment = .center
                    case "end", "right": info.alignment = .right
                    case "justify": info.alignment = .justified
                    default: break
                    }
                    info.breakBefore = props.attribute("fo:break-before") == "page"
                }
                if let level = style.attribute("style:default-outline-level").flatMap(Int.init) {
                    info.headingLevel = level
                }
                paragraphStyles[name] = info
            }
        }
        for listStyle in container.children("list-style") {
            guard let name = listStyle.attribute("style:name") else { continue }
            var levels: [Int: Bool] = [:]
            for level in listStyle.elements {
                let index = Int(level.attribute("text:level") ?? "1") ?? 1
                levels[index] = level.localName == "list-level-style-number"
                    && (level.attribute("style:num-format").map { !$0.isEmpty } ?? true)
            }
            listStyles[name] = levels
        }
    }

    private func paragraphInfo(_ name: String?, depth: Int = 0) -> ParagraphInfo {
        guard let name, var info = paragraphStyles[name] else { return ParagraphInfo() }
        if depth < 8, info.parent != nil {
            let parent = paragraphInfo(info.parent, depth: depth + 1)
            info.run.bold = info.run.bold || parent.run.bold
            info.run.italic = info.run.italic || parent.run.italic
            info.run.code = info.run.code || parent.run.code
            if info.alignment == .natural { info.alignment = parent.alignment }
        }
        return info
    }

    private func isNamed(_ styleName: String?, containing fragment: String, depth: Int = 0) -> Bool {
        guard let styleName, depth < 8 else { return false }
        if styleName.lowercased().contains(fragment) { return true }
        return isNamed(paragraphStyles[styleName]?.parent, containing: fragment, depth: depth + 1)
    }

    // MARK: - Blocks

    private func blocks(in container: XElement, listLevel: Int) -> [Block] {
        var blocks: [Block] = []
        for element in container.elements {
            switch element.localName {
            case "h":
                let level = Int(element.attribute("text:outline-level") ?? "1") ?? 1
                let (runs, images) = inline(element, base: RunStyle())
                let heading = runs.trimmed().map { run -> Run in
                    var copy = run
                    copy.style.bold = false
                    return copy
                }
                if !heading.isEmpty { blocks.append(.heading(level: min(max(level, 1), 6), runs: heading)) }
                blocks.append(contentsOf: images.map(Block.image))
            case "p":
                let styleName = element.attribute("text:style-name")
                let info = paragraphInfo(styleName)
                if info.breakBefore, !blocks.isEmpty { blocks.append(.pageBreak) }
                let (runs, images) = inline(element, base: info.run)
                let cleaned = runs.coalesced()
                if !cleaned.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    if isNamed(styleName, containing: "preformatted") || isNamed(styleName, containing: "source") {
                        blocks.append(.code(cleaned.plainText))
                    } else if isNamed(styleName, containing: "quotation") {
                        blocks.append(.quote([.paragraph(runs: cleaned)]))
                    } else if let level = info.headingLevel {
                        blocks.append(.heading(level: level, runs: cleaned.trimmed()))
                    } else if isNamed(styleName, containing: "title") {
                        blocks.append(.heading(level: 1, runs: cleaned.trimmed()))
                    } else {
                        blocks.append(.paragraph(runs: cleaned, alignment: info.alignment))
                    }
                }
                blocks.append(contentsOf: images.map(Block.image))
            case "list":
                blocks.append(list(element, level: listLevel + 1, inheritedStyle: element.attribute("text:style-name")))
            case "table":
                blocks.append(.table(table(element)))
            case "section", "index-body", "table-of-content", "alphabetical-index":
                blocks.append(contentsOf: self.blocks(in: element, listLevel: listLevel))
            default:
                continue
            }
        }
        // Merge consecutive code lines into one block.
        var merged: [Block] = []
        for block in blocks {
            if case .code(let next) = block, case .code(let previous)? = merged.last {
                merged[merged.count - 1] = .code(previous + "\n" + next)
            } else {
                merged.append(block)
            }
        }
        return merged
    }

    private func list(_ element: XElement, level: Int, inheritedStyle: String?) -> Block {
        let styleName = element.attribute("text:style-name") ?? inheritedStyle
        let ordered = styleName.flatMap { listStyles[$0]?[level] } ?? false
        var items: [[Block]] = []
        for item in element.children("list-item") + element.children("list-header") {
            var content: [Block] = []
            for child in item.elements {
                if child.localName == "list" {
                    content.append(list(child, level: level + 1, inheritedStyle: styleName))
                } else {
                    let wrapper = XElement(name: "wrapper")
                    wrapper.children = [.element(child)]
                    content.append(contentsOf: blocks(in: wrapper, listLevel: level))
                }
            }
            items.append(content)
        }
        return .list(ordered: ordered, items: items)
    }

    private func table(_ element: XElement) -> TableBlock {
        var rows: [[[Block]]] = []
        var headerRows = 0
        func appendRows(from container: XElement, header: Bool) {
            for child in container.elements {
                switch child.localName {
                case "table-row":
                    let repeatCount = min(Int(child.attribute("table:number-rows-repeated") ?? "1") ?? 1, 50)
                    var row: [[Block]] = []
                    for cell in child.elements where cell.localName == "table-cell" || cell.localName == "covered-table-cell" {
                        let repeats = min(Int(cell.attribute("table:number-columns-repeated") ?? "1") ?? 1, 50)
                        let content = blocks(in: cell, listLevel: 0)
                        for _ in 0 ..< repeats { row.append(content) }
                    }
                    // Trim trailing empty cells (spreadsheet-style padding).
                    while let last = row.last, last.isEmpty, row.count > 1 { row.removeLast() }
                    for _ in 0 ..< repeatCount {
                        rows.append(row)
                        if header { headerRows += 1 }
                    }
                case "table-header-rows":
                    appendRows(from: child, header: true)
                case "table-rows", "table-row-group":
                    appendRows(from: child, header: header)
                default:
                    continue
                }
            }
        }
        appendRows(from: element, header: false)
        return TableBlock(rows: rows, hasHeaderRow: headerRows > 0)
    }

    // MARK: - Inline

    private func inline(_ element: XElement, base: RunStyle) -> ([Run], [ImageBlock]) {
        var runs: [Run] = []
        var images: [ImageBlock] = []
        collect(element, style: base, runs: &runs, images: &images)
        return (runs, images)
    }

    private func collect(_ element: XElement, style: RunStyle, runs: inout [Run], images: inout [ImageBlock]) {
        for node in element.children {
            switch node {
            case .text(let string):
                // ODF treats runs of whitespace as a single space (explicit spaces use text:s).
                let collapsed = string.collapsingWhitespace
                if !collapsed.isEmpty { runs.append(Run(collapsed, style)) }
            case .element(let child):
                switch child.localName {
                case "span":
                    var next = style
                    if let name = child.attribute("text:style-name"), let spanStyle = textStyles[name] {
                        next.bold = next.bold || spanStyle.bold
                        next.italic = next.italic || spanStyle.italic
                        next.underline = next.underline || spanStyle.underline
                        next.strikethrough = next.strikethrough || spanStyle.strikethrough
                        next.superscript = next.superscript || spanStyle.superscript
                        next.subscript = next.subscript || spanStyle.subscript
                        next.code = next.code || spanStyle.code
                    }
                    collect(child, style: next, runs: &runs, images: &images)
                case "a":
                    var next = style
                    next.link = child.attribute("xlink:href")
                    collect(child, style: next, runs: &runs, images: &images)
                case "s":
                    let count = Int(child.attribute("text:c") ?? "1") ?? 1
                    runs.append(Run(String(repeating: " ", count: max(1, min(count, 200))), style))
                case "tab":
                    runs.append(Run("\t", style))
                case "line-break":
                    runs.append(Run("\n", style))
                case "frame":
                    if let image = image(in: child) { images.append(image) }
                case "note", "annotation", "bookmark", "bookmark-start", "bookmark-end", "soft-page-break", "sequence-decls":
                    continue
                default:
                    collect(child, style: style, runs: &runs, images: &images)
                }
            }
        }
    }

    private func image(in frame: XElement) -> ImageBlock? {
        guard let imageElement = frame.child("image"),
              let href = imageElement.attribute("xlink:href"),
              !href.hasPrefix("http"),
              let data = package.dataIfPresent(at: href)
        else { return nil }
        let mime = ImageBlock.sniffMimeType(data) ?? ImageBlock.mimeType(forExtension: (href as NSString).pathExtension)
        guard mime.hasPrefix("image/"), !mime.contains("x-emf"), !mime.contains("x-wmf") else { return nil }
        var size: CGSize?
        if let width = frame.attribute("svg:width").flatMap(Self.points), let height = frame.attribute("svg:height").flatMap(Self.points) {
            size = CGSize(width: width, height: height)
        }
        let alt = (frame.child("desc") ?? frame.child("title"))?.text.nilIfBlank
        return ImageBlock(data: data, mimeType: mime, size: size, altText: alt)
    }

    /// Converts ODF lengths ("2.5in", "3cm", "120pt", "40mm") to points.
    static func points(_ length: String) -> CGFloat? {
        let units: [(String, Double)] = [("pt", 1), ("in", 72), ("cm", 28.3465), ("mm", 2.83465), ("px", 0.75), ("pc", 12)]
        for (suffix, factor) in units where length.hasSuffix(suffix) {
            guard let value = Double(length.dropLast(suffix.count)) else { return nil }
            return CGFloat(value * factor)
        }
        return Double(length).map { CGFloat($0) }
    }
}
