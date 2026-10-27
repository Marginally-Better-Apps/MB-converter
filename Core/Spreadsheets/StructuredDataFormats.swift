import Foundation

/// JSON and XML ⇄ table conversion. The first row is treated as column names.
enum JSONTableFormat {
    static func read(url: URL) throws -> Workbook {
        let data = try Data(contentsOf: url)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DocumentError.unreadable("The JSON is invalid: \(error.localizedDescription)")
        }
        let name = url.deletingPathExtension().lastPathComponent
        if let dictionary = object as? [String: Any] {
            // { "sheetA": [...], "sheetB": [...] } or a single object.
            let arrays = dictionary.compactMap { key, value -> Sheet? in
                guard let array = value as? [Any] else { return nil }
                return Sheet(name: key, rows: rows(fromArray: array))
            }.sorted { $0.name < $1.name }
            if !arrays.isEmpty, arrays.count == dictionary.count { return Workbook(sheets: arrays) }
            return Workbook(sheets: [Sheet(name: name, rows: rows(fromArray: [dictionary]))])
        }
        if let array = object as? [Any] {
            return Workbook(sheets: [Sheet(name: name, rows: rows(fromArray: array))])
        }
        return Workbook(sheets: [Sheet(name: name, rows: [[cell(object)]])])
    }

    static func rows(fromArray array: [Any]) -> [[CellValue]] {
        if array.allSatisfy({ $0 is [Any] }) {
            return array.compactMap { $0 as? [Any] }.map { $0.map(cell) }
        }
        var columns: [String] = []
        var seen: Set<String> = []
        var flattenedRows: [[String: Any]] = []
        for element in array {
            var flat: [String: Any] = [:]
            if let object = element as? [String: Any] {
                flatten(object, prefix: "", into: &flat)
            } else {
                flat["value"] = element
            }
            for key in orderedKeys(element, flat: flat) where !seen.contains(key) {
                seen.insert(key)
                columns.append(key)
            }
            flattenedRows.append(flat)
        }
        var rows: [[CellValue]] = [columns.map { .string($0) }]
        for flat in flattenedRows {
            rows.append(columns.map { flat[$0].map(cell) ?? .empty })
        }
        return rows
    }

    /// Preserves the source key order where JSONSerialization lost it, by sorting deterministically.
    private static func orderedKeys(_ element: Any, flat: [String: Any]) -> [String] {
        flat.keys.sorted()
    }

    private static func flatten(_ object: [String: Any], prefix: String, into result: inout [String: Any]) {
        for (key, value) in object {
            let path = prefix.isEmpty ? key : "\(prefix).\(key)"
            if let nested = value as? [String: Any] {
                flatten(nested, prefix: path, into: &result)
            } else {
                result[path] = value
            }
        }
    }

    static func cell(_ value: Any) -> CellValue {
        switch value {
        case is NSNull: return .empty
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return .number(number.doubleValue)
        case let string as String: return .string(string)
        default:
            if let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) {
                return .string(String(decoding: data, as: UTF8.self))
            }
            return .string(String(describing: value))
        }
    }

    static func render(_ workbook: Workbook, headerRow: Bool = true) throws -> Data {
        func sheetObject(_ sheet: Sheet) -> [Any] {
            let rows = sheet.normalizedRows
            guard headerRow, let header = rows.first else { return rows.map { $0.map(jsonValue) } }
            let keys = uniqueKeys(header.enumerated().map { index, value in value.text.nilIfBlank ?? "column\(index + 1)" })
            return rows.dropFirst().map { row -> [String: Any] in
                var object: [String: Any] = [:]
                for (index, key) in keys.enumerated() where index < row.count {
                    object[key] = jsonValue(row[index])
                }
                return object
            }
        }
        let root: Any = workbook.sheets.count == 1
            ? sheetObject(workbook.sheets[0])
            : Dictionary(uniqueKeysWithValues: zip(XLSXWriter.uniqueSheetNames(workbook.sheets.map(\.name)), workbook.sheets.map(sheetObject)))
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static func jsonValue(_ value: CellValue) -> Any {
        switch value {
        case .empty: NSNull()
        case .string(let text): text
        case .number(let number): number == number.rounded() && abs(number) < 1e15 ? Int64(number) as Any : number
        case .bool(let flag): flag
        case .date(let date): CellValue.dateFormatter.string(from: date)
        }
    }

    static func uniqueKeys(_ keys: [String]) -> [String] {
        var counts: [String: Int] = [:]
        return keys.map { key in
            counts[key, default: 0] += 1
            return counts[key]! > 1 ? "\(key)_\(counts[key]!)" : key
        }
    }
}

enum XMLTableFormat {
    /// Treats the most common repeated element as a record; its child elements and attributes become columns.
    static func read(url: URL) throws -> Workbook {
        let root = try XMLDocumentParser.parse(Data(contentsOf: url))
        let name = url.deletingPathExtension().lastPathComponent
        let recordParent = findRecordParent(root) ?? root
        let records = recordParent.elements
        guard !records.isEmpty else {
            return Workbook(sheets: [Sheet(name: name, rows: [[.string(root.localName)], [CellValue.inferred(root.text)]])])
        }
        var columns: [String] = []
        var seen: Set<String> = []
        var flatRecords: [[String: String]] = []
        for record in records {
            var flat: [String: String] = [:]
            for (key, value) in record.attributes.sorted(by: { $0.key < $1.key }) {
                flat["@" + key] = value
                if !seen.contains("@" + key) { seen.insert("@" + key); columns.append("@" + key) }
            }
            if record.elements.isEmpty {
                let key = record.localName
                flat[key] = record.text
                if !seen.contains(key) { seen.insert(key); columns.append(key) }
            }
            for child in record.elements {
                let key = child.localName
                let value = child.elements.isEmpty ? child.text : child.elements.map(\.text).joined(separator: "; ")
                flat[key] = flat[key].map { $0 + "; " + value } ?? value
                if !seen.contains(key) { seen.insert(key); columns.append(key) }
            }
            flatRecords.append(flat)
        }
        var rows: [[CellValue]] = [columns.map { .string($0) }]
        for record in flatRecords {
            rows.append(columns.map { record[$0].map(CellValue.inferred) ?? .empty })
        }
        return Workbook(sheets: [Sheet(name: name, rows: rows)])
    }

    private static func findRecordParent(_ element: XElement) -> XElement? {
        var best: (XElement, Int)?
        func visit(_ node: XElement, depth: Int) {
            guard depth < 6 else { return }
            let counts = Dictionary(grouping: node.elements, by: \.name).mapValues(\.count)
            if let maxCount = counts.values.max(), maxCount > (best?.1 ?? 1) {
                best = (node, maxCount)
            }
            node.elements.forEach { visit($0, depth: depth + 1) }
        }
        visit(element, depth: 0)
        return best?.0 ?? (element.elements.count == 1 ? element : nil)
    }

    static func render(_ workbook: Workbook) -> Data {
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<workbook>\n"
        for sheet in workbook.sheets {
            let rows = sheet.normalizedRows
            let header = rows.first.map { $0.enumerated().map { index, cell in elementName(cell.text, index: index) } } ?? []
            xml += "  <sheet name=\"\(XMLEscaping.escape(sheet.name))\">\n"
            for row in rows.dropFirst() {
                xml += "    <row>"
                for (index, value) in row.enumerated() where index < header.count {
                    xml += "<\(header[index])>\(XMLEscaping.escape(value.text))</\(header[index])>"
                }
                xml += "</row>\n"
            }
            xml += "  </sheet>\n"
        }
        xml += "</workbook>\n"
        return Data(xml.utf8)
    }

    /// Turns arbitrary header text into a valid XML element name.
    static func elementName(_ text: String, index: Int) -> String {
        var name = ""
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" || scalar == "-" || scalar == "." {
                name.unicodeScalars.append(scalar)
            } else if !name.isEmpty, name.last != "_" {
                name.append("_")
            }
        }
        while name.hasSuffix("_") { name.removeLast() }
        if name.isEmpty { name = "column\(index + 1)" }
        if let first = name.unicodeScalars.first, !CharacterSet.letters.contains(first), first != "_" {
            name = "_" + name
        }
        if name.lowercased().hasPrefix("xml") { name = "_" + name }
        return name
    }
}
