import Foundation

enum PlainTextWriter {
    static func render(_ document: RichDocument) -> String {
        var output: [String] = []
        for block in document.blocks {
            let text = render(block, indent: "")
            if !text.isEmpty { output.append(text) }
        }
        return output.joined(separator: "\n\n") + (output.isEmpty ? "" : "\n")
    }

    static func data(_ document: RichDocument) -> Data {
        Data(render(document).utf8)
    }

    private static func render(_ block: Block, indent: String) -> String {
        switch block {
        case .heading(_, let runs):
            return indent + runs.plainText
        case .paragraph(let runs, _):
            return runs.plainText
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { indent + $0 }
                .joined(separator: "\n")
        case .list(let ordered, let items):
            return items.enumerated().map { index, blocks in
                let marker = ordered ? "\(index + 1). " : "• "
                let body = blocks.map { render($0, indent: "") }.filter { !$0.isEmpty }
                guard let first = body.first else { return indent + marker }
                let continuation = String(repeating: " ", count: marker.count)
                let rest = body.dropFirst().map { item in
                    item.split(separator: "\n", omittingEmptySubsequences: false)
                        .map { indent + continuation + $0 }
                        .joined(separator: "\n")
                }
                return ([indent + marker + first] + rest).joined(separator: "\n")
            }.joined(separator: "\n")
        case .table(let table):
            return table.rows.map { row in
                indent + row.map { cell in
                    cell.map(\.plainText).joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
                }.joined(separator: "\t")
            }.joined(separator: "\n")
        case .image(let image):
            return image.altText.map { indent + "[\($0)]" } ?? ""
        case .quote(let blocks):
            return blocks.map { render($0, indent: indent + "    ") }.joined(separator: "\n\n")
        case .code(let code):
            return code.split(separator: "\n", omittingEmptySubsequences: false)
                .map { indent + "    " + $0 }
                .joined(separator: "\n")
        case .rule:
            return indent + "* * *"
        case .pageBreak:
            return ""
        }
    }
}
