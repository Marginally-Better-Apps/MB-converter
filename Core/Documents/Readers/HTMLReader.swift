import CoreGraphics
import Foundation

/// Forgiving HTML parser: real-world HTML is rarely well-formed XML, so this tokenizes tag soup,
/// builds a light tree with implicit closes, then maps it onto `RichDocument` blocks.
enum HTMLReader {
    typealias ImageResolver = (String) -> Data?

    static func read(url: URL) throws -> RichDocument {
        let data = try Data(contentsOf: url)
        let baseDirectory = url.deletingLastPathComponent()
        return read(html: TextDecoding.decode(data), imageResolver: { src in
            guard !src.contains("://") else { return nil }
            let path = src.removingPercentEncoding ?? src
            return try? Data(contentsOf: baseDirectory.appendingPathComponent(path))
        })
    }

    static func read(html: String, imageResolver: ImageResolver? = nil) -> RichDocument {
        let root = HTMLTreeBuilder.build(html)
        var metadata = DocumentMetadata()
        if let head = root.firstDescendant("head") {
            metadata.title = head.firstDescendant("title")?.text.collapsingWhitespace.nilIfBlank
            for meta in head.descendants("meta") {
                let name = meta.attribute("name")?.lowercased()
                let content = meta.attribute("content")?.nilIfBlank
                switch name {
                case "author": metadata.author = content
                case "description", "subject": metadata.subject = content
                case "keywords":
                    metadata.keywords = (content ?? "").split(separator: ",").compactMap { String($0).nilIfBlank }
                default: break
                }
            }
        }
        if let lang = root.firstDescendant("html")?.attribute("lang") { metadata.language = lang }
        let body = root.firstDescendant("body") ?? root
        let converter = Converter(imageResolver: imageResolver)
        return RichDocument(metadata: metadata, blocks: converter.blocks(in: body, style: RunStyle()))
    }

    // MARK: - DOM → blocks

    private struct Converter {
        let imageResolver: ImageResolver?

        static let blockTags: Set<String> = [
            "p", "div", "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "table", "blockquote", "pre", "hr",
            "section", "article", "header", "footer", "main", "nav", "aside", "figure", "figcaption", "dl", "dt", "dd",
            "address", "form", "center", "body", "html", "tbody", "thead", "tfoot", "tr", "td", "th", "caption", "details", "summary"
        ]
        static let skippedTags: Set<String> = ["script", "style", "head", "title", "noscript", "template", "svg", "math", "iframe", "object", "button", "select", "textarea", "nav"]

        func blocks(in element: XElement, style: RunStyle) -> [Block] {
            var blocks: [Block] = []
            var runs: [Run] = []

            func flush() {
                let trimmed = runs.trimmed()
                if !trimmed.isEmpty { blocks.append(.paragraph(runs: trimmed)) }
                runs = []
            }

            for node in element.children {
                switch node {
                case .text(let text):
                    runs.append(Run(text.collapsingWhitespace, style))
                case .element(let child):
                    let tag = child.name
                    if Self.skippedTags.contains(tag) { continue }
                    if Self.blockTags.contains(tag) || tag == "img" {
                        flush()
                        blocks.append(contentsOf: block(child, style: style))
                    } else {
                        var images: [Block] = []
                        collectInline(child, style: style, runs: &runs, images: &images)
                        if !images.isEmpty {
                            flush()
                            blocks.append(contentsOf: images)
                        }
                    }
                }
            }
            flush()
            return blocks
        }

        private func block(_ element: XElement, style: RunStyle) -> [Block] {
            let css = CSSInline(element.attribute("style"))
            var result: [Block] = []
            if css.pageBreakBefore { result.append(.pageBreak) }
            switch element.name {
            case "h1", "h2", "h3", "h4", "h5", "h6":
                let level = Int(element.name.dropFirst()) ?? 1
                var runs: [Run] = []
                var images: [Block] = []
                collectChildren(element, style: style, runs: &runs, images: &images)
                let trimmed = runs.trimmed()
                if !trimmed.isEmpty { result.append(.heading(level: level, runs: trimmed)) }
                result.append(contentsOf: images)
            case "p", "dt", "figcaption", "summary", "caption", "address":
                var runs: [Run] = []
                var images: [Block] = []
                var paragraphStyle = style
                css.apply(to: &paragraphStyle)
                collectChildren(element, style: paragraphStyle, runs: &runs, images: &images)
                let trimmed = runs.trimmed()
                let alignment = css.alignment ?? (element.attribute("align").map(Self.alignment) ?? .natural)
                if !trimmed.isEmpty {
                    result.append(.paragraph(runs: trimmed, alignment: alignment))
                }
                result.append(contentsOf: images)
            case "ul", "ol":
                let ordered = element.name == "ol"
                var items: [[Block]] = []
                for child in element.elements {
                    if child.name == "li" {
                        items.append(blocks(in: child, style: style))
                    } else if child.name == "ul" || child.name == "ol" {
                        // Invalid but common: nested list directly inside a list.
                        let nested = block(child, style: style)
                        if items.isEmpty { items.append([]) }
                        items[items.count - 1].append(contentsOf: nested)
                    }
                }
                if !items.isEmpty { result.append(.list(ordered: ordered, items: items)) }
            case "li", "dd":
                result.append(contentsOf: blocks(in: element, style: style))
            case "table":
                if let table = table(element, style: style) { result.append(.table(table)) }
            case "blockquote":
                let inner = blocks(in: element, style: style)
                if !inner.isEmpty { result.append(.quote(inner)) }
            case "pre":
                var text = element.text
                if text.hasPrefix("\n") { text.removeFirst() }
                while text.hasSuffix("\n") { text.removeLast() }
                result.append(.code(text))
            case "hr":
                result.append(.rule)
            case "img":
                if let image = image(element) { result.append(.image(image)) }
            default:
                var nextStyle = style
                css.apply(to: &nextStyle)
                let forcedAlignment: TextAlignment? = element.name == "center" ? .center : css.alignment
                if let forcedAlignment {
                    result.append(contentsOf: blocks(in: element, style: nextStyle).map { block in
                        if case .paragraph(let runs, .natural) = block { return .paragraph(runs: runs, alignment: forcedAlignment) }
                        return block
                    })
                } else {
                    result.append(contentsOf: blocks(in: element, style: nextStyle))
                }
            }
            if css.pageBreakAfter { result.append(.pageBreak) }
            if element.attribute("class")?.split(separator: " ").contains("page-break") == true, !css.pageBreakAfter {
                result.append(.pageBreak)
            }
            return result
        }

        private func collectChildren(_ element: XElement, style: RunStyle, runs: inout [Run], images: inout [Block]) {
            for node in element.children {
                switch node {
                case .text(let text):
                    runs.append(Run(text.collapsingWhitespace, style))
                case .element(let child):
                    if Self.skippedTags.contains(child.name) { continue }
                    collectInline(child, style: style, runs: &runs, images: &images)
                }
            }
        }

        private func collectInline(_ element: XElement, style: RunStyle, runs: inout [Run], images: inout [Block]) {
            var next = style
            switch element.name {
            case "b", "strong": next.bold = true
            case "i", "em", "cite", "dfn", "var": next.italic = true
            case "u", "ins": next.underline = true
            case "s", "strike", "del": next.strikethrough = true
            case "code", "kbd", "samp", "tt": next.code = true
            case "sup": next.superscript = true
            case "sub": next.subscript = true
            case "a":
                if let href = element.attribute("href"), !href.isEmpty, !href.lowercased().hasPrefix("javascript:") {
                    next.link = href
                }
            case "br":
                runs.append(Run("\n", style))
                return
            case "img":
                if let image = image(element) { images.append(.image(image)) }
                return
            case "wbr":
                return
            default:
                break
            }
            CSSInline(element.attribute("style")).apply(to: &next)
            if Self.blockTags.contains(element.name) {
                // Block element inside inline context (e.g. <a><div>…</div></a>): keep its text.
                runs.append(Run(" ", style))
            }
            collectChildren(element, style: next, runs: &runs, images: &images)
        }

        private func table(_ element: XElement, style: RunStyle) -> TableBlock? {
            var rows: [[[Block]]] = []
            var hasHeader = false
            func visit(_ container: XElement, inHead: Bool) {
                for child in container.elements {
                    switch child.name {
                    case "thead": visit(child, inHead: true)
                    case "tbody", "tfoot": visit(child, inHead: false)
                    case "tr":
                        var row: [[Block]] = []
                        var allHeaderCells = true
                        for cell in child.elements where cell.name == "td" || cell.name == "th" {
                            if cell.name != "th" { allHeaderCells = false }
                            row.append(blocks(in: cell, style: style))
                            let span = min(Int(cell.attribute("colspan") ?? "1") ?? 1, 20)
                            if span > 1 { row.append(contentsOf: Array(repeating: [], count: span - 1)) }
                        }
                        if rows.isEmpty, inHead || (allHeaderCells && !row.isEmpty) { hasHeader = true }
                        if !row.isEmpty { rows.append(row) }
                    default:
                        continue
                    }
                }
            }
            visit(element, inHead: false)
            guard !rows.isEmpty else { return nil }
            return TableBlock(rows: rows, hasHeaderRow: hasHeader)
        }

        private func image(_ element: XElement) -> ImageBlock? {
            guard let src = element.attribute("src")?.trimmingCharacters(in: .whitespaces), !src.isEmpty else { return nil }
            var data: Data?
            var mime: String?
            if src.hasPrefix("data:") {
                let parts = src.dropFirst(5).split(separator: ",", maxSplits: 1)
                if parts.count == 2 {
                    let header = String(parts[0])
                    mime = header.split(separator: ";").first.map(String.init)
                    let payload = String(parts[1])
                    data = header.contains("base64")
                        ? Data(base64Encoded: payload, options: .ignoreUnknownCharacters)
                        : payload.removingPercentEncoding.map { Data($0.utf8) }
                }
            } else {
                data = imageResolver?(src)
                mime = ImageBlock.mimeType(forExtension: (src.split(separator: "?").first.map(String.init) ?? src).components(separatedBy: ".").last ?? "")
            }
            guard let data, !data.isEmpty else { return nil }
            let resolvedMime = ImageBlock.sniffMimeType(data) ?? mime ?? "image/png"
            var size: CGSize?
            if let width = element.attribute("width").flatMap(Double.init), let height = element.attribute("height").flatMap(Double.init) {
                size = CGSize(width: width * 0.75, height: height * 0.75)
            }
            return ImageBlock(data: data, mimeType: resolvedMime, size: size, altText: element.attribute("alt")?.nilIfBlank)
        }

        static func alignment(_ value: String) -> TextAlignment {
            switch value.lowercased() {
            case "center": .center
            case "right": .right
            case "justify": .justified
            default: .natural
            }
        }
    }

    /// The handful of inline CSS declarations that map onto the document model.
    private struct CSSInline {
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var alignment: TextAlignment?
        var pageBreakBefore = false
        var pageBreakAfter = false

        init(_ style: String?) {
            guard let style else { return }
            for declaration in style.split(separator: ";") {
                let pair = declaration.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard pair.count == 2 else { continue }
                let (property, value) = (pair[0], pair[1])
                switch property {
                case "font-weight": bold = value == "bold" || value == "bolder" || (Int(value) ?? 400) >= 600
                case "font-style": italic = value == "italic" || value == "oblique"
                case "text-decoration", "text-decoration-line":
                    underline = value.contains("underline")
                    strike = value.contains("line-through")
                case "text-align": alignment = Converter.alignment(value)
                case "page-break-before", "break-before": pageBreakBefore = value == "always" || value == "page"
                case "page-break-after", "break-after": pageBreakAfter = value == "always" || value == "page"
                default: continue
                }
            }
        }

        func apply(to style: inout RunStyle) {
            if bold { style.bold = true }
            if italic { style.italic = true }
            if underline { style.underline = true }
            if strike { style.strikethrough = true }
        }
    }
}

// MARK: - Tokenizer & tree builder

enum HTMLTreeBuilder {
    static let voidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"]
    private static let rawTextElements: Set<String> = ["script", "style", "textarea", "title"]
    /// Opening one of these implicitly closes an open `<p>`.
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "div", "dl", "fieldset", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
        "header", "hr", "main", "nav", "ol", "p", "pre", "section", "table", "ul", "figure"
    ]

    static func build(_ html: String) -> XElement {
        let root = XElement(name: "#document")
        var stack: [XElement] = [root]
        var index = html.startIndex

        func current() -> XElement { stack[stack.count - 1] }

        func appendText(_ text: String) {
            guard !text.isEmpty else { return }
            let decoded = HTMLEntities.decode(text)
            if case .text(let previous)? = current().children.last {
                current().children[current().children.count - 1] = .text(previous + decoded)
            } else {
                current().children.append(.text(decoded))
            }
        }

        func close(_ name: String) {
            guard let position = stack.lastIndex(where: { $0.name == name }), position > 0 else { return }
            stack.removeSubrange(position...)
        }

        func open(_ element: XElement, selfClosing: Bool) {
            let name = element.name
            if closesParagraph.contains(name) { closeIfOpen("p", stoppingAt: ["div", "td", "th", "li", "blockquote", "body", "table"]) }
            switch name {
            case "li": closeIfOpen("li", stoppingAt: ["ul", "ol"])
            case "dt", "dd": closeIfOpen("dt", stoppingAt: ["dl"]); closeIfOpen("dd", stoppingAt: ["dl"])
            case "tr": closeIfOpen("tr", stoppingAt: ["table", "tbody", "thead", "tfoot"])
            case "td", "th": closeIfOpen("td", stoppingAt: ["tr", "table"]); closeIfOpen("th", stoppingAt: ["tr", "table"])
            case "tbody", "thead", "tfoot": closeIfOpen("tbody", stoppingAt: ["table"]); closeIfOpen("thead", stoppingAt: ["table"])
            case "option": closeIfOpen("option", stoppingAt: ["select"])
            default: break
            }
            element.parent = current()
            current().children.append(.element(element))
            if !selfClosing, !voidElements.contains(name) {
                stack.append(element)
            }
        }

        func closeIfOpen(_ name: String, stoppingAt boundaries: Set<String>) {
            for position in stack.indices.reversed() {
                let candidate = stack[position].name
                if candidate == name {
                    stack.removeSubrange(position...)
                    return
                }
                if boundaries.contains(candidate) { return }
            }
        }

        while index < html.endIndex {
            guard let tagStart = html[index...].firstIndex(of: "<") else {
                appendText(String(html[index...]))
                break
            }
            if tagStart > index { appendText(String(html[index ..< tagStart])) }
            let afterBracket = html.index(after: tagStart)
            guard afterBracket < html.endIndex else {
                appendText("<")
                break
            }

            if html[afterBracket...].hasPrefix("!--") {
                if let end = html.range(of: "-->", range: afterBracket ..< html.endIndex) {
                    index = end.upperBound
                } else {
                    index = html.endIndex
                }
                continue
            }
            if html[afterBracket] == "!" || html[afterBracket] == "?" {
                index = html[afterBracket...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                continue
            }
            let isEnd = html[afterBracket] == "/"
            let nameStart = isEnd ? html.index(after: afterBracket) : afterBracket
            guard nameStart < html.endIndex, html[nameStart].isLetter else {
                appendText("<")
                index = afterBracket
                continue
            }
            guard let tagEnd = findTagEnd(html, from: nameStart) else {
                appendText(String(html[tagStart...]))
                break
            }
            let inner = html[nameStart ..< tagEnd]
            index = html.index(after: tagEnd)
            let nameEnd = inner.firstIndex(where: { $0.isWhitespace || $0 == "/" }) ?? inner.endIndex
            let rawName = String(inner[inner.startIndex ..< nameEnd]).lowercased()
            let name = rawName.split(separator: ":").last.map(String.init) ?? rawName

            if isEnd {
                if name == "p", !stack.contains(where: { $0.name == "p" }) {
                    open(XElement(name: "p"), selfClosing: true)
                } else if name == "br" {
                    open(XElement(name: "br"), selfClosing: true)
                } else {
                    close(name)
                }
                continue
            }
            let selfClosing = inner.hasSuffix("/")
            let element = XElement(name: name, attributes: parseAttributes(String(inner[nameEnd...])))
            open(element, selfClosing: selfClosing)

            if rawTextElements.contains(name), !selfClosing {
                let closing = "</\(name)"
                if let end = html.range(of: closing, options: .caseInsensitive, range: index ..< html.endIndex) {
                    let raw = String(html[index ..< end.lowerBound])
                    element.children.append(.text(name == "title" || name == "textarea" ? HTMLEntities.decode(raw) : raw))
                    index = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                } else {
                    index = html.endIndex
                }
                close(name)
            }
        }
        return root
    }

    private static func findTagEnd(_ html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var index = start
        while index < html.endIndex {
            let ch = html[index]
            if let open = quote {
                if ch == open { quote = nil }
            } else if ch == "\"" || ch == "'" {
                quote = ch
            } else if ch == ">" {
                return index
            }
            index = html.index(after: index)
        }
        return nil
    }

    static func parseAttributes(_ source: String) -> [String: String] {
        var attributes: [String: String] = [:]
        let chars = Array(source)
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace || chars[i] == "/" { i += 1 }
            let nameStart = i
            while i < chars.count, !chars[i].isWhitespace, chars[i] != "=", chars[i] != "/" { i += 1 }
            guard i > nameStart else { i += 1; continue }
            let name = String(chars[nameStart ..< i]).lowercased()
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            var value = ""
            if i < chars.count, chars[i] == "=" {
                i += 1
                while i < chars.count, chars[i].isWhitespace { i += 1 }
                if i < chars.count, chars[i] == "\"" || chars[i] == "'" {
                    let quote = chars[i]
                    i += 1
                    let valueStart = i
                    while i < chars.count, chars[i] != quote { i += 1 }
                    value = String(chars[valueStart ..< min(i, chars.count)])
                    i += 1
                } else {
                    let valueStart = i
                    while i < chars.count, !chars[i].isWhitespace { i += 1 }
                    value = String(chars[valueStart ..< i])
                }
            }
            attributes[name] = HTMLEntities.decode(value)
        }
        return attributes
    }
}

enum HTMLEntities {
    private static let named: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "thinsp": "\u{2009}", "ndash": "–", "mdash": "—", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "sbquo": "‚",
        "bdquo": "„", "hellip": "…", "bull": "•", "middot": "·", "copy": "©", "reg": "®", "trade": "™", "deg": "°", "plusmn": "±",
        "times": "×", "divide": "÷", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢", "sect": "§", "para": "¶", "laquo": "«",
        "raquo": "»", "frac12": "½", "frac14": "¼", "frac34": "¾", "iexcl": "¡", "iquest": "¿", "shy": "\u{00AD}", "larr": "←",
        "rarr": "→", "uarr": "↑", "darr": "↓", "harr": "↔", "le": "≤", "ge": "≥", "ne": "≠", "infin": "∞", "check": "✓",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â", "auml": "ä", "atilde": "ã",
        "aring": "å", "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "otilde": "õ", "oslash": "ø", "uacute": "ú",
        "ugrave": "ù", "ucirc": "û", "uuml": "ü", "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï", "ntilde": "ñ", "ccedil": "ç",
        "szlig": "ß", "Eacute": "É", "Aacute": "Á", "Oacute": "Ó", "Uacute": "Ú", "Ntilde": "Ñ", "Ccedil": "Ç", "Auml": "Ä",
        "Ouml": "Ö", "Uuml": "Ü", "aelig": "æ", "AElig": "Æ", "zwj": "\u{200D}", "zwnj": "\u{200C}"
    ]

    static func decode(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]
            guard ch == "&", let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(ch)
                index = text.index(after: index)
                continue
            }
            let entity = String(text[text.index(after: index) ..< semicolon])
            if let replacement = resolve(entity) {
                result += replacement
                index = text.index(after: semicolon)
            } else {
                result.append(ch)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func resolve(_ entity: String) -> String? {
        if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
            return UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        if entity.hasPrefix("#") {
            return UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
        return named[entity]
    }
}

/// Text decoding with BOM sniffing and a Latin-1 fallback for legacy files.
enum TextDecoding {
    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let string = String(data: data, encoding: .utf16) { return string }
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        if let string = String(data: data, encoding: .windowsCP1252) { return string }
        return String(decoding: data, as: UTF8.self)
    }
}
