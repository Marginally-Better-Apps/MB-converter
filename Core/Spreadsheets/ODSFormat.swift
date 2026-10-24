import Foundation

/// OpenDocument Spreadsheet (.ods) reading and writing.
enum ODSFormat {
    static let mimeType = "application/vnd.oasis.opendocument.spreadsheet"

    static func read(url: URL) throws -> Workbook {
        let package = try ZipPackageReader(url: url)
        let content = try package.xml(at: "content.xml")
        guard let spreadsheet = content.child("body")?.child("spreadsheet") else {
            throw DocumentError.unreadable("The file has no spreadsheet body.")
        }
        let sheets = spreadsheet.children("table").enumerated().map { index, table in
            Sheet(name: table.attribute("table:name") ?? "Sheet\(index + 1)", rows: rows(in: table))
        }
        guard !sheets.isEmpty else { throw DocumentError.empty("The spreadsheet has no sheets.") }
        return Workbook(sheets: sheets)
    }

    private static func rows(in table: XElement) -> [[CellValue]] {
        var rows: [[CellValue]] = []
        func visit(_ container: XElement) {
            for child in container.elements {
                switch child.localName {
                case "table-row":
                    let repeats = Int(child.attribute("table:number-rows-repeated") ?? "1") ?? 1
                    var row: [CellValue] = []
                    for cell in child.elements where cell.localName == "table-cell" || cell.localName == "covered-table-cell" {
                        let value = cellValue(cell)
                        let columnRepeats = Int(cell.attribute("table:number-columns-repeated") ?? "1") ?? 1
                        // Producers pad sheets with huge repeated empty ranges; cap them.
                        let count = value.isEmpty ? min(columnRepeats, 64) : min(columnRepeats, 1_024)
                        row.append(contentsOf: Array(repeating: value, count: count))
                    }
                    while let last = row.last, last.isEmpty { row.removeLast() }
                    let rowCount = row.isEmpty ? min(repeats, 16) : min(repeats, 10_000)
                    for _ in 0 ..< rowCount { rows.append(row) }
                case "table-header-rows", "table-rows", "table-row-group":
                    visit(child)
                default:
                    continue
                }
            }
        }
        visit(table)
        while let last = rows.last, last.isEmpty { rows.removeLast() }
        return rows
    }

    private static func cellValue(_ cell: XElement) -> CellValue {
        let type = cell.attribute("office:value-type")
        let text = cell.children("p").map(paragraphText).joined(separator: "\n")
        switch type {
        case "float", "percentage", "currency":
            if let value = cell.attribute("office:value").flatMap(Double.init) { return .number(value) }
        case "boolean":
            if let value = cell.attribute("office:boolean-value") { return .bool(value == "true") }
        case "date":
            if let raw = cell.attribute("office:date-value") {
                if let date = CellValue.dateTimeFormatter.date(from: String(raw.prefix(19))) ?? CellValue.dateFormatter.date(from: String(raw.prefix(10))) {
                    return .date(date)
                }
            }
        case "string":
            if let value = cell.attribute("office:string-value") { return .string(value) }
        default:
            break
        }
        return text.isEmpty ? .empty : .string(text)
    }

    private static func paragraphText(_ p: XElement) -> String {
        var text = ""
        for node in p.children {
            switch node {
            case .text(let string): text += string
            case .element(let element):
                switch element.localName {
                case "s": text += String(repeating: " ", count: Int(element.attribute("text:c") ?? "1") ?? 1)
                case "tab": text += "\t"
                case "line-break": text += "\n"
                case "annotation": continue
                default: text += paragraphText(element)
                }
            }
        }
        return text
    }

    static func write(_ workbook: Workbook, boldHeader: Bool = true, to url: URL) throws {
        let package = ZipPackageWriter()
        package.add("mimetype", string: mimeType, compressed: false)
        var tables = ""
        for (index, sheet) in workbook.sheets.enumerated() {
            let rows = sheet.normalizedRows
            let name = XMLEscaping.escape(sheet.name.isEmpty ? "Sheet\(index + 1)" : sheet.name)
            tables += "<table:table table:name=\"\(name)\"><table:table-column table:number-columns-repeated=\"\(max(rows.first?.count ?? 1, 1))\"/>"
            for (rowIndex, row) in rows.enumerated() {
                tables += "<table:table-row>"
                let style = boldHeader && rowIndex == 0 && rows.count > 1 ? " table:style-name=\"Header\"" : ""
                for value in row {
                    switch value {
                    case .empty:
                        tables += "<table:table-cell\(style)/>"
                    case .string(let text):
                        tables += "<table:table-cell\(style) office:value-type=\"string\" office:string-value=\"\(XMLEscaping.escape(text))\"><text:p>\(XMLEscaping.escape(text))</text:p></table:table-cell>"
                    case .number(let number):
                        tables += "<table:table-cell\(style) office:value-type=\"float\" office:value=\"\(CellValue.format(number))\"><text:p>\(CellValue.format(number))</text:p></table:table-cell>"
                    case .bool(let flag):
                        tables += "<table:table-cell\(style) office:value-type=\"boolean\" office:boolean-value=\"\(flag)\"><text:p>\(flag ? "TRUE" : "FALSE")</text:p></table:table-cell>"
                    case .date(let date):
                        let iso = CellValue.dateFormatter.string(from: date)
                        tables += "<table:table-cell\(style) office:value-type=\"date\" office:date-value=\"\(iso)\"><text:p>\(iso)</text:p></table:table-cell>"
                    }
                }
                tables += "</table:table-row>"
            }
            tables += "</table:table>"
        }
        package.add("content.xml", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(ODTWriter.namespaces)><office:automatic-styles><style:style style:name="Header" style:family="table-cell"><style:text-properties fo:font-weight="bold"/></style:style></office:automatic-styles><office:body><office:spreadsheet>\(tables)</office:spreadsheet></office:body></office:document-content>
        """)
        package.add("styles.xml", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \(ODTWriter.namespaces)><office:styles/></office:document-styles>
        """)
        package.add("meta.xml", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta \(ODTWriter.namespaces)><office:meta><meta:generator>MB Converter</meta:generator></office:meta></office:document-meta>
        """)
        package.add("META-INF/manifest.xml", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3"><manifest:file-entry manifest:full-path="/" manifest:version="1.3" manifest:media-type="\(mimeType)"/><manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="styles.xml" manifest:media-type="text/xml"/><manifest:file-entry manifest:full-path="meta.xml" manifest:media-type="text/xml"/></manifest:manifest>
        """)
        try package.write(to: url)
    }
}
