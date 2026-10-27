import Foundation

/// Tabular data model shared by every spreadsheet/data format.
struct Workbook: Hashable, Sendable {
    var sheets: [Sheet]

    init(sheets: [Sheet]) {
        self.sheets = sheets
    }

    var isEmpty: Bool { sheets.allSatisfy(\.isEmpty) }
}

struct Sheet: Hashable, Sendable {
    var name: String
    var rows: [[CellValue]]

    init(name: String, rows: [[CellValue]]) {
        self.name = name
        self.rows = rows
    }

    var columnCount: Int { rows.map(\.count).max() ?? 0 }

    var isEmpty: Bool { rows.allSatisfy { $0.allSatisfy(\.isEmpty) } }

    /// Rows padded to a rectangular grid with trailing empty rows/columns removed.
    var normalizedRows: [[CellValue]] {
        var trimmed = rows
        while let last = trimmed.last, last.allSatisfy(\.isEmpty) { trimmed.removeLast() }
        var width = 0
        for row in trimmed {
            if let lastFilled = row.lastIndex(where: { !$0.isEmpty }) { width = max(width, lastFilled + 1) }
        }
        return trimmed.map { row in
            var padded = Array(row.prefix(width))
            while padded.count < width { padded.append(.empty) }
            return padded
        }
    }
}

enum CellValue: Hashable, Sendable {
    case empty
    case string(String)
    case number(Double)
    case bool(Bool)
    case date(Date)

    var isEmpty: Bool {
        if case .empty = self { return true }
        if case .string(let text) = self { return text.isEmpty }
        return false
    }

    /// Display text used by CSV, HTML, Markdown and PDF output.
    var text: String {
        switch self {
        case .empty: ""
        case .string(let text): text
        case .number(let number): Self.format(number)
        case .bool(let value): value ? "TRUE" : "FALSE"
        case .date(let date): Self.dateFormatter.string(from: date)
        }
    }

    static func format(_ number: Double) -> String {
        if number.isNaN || number.isInfinite { return String(number) }
        if number == number.rounded(), abs(number) < 1e15 { return String(Int64(number)) }
        var text = String(format: "%.10g", number)
        if text.contains("e") { text = String(number) }
        return text
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter
    }()

    /// Infers numbers and booleans from plain text (CSV cells, XML text).
    static func inferred(_ raw: String) -> CellValue {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return raw.isEmpty ? .empty : .string(raw) }
        // Keep identifiers like zip codes and phone numbers with leading zeros as text.
        if trimmed.count > 1, trimmed.hasPrefix("0"), !trimmed.hasPrefix("0."), trimmed.allSatisfy(\.isNumber) {
            return .string(raw)
        }
        let lower = trimmed.lowercased()
        if lower == "true" { return .bool(true) }
        if lower == "false" { return .bool(false) }
        if trimmed.count < 24, let number = Double(trimmed), trimmed.rangeOfCharacter(from: CharacterSet.letters.subtracting(CharacterSet(charactersIn: "eE"))) == nil {
            return .number(number)
        }
        return .string(raw)
    }
}

extension Workbook {
    /// Renders each sheet as a titled table for document/PDF output.
    func asDocument(includeSheetTitles: Bool? = nil) -> RichDocument {
        let showTitles = includeSheetTitles ?? (sheets.count > 1)
        var blocks: [Block] = []
        for (index, sheet) in sheets.enumerated() {
            let rows = sheet.normalizedRows
            guard !rows.isEmpty else { continue }
            if index > 0, !blocks.isEmpty { blocks.append(.pageBreak) }
            if showTitles { blocks.append(.heading(level: 2, runs: [Run(sheet.name)])) }
            blocks.append(.table(TableBlock(textRows: rows.map { $0.map(\.text) }, hasHeaderRow: rows.count > 1)))
        }
        return RichDocument(blocks: blocks)
    }
}

extension RichDocument {
    /// Extracts tables (e.g. from a DOCX or PDF→document conversion) into sheets.
    func extractedTables() -> Workbook {
        var sheets: [Sheet] = []
        func visit(_ blocks: [Block]) {
            for block in blocks {
                switch block {
                case .table(let table):
                    let rows = table.rows.map { row in row.map { cell in CellValue.inferred(cell.map(\.plainText).joined(separator: "\n")) } }
                    sheets.append(Sheet(name: "Table \(sheets.count + 1)", rows: rows))
                case .list(_, let items):
                    items.forEach(visit)
                case .quote(let inner):
                    visit(inner)
                default:
                    continue
                }
            }
        }
        visit(blocks)
        return Workbook(sheets: sheets)
    }
}
