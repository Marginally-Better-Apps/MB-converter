import Foundation

enum MarkdownWriter {
    /// Where an image is written in the Markdown. Defaults to an inline data URI.
    typealias ImageSource = @Sendable (ImageBlock) -> String
    static let dataURI: ImageSource = { "data:\($0.mimeType);base64,\($0.data.base64EncodedString())" }

    static func render(_ document: RichDocument, imageSource: @escaping ImageSource = dataURI) -> String {
        var parts: [String] = []
        for block in document.blocks {
            let text = render(block, imageSource: imageSource)
            if !text.isEmpty { parts.append(text) }
        }
        return parts.joined(separator: "\n\n") + (parts.isEmpty ? "" : "\n")
    }

    static func data(_ document: RichDocument, imageSource: @escaping ImageSource = dataURI) -> Data {
        Data(render(document, imageSource: imageSource).utf8)
    }

    static func render(_ block: Block, imageSource: @escaping ImageSource = dataURI) -> String {
        let child: (Block) -> String = { MarkdownWriter.render($0, imageSource: imageSource) }
        switch block {
        case .heading(let level, let runs):
            return String(repeating: "#", count: min(max(level, 1), 6)) + " " + inline(runs)
        case .paragraph(let runs, _):
            return inline(runs)
        case .list(let ordered, let items):
            return items.enumerated().map { index, blocks in
                let marker = ordered ? "\(index + 1). " : "- "
                let pad = String(repeating: " ", count: marker.count)
                let rendered = blocks.map { ($0, child($0)) }.filter { !$0.1.isEmpty }
                guard let first = rendered.first else { return marker }
                var lines = [marker + indented(first.1, by: pad, skipFirst: true)]
                for (block, text) in rendered.dropFirst() {
                    // Nested lists stay tight; other blocks need a blank line to belong to the item.
                    if case .list = block {} else { lines.append("") }
                    lines.append(indented(text, by: pad, skipFirst: false))
                }
                return lines.joined(separator: "\n")
            }.joined(separator: "\n")
        case .table(let table):
            return renderTable(table)
        case .image(let image):
            return picture(image, imageSource)
        case .imageRow(let images):
            return images.map { picture($0, imageSource) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .quote(let blocks):
            return blocks.map(child).filter { !$0.isEmpty }.joined(separator: "\n\n")
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }
                .joined(separator: "\n")
        case .code(let code):
            let fence = code.contains("```") ? "~~~" : "```"
            return fence + "\n" + code + "\n" + fence
        case .rule:
            return "---"
        case .pageBreak:
            return ""
        }
    }

    static func inline(_ runs: [Run]) -> String {
        var output = ""
        for run in runs.coalesced() {
            let lines = run.text.components(separatedBy: "\n")
            let rendered = lines.map { line -> String in
                guard !line.isEmpty else { return line }
                if run.style.code {
                    let tick = line.contains("`") ? "``" : "`"
                    return tick + line + tick
                }
                // Keep surrounding spaces outside emphasis markers so they parse.
                let leading = String(line.prefix { $0 == " " })
                let trailing = String(line.reversed().prefix { $0 == " " })
                let core = line.trimmingCharacters(in: .whitespaces)
                guard !core.isEmpty else { return line }
                var text = escape(core)
                if run.style.strikethrough { text = "~~\(text)~~" }
                if run.style.italic { text = "*\(text)*" }
                if run.style.bold { text = "**\(text)**" }
                if run.style.underline, !run.style.bold, !run.style.italic, run.style.link == nil {
                    text = "<u>\(text)</u>"
                }
                if let link = run.style.link { text = "[\(text)](\(link.replacingOccurrences(of: " ", with: "%20")))" }
                return leading + text + String(trailing)
            }
            output += rendered.joined(separator: "  \n")
        }
        return output
    }

    /// An empty source means "leave this picture out".
    private static func picture(_ image: ImageBlock, _ imageSource: ImageSource) -> String {
        let source = imageSource(image)
        return source.isEmpty ? "" : "![\(escape(image.altText ?? "image"))](\(source))"
    }

    private static func renderTable(_ table: TableBlock) -> String {
        let columns = max(table.columnCount, 1)
        var rows = table.rows.map { row -> [String] in
            var cells = row.map { cell in
                cell.map { block -> String in
                    if case .paragraph(let runs, _) = block { return inline(runs) }
                    return block.plainText
                }.joined(separator: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "|", with: "\\|")
            }
            while cells.count < columns { cells.append("") }
            return cells
        }
        if rows.isEmpty { return "" }
        let header = table.hasHeaderRow ? rows.removeFirst() : Array(repeating: "", count: columns)
        var lines = ["| " + header.joined(separator: " | ") + " |"]
        lines.append("|" + Array(repeating: " --- ", count: columns).joined(separator: "|") + "|")
        for row in rows {
            lines.append("| " + row.joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        var result = ""
        for ch in text {
            if "\\`*_[]#".contains(ch) { result.append("\\") }
            result.append(ch)
        }
        // A leading "1." or "-" would turn a paragraph into a list.
        if let first = result.first, first == "-" || first == "+" || first == ">" {
            result = "\\" + result
        }
        return result
    }

    private static func indented(_ text: String, by pad: String, skipFirst: Bool) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            (skipFirst && index == 0) || line.isEmpty ? String(line) : pad + line
        }.joined(separator: "\n")
    }
}
