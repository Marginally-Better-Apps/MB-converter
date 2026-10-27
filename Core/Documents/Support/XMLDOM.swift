import Foundation

/// Minimal DOM for the XML parts of office packages. Namespaced names keep their prefix (e.g. `w:p`).
final class XElement {
    let name: String
    var attributes: [String: String]
    var children: [XNode] = []
    weak var parent: XElement?

    init(name: String, attributes: [String: String] = [:]) {
        self.name = name
        self.attributes = attributes
    }

    /// Name without namespace prefix.
    var localName: String {
        guard let index = name.lastIndex(of: ":") else { return name }
        return String(name[name.index(after: index)...])
    }

    var elements: [XElement] {
        children.compactMap { if case .element(let element) = $0 { element } else { nil } }
    }

    /// Concatenated text of all descendants.
    var text: String {
        children.map { node in
            switch node {
            case .text(let string): string
            case .element(let element): element.text
            }
        }.joined()
    }

    func attribute(_ name: String) -> String? {
        if let value = attributes[name] { return value }
        // Allow lookups by local name when the prefix differs between producers.
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return attributes.first { key, _ in
            key == local || key.hasSuffix(":" + local)
        }?.value
    }

    func child(_ name: String) -> XElement? {
        elements.first { $0.matches(name) }
    }

    func children(_ name: String) -> [XElement] {
        elements.filter { $0.matches(name) }
    }

    /// Depth-first search of descendants (excluding self).
    func descendants(_ name: String) -> [XElement] {
        var result: [XElement] = []
        for element in elements {
            if element.matches(name) { result.append(element) }
            result.append(contentsOf: element.descendants(name))
        }
        return result
    }

    func firstDescendant(_ name: String) -> XElement? {
        for element in elements {
            if element.matches(name) { return element }
            if let found = element.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Matches either the full qualified name or, when `name` has no prefix, the local name.
    func matches(_ query: String) -> Bool {
        if query.contains(":") { return name == query }
        return localName == query
    }
}

enum XNode {
    case element(XElement)
    case text(String)
}

enum XMLDocumentParser {
    static func parse(_ data: Data) throws -> XElement {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            let reason = parser.parserError?.localizedDescription ?? "unknown error"
            throw DocumentError.unreadable("Malformed XML (\(reason)).")
        }
        return root
    }

    static func parse(_ string: String) throws -> XElement {
        try parse(Data(string.utf8))
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var root: XElement?
        private var stack: [XElement] = []
        private var pendingText = ""

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes attributeDict: [String: String] = [:]
        ) {
            flushText()
            let element = XElement(name: qName ?? elementName, attributes: attributeDict)
            if let parent = stack.last {
                element.parent = parent
                parent.children.append(.element(element))
            } else {
                root = element
            }
            stack.append(element)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            flushText()
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            pendingText += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            pendingText += String(decoding: CDATABlock, as: UTF8.self)
        }

        private func flushText() {
            guard !pendingText.isEmpty else { return }
            stack.last?.children.append(.text(pendingText))
            pendingText = ""
        }
    }
}

enum XMLEscaping {
    static func escape(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                // XML 1.0 forbids most C0 control characters.
                if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r" { continue }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}
