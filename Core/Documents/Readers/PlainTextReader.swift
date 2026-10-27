import Foundation

enum PlainTextReader {
    static func read(url: URL) throws -> RichDocument {
        read(text: TextDecoding.decode(try Data(contentsOf: url)))
    }

    /// Blank lines separate paragraphs; single newlines are kept as line breaks.
    static func read(text: String) -> RichDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var blocks: [Block] = []
        var current: [String] = []
        func flush() {
            let joined = current.joined(separator: "\n").trimmingCharacters(in: .newlines)
            if !joined.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.paragraph(runs: [Run(joined)]))
            }
            current = []
        }
        for line in normalized.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else if line.contains("\u{0C}") {
                // Form feed = page break in plain text exports.
                let parts = line.components(separatedBy: "\u{0C}")
                for (index, part) in parts.enumerated() {
                    if !part.isEmpty { current.append(part) }
                    if index < parts.count - 1 {
                        flush()
                        blocks.append(.pageBreak)
                    }
                }
            } else {
                current.append(line)
            }
        }
        flush()
        return RichDocument(blocks: blocks)
    }
}
