import Foundation

/// Practical CommonMark subset plus GitHub tables and strikethrough.
enum MarkdownReader {
    typealias ImageResolver = (String) -> Data?

    static func read(url: URL) throws -> RichDocument {
        let baseDirectory = url.deletingLastPathComponent()
        return read(markdown: TextDecoding.decode(try Data(contentsOf: url)), imageResolver: { src in
            guard !src.contains("://") else { return nil }
            return try? Data(contentsOf: baseDirectory.appendingPathComponent(src.removingPercentEncoding ?? src))
        })
    }

    static func read(markdown: String, imageResolver: ImageResolver? = nil) -> RichDocument {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var metadata = DocumentMetadata()
        // YAML front matter (title/author) is common in notes apps and static site generators.
        if text.hasPrefix("---\n"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 4) ..< text.endIndex) {
            let front = text[text.index(text.startIndex, offsetBy: 4) ..< end.lowerBound]
            for line in front.split(separator: "\n") {
                let pair = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2 else { continue }
                let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                switch pair[0].lowercased() {
                case "title": metadata.title = value.nilIfBlank
                case "author": metadata.author = value.nilIfBlank
                case "description", "subject": metadata.subject = value.nilIfBlank
                default: break
                }
            }
            text = String(text[end.upperBound...])
        }
        let lines = text.components(separatedBy: "\n").map { $0.replacingOccurrences(of: "\t", with: "    ") }
        let parser = BlockParser(inline: InlineParser(imageResolver: imageResolver))
        return RichDocument(metadata: metadata, blocks: parser.parse(lines[...]))
    }

    // MARK: - Blocks

    private struct BlockParser {
        let inline: InlineParser

        func parse(_ lines: ArraySlice<String>) -> [Block] {
            var blocks: [Block] = []
            var paragraph: [String] = []
            var index = lines.startIndex

            func flushParagraph() {
                guard !paragraph.isEmpty else { return }
                let joined = paragraph.joined(separator: "\n")
                paragraph = []
                let (runs, images) = inline.parse(joined)
                let trimmed = runs.trimmed()
                if !trimmed.isEmpty { blocks.append(.paragraph(runs: trimmed)) }
                blocks.append(contentsOf: images.map(Block.image))
            }

            while index < lines.endIndex {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let indent = line.prefix { $0 == " " }.count

                if trimmed.isEmpty {
                    flushParagraph()
                    index += 1
                    continue
                }

                // Setext headings underline the paragraph line(s) above.
                if !paragraph.isEmpty, indent < 4, isSetextUnderline(trimmed) {
                    let level = trimmed.hasPrefix("=") ? 1 : 2
                    let (runs, _) = inline.parse(paragraph.joined(separator: " "))
                    paragraph = []
                    blocks.append(.heading(level: level, runs: runs.trimmed()))
                    index += 1
                    continue
                }

                if indent < 4, let heading = atxHeading(trimmed) {
                    flushParagraph()
                    blocks.append(heading)
                    index += 1
                    continue
                }

                if indent < 4, isThematicBreak(trimmed) {
                    flushParagraph()
                    blocks.append(.rule)
                    index += 1
                    continue
                }

                if indent < 4, let fence = fenceMarker(trimmed) {
                    flushParagraph()
                    var code: [String] = []
                    index += 1
                    while index < lines.endIndex {
                        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                        if candidate.hasPrefix(fence), candidate.allSatisfy({ $0 == fence.first }) { index += 1; break }
                        code.append(String(lines[index].dropFirst(min(indent, lines[index].prefix { $0 == " " }.count))))
                        index += 1
                    }
                    blocks.append(.code(code.joined(separator: "\n")))
                    continue
                }

                if indent >= 4, paragraph.isEmpty {
                    var code: [String] = []
                    while index < lines.endIndex {
                        let candidate = lines[index]
                        let candidateIndent = candidate.prefix { $0 == " " }.count
                        if candidate.trimmingCharacters(in: .whitespaces).isEmpty {
                            code.append("")
                        } else if candidateIndent >= 4 {
                            code.append(String(candidate.dropFirst(4)))
                        } else {
                            break
                        }
                        index += 1
                    }
                    while code.last == "" { code.removeLast() }
                    blocks.append(.code(code.joined(separator: "\n")))
                    continue
                }

                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    var quoted: [String] = []
                    while index < lines.endIndex {
                        let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                        guard candidate.hasPrefix(">") else {
                            // Lazy continuation of a quoted paragraph.
                            if !candidate.isEmpty, !quoted.isEmpty, quoted.last?.isEmpty == false, listMarker(lines[index]) == nil {
                                quoted.append(candidate)
                                index += 1
                                continue
                            }
                            break
                        }
                        var content = candidate.dropFirst()
                        if content.hasPrefix(" ") { content = content.dropFirst() }
                        quoted.append(String(content))
                        index += 1
                    }
                    blocks.append(.quote(parse(quoted[...])))
                    continue
                }

                if indent < 4, let table = tableBlock(lines, at: index) {
                    flushParagraph()
                    blocks.append(.table(table.block))
                    index = table.next
                    continue
                }

                if let marker = listMarker(line), paragraph.isEmpty || marker.ordered == false || marker.number == 1 {
                    flushParagraph()
                    let result = list(lines, at: index, first: marker)
                    blocks.append(result.block)
                    index = result.next
                    continue
                }

                paragraph.append(trimmed + trailingBreakMarker(line))
                index += 1
            }
            flushParagraph()
            return blocks
        }

        /// Preserves the "two trailing spaces" hard line break that trimming would otherwise remove.
        private func trailingBreakMarker(_ line: String) -> String {
            line.hasSuffix("  ") ? "\u{2028}" : ""
        }

        private func isSetextUnderline(_ trimmed: String) -> Bool {
            guard let first = trimmed.first, first == "=" || first == "-" else { return false }
            return trimmed.allSatisfy { $0 == first }
        }

        private func atxHeading(_ trimmed: String) -> Block? {
            let hashes = trimmed.prefix { $0 == "#" }.count
            guard (1 ... 6).contains(hashes) else { return nil }
            let rest = trimmed.dropFirst(hashes)
            guard rest.isEmpty || rest.first == " " else { return nil }
            var content = rest.trimmingCharacters(in: .whitespaces)
            // Optional closing hashes.
            while content.hasSuffix("#") { content.removeLast() }
            let (runs, _) = inline.parse(content.trimmingCharacters(in: .whitespaces))
            return .heading(level: hashes, runs: runs.trimmed())
        }

        private func isThematicBreak(_ trimmed: String) -> Bool {
            let compact = trimmed.replacingOccurrences(of: " ", with: "")
            guard compact.count >= 3, let first = compact.first, "-*_".contains(first) else { return false }
            return compact.allSatisfy { $0 == first }
        }

        private func fenceMarker(_ trimmed: String) -> String? {
            for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
                let count = trimmed.prefix { $0 == fence.first }.count
                return String(repeating: String(fence.first!), count: count)
            }
            return nil
        }

        struct ListMarker {
            let ordered: Bool
            let number: Int
            let indent: Int
            /// Column where item content starts.
            let contentOffset: Int
            let content: String
        }

        func listMarker(_ line: String) -> ListMarker? {
            let indent = line.prefix { $0 == " " }.count
            guard indent < 4 + 8 else { return nil }
            let rest = line.dropFirst(indent)
            if let first = rest.first, "-*+".contains(first) {
                let after = rest.dropFirst()
                guard after.isEmpty || after.first == " " else { return nil }
                if isThematicBreak(String(rest)) { return nil }
                let spaces = min(max(after.prefix { $0 == " " }.count, 1), 4)
                return ListMarker(ordered: false, number: 0, indent: indent, contentOffset: indent + 1 + spaces, content: after.trimmingCharacters(in: .whitespaces))
            }
            let digits = rest.prefix { $0.isNumber }
            guard (1 ... 9).contains(digits.count) else { return nil }
            let afterDigits = rest.dropFirst(digits.count)
            guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
            let after = afterDigits.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            let spaces = min(max(after.prefix { $0 == " " }.count, 1), 4)
            return ListMarker(
                ordered: true,
                number: Int(digits) ?? 1,
                indent: indent,
                contentOffset: indent + digits.count + 1 + spaces,
                content: after.trimmingCharacters(in: .whitespaces)
            )
        }

        private func list(_ lines: ArraySlice<String>, at start: Int, first: ListMarker) -> (block: Block, next: Int) {
            var items: [[Block]] = []
            var index = start
            var current: [String]? = nil
            var contentOffset = first.contentOffset
            var sawBlank = false

            func finishItem() {
                if let lines = current { items.append(parse(lines[...])) }
                current = nil
            }

            while index < lines.endIndex {
                let line = lines[index]
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    sawBlank = true
                    current?.append("")
                    index += 1
                    continue
                }
                let indent = line.prefix { $0 == " " }.count
                if let marker = listMarker(line), marker.indent < contentOffset, marker.indent <= first.indent + 3 {
                    guard marker.ordered == first.ordered else { break }
                    finishItem()
                    current = [marker.content]
                    contentOffset = marker.contentOffset
                    sawBlank = false
                    index += 1
                    continue
                }
                if indent >= contentOffset {
                    current?.append(String(line.dropFirst(contentOffset)))
                    sawBlank = false
                    index += 1
                    continue
                }
                // Lazy continuation line belongs to the open paragraph.
                if !sawBlank, current != nil, atxHeading(trimmed) == nil, !isThematicBreak(trimmed), !trimmed.hasPrefix(">") {
                    current?.append(trimmed)
                    index += 1
                    continue
                }
                break
            }
            finishItem()
            return (.list(ordered: first.ordered, items: items), index)
        }

        private func tableBlock(_ lines: ArraySlice<String>, at index: Int) -> (block: TableBlock, next: Int)? {
            guard index + 1 < lines.endIndex, lines[index].contains("|") else { return nil }
            let delimiter = lines[index + 1].trimmingCharacters(in: .whitespaces)
            let delimiterCells = splitRow(delimiter)
            guard !delimiterCells.isEmpty,
                  delimiterCells.allSatisfy({ cell in
                      let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ": "))
                      return core.count >= 1 && core.allSatisfy { $0 == "-" }
                  })
            else { return nil }
            var rows: [[[Block]]] = [splitRow(lines[index]).map(cellBlocks)]
            var next = index + 2
            while next < lines.endIndex {
                let line = lines[next]
                guard line.contains("|"), !line.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                rows.append(splitRow(line).map(cellBlocks))
                next += 1
            }
            return (TableBlock(rows: rows, hasHeaderRow: true), next)
        }

        private func cellBlocks(_ text: String) -> [Block] {
            let (runs, images) = inline.parse(text)
            var blocks: [Block] = []
            let trimmed = runs.trimmed()
            if !trimmed.isEmpty { blocks.append(.paragraph(runs: trimmed)) }
            blocks.append(contentsOf: images.map(Block.image))
            return blocks
        }

        private func splitRow(_ line: String) -> [String] {
            var trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("|") { trimmed.removeFirst() }
            if trimmed.hasSuffix("|"), !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
            var cells: [String] = []
            var current = ""
            var escaped = false
            for ch in trimmed {
                if escaped {
                    if ch != "|" { current.append("\\") }
                    current.append(ch)
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "|" {
                    cells.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                } else {
                    current.append(ch)
                }
            }
            cells.append(current.trimmingCharacters(in: .whitespaces))
            return cells
        }
    }

    // MARK: - Inline

    struct InlineParser {
        let imageResolver: ImageResolver?

        /// Returns inline runs plus images that should become standalone blocks.
        func parse(_ text: String) -> ([Run], [ImageBlock]) {
            var images: [ImageBlock] = []
            let runs = parse(Array(text), style: RunStyle(), images: &images)
            return (runs.coalesced(), images)
        }

        private func parse(_ chars: [Character], style: RunStyle, images: inout [ImageBlock]) -> [Run] {
            var runs: [Run] = []
            var buffer = ""
            var i = 0

            func flush() {
                if !buffer.isEmpty { runs.append(Run(buffer, style)) }
                buffer = ""
            }

            while i < chars.count {
                let ch = chars[i]
                switch ch {
                case "\\":
                    if i + 1 < chars.count, chars[i + 1] == "\n" {
                        buffer.append("\n")
                        i += 2
                    } else if i + 1 < chars.count, chars[i + 1].isPunctuation || chars[i + 1].isSymbol {
                        buffer.append(chars[i + 1])
                        i += 2
                    } else {
                        buffer.append(ch)
                        i += 1
                    }
                case "\u{2028}":
                    // Hard break marker from the block parser; the following "\n" becomes the break.
                    i += 1
                    if i < chars.count, chars[i] == "\n" { buffer.append("\n"); i += 1 }
                case "\n":
                    buffer.append(" ")
                    i += 1
                case "`":
                    let ticks = countRun(chars, from: i, of: "`")
                    if let close = findRun(chars, from: i + ticks, of: "`", count: ticks) {
                        flush()
                        var code = String(chars[(i + ticks) ..< close]).replacingOccurrences(of: "\n", with: " ")
                        if code.hasPrefix(" "), code.hasSuffix(" "), code.count > 2 { code = String(code.dropFirst().dropLast()) }
                        var codeStyle = style
                        codeStyle.code = true
                        runs.append(Run(code, codeStyle))
                        i = close + ticks
                    } else {
                        buffer.append(String(repeating: "`", count: ticks))
                        i += ticks
                    }
                case "*", "_", "~":
                    let count = countRun(chars, from: i, of: ch)
                    let useCount = ch == "~" ? (count >= 2 ? 2 : 0) : min(count, 3)
                    let prev: Character? = i > 0 ? chars[i - 1] : nil
                    let next: Character? = i + count < chars.count ? chars[i + count] : nil
                    let canOpen = useCount > 0 && next != nil && !(next!.isWhitespace)
                        && !(ch == "_" && prev != nil && (prev!.isLetter || prev!.isNumber))
                    if canOpen, let close = findClosing(chars, from: i + useCount, marker: ch, count: useCount) {
                        flush()
                        var inner = style
                        switch (ch, useCount) {
                        case ("~", _): inner.strikethrough = true
                        case (_, 1): inner.italic = true
                        case (_, 2): inner.bold = true
                        default: inner.bold = true; inner.italic = true
                        }
                        runs.append(contentsOf: parse(Array(chars[(i + useCount) ..< close]), style: inner, images: &images))
                        i = close + useCount
                    } else {
                        buffer.append(String(repeating: String(ch), count: count))
                        i += count
                    }
                case "!" where i + 1 < chars.count && chars[i + 1] == "[":
                    if let link = parseLink(chars, from: i + 1) {
                        flush()
                        if let image = loadImage(src: link.destination, alt: String(chars[link.textRange])) {
                            images.append(image)
                        } else {
                            buffer.append(String(chars[link.textRange]))
                        }
                        i = link.end
                    } else {
                        buffer.append(ch)
                        i += 1
                    }
                case "[":
                    if let link = parseLink(chars, from: i) {
                        flush()
                        var linkStyle = style
                        linkStyle.link = link.destination
                        runs.append(contentsOf: parse(Array(chars[link.textRange]), style: linkStyle, images: &images))
                        i = link.end
                    } else {
                        buffer.append(ch)
                        i += 1
                    }
                case "<":
                    if let close = chars[i...].firstIndex(of: ">") {
                        let inside = String(chars[(i + 1) ..< close])
                        let lower = inside.lowercased()
                        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:") {
                            flush()
                            var linkStyle = style
                            linkStyle.link = inside
                            runs.append(Run(inside, linkStyle))
                            i = close + 1
                            continue
                        }
                        if lower == "br" || lower == "br/" || lower == "br /" {
                            buffer.append("\n")
                            i = close + 1
                            continue
                        }
                        if lower == "u", let end = findString(chars, "</u>", from: close + 1) {
                            flush()
                            var underline = style
                            underline.underline = true
                            runs.append(contentsOf: parse(Array(chars[(close + 1) ..< end]), style: underline, images: &images))
                            i = end + 4
                            continue
                        }
                    }
                    buffer.append(ch)
                    i += 1
                default:
                    buffer.append(ch)
                    i += 1
                }
            }
            flush()
            return runs
        }

        private func countRun(_ chars: [Character], from start: Int, of ch: Character) -> Int {
            var count = 0
            while start + count < chars.count, chars[start + count] == ch { count += 1 }
            return count
        }

        private func findRun(_ chars: [Character], from start: Int, of ch: Character, count: Int) -> Int? {
            var i = start
            while i < chars.count {
                if chars[i] == ch {
                    let run = countRun(chars, from: i, of: ch)
                    if run == count { return i }
                    i += run
                } else {
                    i += 1
                }
            }
            return nil
        }

        private func findClosing(_ chars: [Character], from start: Int, marker: Character, count: Int) -> Int? {
            var i = start
            while i < chars.count {
                let ch = chars[i]
                if ch == "\\" { i += 2; continue }
                if ch == "`" {
                    let ticks = countRun(chars, from: i, of: "`")
                    if let close = findRun(chars, from: i + ticks, of: "`", count: ticks) { i = close + ticks; continue }
                }
                if ch == marker {
                    let run = countRun(chars, from: i, of: marker)
                    let prev = chars[i - 1]
                    let next: Character? = i + run < chars.count ? chars[i + run] : nil
                    let canClose = !prev.isWhitespace && !(marker == "_" && next != nil && (next!.isLetter || next!.isNumber))
                    if canClose, run >= count, i > start {
                        // Prefer exact matches; for *** inside ** handle the outer marker.
                        return run == count ? i : i + (run - count)
                    }
                    i += run
                    continue
                }
                i += 1
            }
            return nil
        }

        private func findString(_ chars: [Character], _ needle: String, from start: Int) -> Int? {
            let target = Array(needle)
            guard target.count <= chars.count else { return nil }
            var i = start
            while i + target.count <= chars.count {
                if Array(chars[i ..< i + target.count]).map({ $0.lowercased() }) == target.map({ $0.lowercased() }) { return i }
                i += 1
            }
            return nil
        }

        private struct ParsedLink {
            let textRange: Range<Int>
            let destination: String
            let end: Int
        }

        private func parseLink(_ chars: [Character], from open: Int) -> ParsedLink? {
            var depth = 0
            var i = open
            var closeBracket: Int?
            while i < chars.count {
                if chars[i] == "\\" { i += 2; continue }
                if chars[i] == "[" { depth += 1 }
                if chars[i] == "]" {
                    depth -= 1
                    if depth == 0 { closeBracket = i; break }
                }
                i += 1
            }
            guard let close = closeBracket, close + 1 < chars.count, chars[close + 1] == "(" else { return nil }
            var j = close + 2
            var parens = 1
            var destination = ""
            while j < chars.count {
                if chars[j] == "(" { parens += 1 }
                if chars[j] == ")" {
                    parens -= 1
                    if parens == 0 { break }
                }
                destination.append(chars[j])
                j += 1
            }
            guard j < chars.count else { return nil }
            var target = destination.trimmingCharacters(in: .whitespaces)
            if target.hasPrefix("<"), let end = target.firstIndex(of: ">") {
                target = String(target[target.index(after: target.startIndex) ..< end])
            } else if let space = target.firstIndex(of: " ") {
                target = String(target[..<space]) // drop optional "title"
            }
            return ParsedLink(textRange: (open + 1) ..< close, destination: target, end: j + 1)
        }

        private func loadImage(src: String, alt: String) -> ImageBlock? {
            var data: Data?
            var mime: String?
            if src.hasPrefix("data:") {
                let parts = src.dropFirst(5).split(separator: ",", maxSplits: 1)
                if parts.count == 2 {
                    mime = parts[0].split(separator: ";").first.map(String.init)
                    data = Data(base64Encoded: String(parts[1]), options: .ignoreUnknownCharacters)
                }
            } else {
                data = imageResolver?(src)
                mime = ImageBlock.mimeType(forExtension: (src as NSString).pathExtension)
            }
            guard let data, !data.isEmpty else { return nil }
            return ImageBlock(data: data, mimeType: ImageBlock.sniffMimeType(data) ?? mime ?? "image/png", size: nil, altText: alt.nilIfBlank)
        }
    }
}
