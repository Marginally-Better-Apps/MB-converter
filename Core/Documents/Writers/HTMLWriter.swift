import Foundation

/// Emits XHTML-compatible markup so the same output works for browsers, EPUB chapters and PDF printing.
enum HTMLWriter {
    enum Mode {
        /// Self-contained page with images inlined as data URIs.
        case standalone
        /// Body styled for the print renderer, which applies page size and margins itself.
        case print
        /// EPUB chapter: XHTML with images referenced by the provided resolver.
        case epubChapter
    }

    static func render(
        _ document: RichDocument,
        options: DocumentExportOptions = .default,
        mode: Mode = .standalone,
        imageSource: ((ImageBlock) -> String)? = nil
    ) -> String {
        render(blocks: document.blocks, title: options.title ?? document.resolvedTitle, metadata: document.metadata, options: options, mode: mode, imageSource: imageSource)
    }

    static func render(
        blocks: [Block],
        title: String?,
        metadata: DocumentMetadata = DocumentMetadata(),
        options: DocumentExportOptions = .default,
        mode: Mode = .standalone,
        imageSource: ((ImageBlock) -> String)? = nil
    ) -> String {
        let resolver = imageSource ?? { "data:\($0.mimeType);base64,\($0.data.base64EncodedString())" }
        var context = Context(options: options, imageSource: resolver)
        let body = blocks.map { context.block($0) }.joined(separator: "\n")
        let escapedTitle = XMLEscaping.escape(title ?? "Document")
        var head = """
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title>\(escapedTitle)</title>
        """
        if let author = options.author ?? metadata.author {
            head += "\n<meta name=\"author\" content=\"\(XMLEscaping.escape(author))\"/>"
        }
        let lang = XMLEscaping.escape(metadata.language ?? "en")
        let namespace = mode == .epubChapter ? " xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\"" : ""
        let doctype = mode == .epubChapter ? "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!DOCTYPE html>" : "<!DOCTYPE html>"
        let style = mode == .epubChapter
            ? "<link rel=\"stylesheet\" type=\"text/css\" href=\"style.css\"/>"
            : "<style>\n\(stylesheet(options: options, mode: mode))\n</style>"
        return """
        \(doctype)
        <html\(namespace) lang="\(lang)" xml:lang="\(lang)">
        <head>
        \(head)
        \(style)
        </head>
        <body>
        \(body)
        </body>
        </html>
        """
    }

    static func data(_ document: RichDocument, options: DocumentExportOptions = .default) -> Data {
        Data(render(document, options: options).utf8)
    }

    static func stylesheet(options: DocumentExportOptions, mode: Mode) -> String {
        let size = options.fontSize
        let bodyMargin: String = switch mode {
        case .standalone: "max-width: 46em; margin: 2.5em auto; padding: 0 1.25em;"
        case .print, .epubChapter: "margin: 0; padding: 0;"
        }
        return """
        body { font-family: \(options.fontFamily.cssStack); font-size: \(fmt(size))pt; line-height: \(fmt(options.lineSpacing)); color: #111; \(bodyMargin) -webkit-text-size-adjust: 100%; }
        h1, h2, h3, h4, h5, h6 { line-height: 1.2; margin: 1.1em 0 0.45em; font-weight: 600; page-break-after: avoid; }
        h1 { font-size: \(fmt(size * 2))pt; } h2 { font-size: \(fmt(size * 1.6))pt; } h3 { font-size: \(fmt(size * 1.3))pt; }
        h4 { font-size: \(fmt(size * 1.12))pt; } h5, h6 { font-size: \(fmt(size))pt; }
        p { margin: 0 0 0.75em; orphans: 3; widows: 3; }
        ul, ol { margin: 0 0 0.75em; padding-left: 1.6em; }
        li > p { margin: 0 0 0.25em; }
        table { border-collapse: collapse; margin: 0.5em 0 1em; width: auto; max-width: 100%; page-break-inside: auto; }
        th, td { border: 0.75pt solid #b8c2cc; padding: 0.3em 0.55em; vertical-align: top; text-align: left; }
        th { background: #eef2f6; font-weight: 600; }
        tr { page-break-inside: avoid; }
        td p, th p { margin: 0; }
        img { max-width: 100%; height: auto; }
        blockquote { margin: 0 0 0.75em; padding: 0.1em 0 0.1em 1em; border-left: 3pt solid #c9d3dd; color: #333; }
        pre { font-family: Menlo, 'SF Mono', Courier, monospace; font-size: \(fmt(size * 0.88))pt; background: #f4f6f8; padding: 0.7em 0.9em; border-radius: 4pt; white-space: pre-wrap; word-wrap: break-word; }
        code { font-family: Menlo, 'SF Mono', Courier, monospace; font-size: 0.9em; }
        hr { border: none; border-top: 0.75pt solid #c9d3dd; margin: 1.2em 0; }
        a { color: #0b5fa5; }
        .page-break { page-break-after: always; break-after: page; height: 0; }
        .center { text-align: center; } .right { text-align: right; } .justify { text-align: justify; }
        """
    }

    private static func fmt(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.2f", value)
    }

    private struct Context {
        let options: DocumentExportOptions
        let imageSource: (ImageBlock) -> String

        mutating func block(_ block: Block) -> String {
            switch block {
            case .heading(let level, let runs):
                let tag = "h\(min(max(level, 1), 6))"
                return "<\(tag)>\(inline(runs))</\(tag)>"
            case .paragraph(let runs, let alignment):
                let cls: String = switch alignment {
                case .center: " class=\"center\""
                case .right: " class=\"right\""
                case .justified: " class=\"justify\""
                default: ""
                }
                let content = inline(runs)
                return "<p\(cls)>\(content.isEmpty ? "&#160;" : content)</p>"
            case .list(let ordered, let items):
                let tag = ordered ? "ol" : "ul"
                let body = items.map { item -> String in
                    // Tight list items render their single paragraph inline.
                    if item.count == 1, case .paragraph(let runs, _) = item[0] {
                        return "<li>\(inline(runs))</li>"
                    }
                    return "<li>" + item.map { self.block($0) }.joined() + "</li>"
                }.joined(separator: "\n")
                return "<\(tag)>\n\(body)\n</\(tag)>"
            case .table(let table):
                var rows: [String] = []
                for (index, row) in table.rows.enumerated() {
                    let isHeader = table.hasHeaderRow && index == 0
                    let cellTag = isHeader ? "th" : "td"
                    var cells = row.map { cell -> String in
                        "<\(cellTag)>" + cellContent(cell) + "</\(cellTag)>"
                    }
                    while cells.count < table.columnCount { cells.append("<\(cellTag)></\(cellTag)>") }
                    rows.append("<tr>" + cells.joined() + "</tr>")
                }
                if table.hasHeaderRow, !rows.isEmpty {
                    let head = rows.removeFirst()
                    return "<table>\n<thead>\(head)</thead>\n<tbody>\n\(rows.joined(separator: "\n"))\n</tbody>\n</table>"
                }
                return "<table>\n<tbody>\n\(rows.joined(separator: "\n"))\n</tbody>\n</table>"
            case .image(let image):
                guard options.includeImages else { return "" }
                var attributes = "src=\"\(XMLEscaping.escape(imageSource(image)))\" alt=\"\(XMLEscaping.escape(image.altText ?? ""))\""
                if let size = image.size, size.width > 0 {
                    attributes += " style=\"width: \(Int(size.width))pt;\""
                }
                return "<p class=\"center\"><img \(attributes)/></p>"
            case .quote(let blocks):
                return "<blockquote>" + blocks.map { self.block($0) }.joined(separator: "\n") + "</blockquote>"
            case .code(let code):
                return "<pre><code>\(XMLEscaping.escape(code))</code></pre>"
            case .rule:
                return "<hr/>"
            case .pageBreak:
                return "<div class=\"page-break\"></div>"
            }
        }

        private mutating func cellContent(_ blocks: [Block]) -> String {
            if blocks.count == 1, case .paragraph(let runs, _) = blocks[0] {
                return inline(runs)
            }
            return blocks.map { block($0) }.joined()
        }

        func inline(_ runs: [Run]) -> String {
            runs.coalesced().map { run -> String in
                var text = XMLEscaping.escape(run.text).replacingOccurrences(of: "\n", with: "<br/>")
                let style = run.style
                if style.code { text = "<code>\(text)</code>" }
                if style.superscript { text = "<sup>\(text)</sup>" }
                if style.subscript { text = "<sub>\(text)</sub>" }
                if style.strikethrough { text = "<s>\(text)</s>" }
                if style.underline { text = "<u>\(text)</u>" }
                if style.italic { text = "<em>\(text)</em>" }
                if style.bold { text = "<strong>\(text)</strong>" }
                if let link = style.link { text = "<a href=\"\(XMLEscaping.escape(link))\">\(text)</a>" }
                return text
            }.joined()
        }
    }
}
