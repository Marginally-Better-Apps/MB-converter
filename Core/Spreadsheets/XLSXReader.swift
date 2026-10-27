import Foundation

/// Reads Office Open XML spreadsheets (.xlsx) — values only, using cached formula results.
enum XLSXReader {
    static func read(url: URL) throws -> Workbook {
        let package = try ZipPackageReader(url: url)
        let workbookPath = "xl/workbook.xml"
        let workbook = try package.xml(at: workbookPath)
        var rels: [String: String] = [:]
        for rel in package.xmlIfPresent(at: "xl/_rels/workbook.xml.rels")?.children("Relationship") ?? [] {
            if let id = rel.attribute("Id"), let target = rel.attribute("Target") { rels[id] = target }
        }
        let sharedStrings = loadSharedStrings(package)
        let dateStyles = loadDateStyleIndexes(package)
        let uses1904 = workbook.child("workbookPr")?.attribute("date1904").map { $0 == "1" || $0 == "true" } ?? false

        var sheets: [Sheet] = []
        for sheet in workbook.child("sheets")?.children("sheet") ?? [] {
            guard let id = sheet.attribute("r:id"), let target = rels[id] else { continue }
            let path = ZipPackageReader.resolve(target, against: workbookPath)
            guard let xml = package.xmlIfPresent(at: path) else { continue }
            let name = sheet.attribute("name") ?? "Sheet\(sheets.count + 1)"
            sheets.append(Sheet(name: name, rows: rows(in: xml, sharedStrings: sharedStrings, dateStyles: dateStyles, uses1904: uses1904)))
        }
        guard !sheets.isEmpty else { throw DocumentError.empty("The workbook has no sheets.") }
        return Workbook(sheets: sheets)
    }

    private static func loadSharedStrings(_ package: ZipPackageReader) -> [String] {
        guard let xml = package.xmlIfPresent(at: "xl/sharedStrings.xml") else { return [] }
        return xml.children("si").map { item in
            if let t = item.child("t") { return t.text }
            // Rich text: concatenate runs, skipping phonetic hints.
            return item.children("r").compactMap { $0.child("t")?.text }.joined()
        }
    }

    /// Style indexes (cellXfs) whose number format displays dates.
    private static func loadDateStyleIndexes(_ package: ZipPackageReader) -> Set<Int> {
        guard let styles = package.xmlIfPresent(at: "xl/styles.xml") else { return [] }
        var customDateFormats: Set<Int> = []
        for format in styles.child("numFmts")?.children("numFmt") ?? [] {
            guard let id = Int(format.attribute("numFmtId") ?? ""), let code = format.attribute("formatCode")?.lowercased() else { continue }
            let stripped = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
            if stripped.contains("y") || stripped.contains("d") || (stripped.contains("m") && !stripped.contains("0")) {
                customDateFormats.insert(id)
            }
        }
        let builtInDates: Set<Int> = Set(14 ... 22).union(45 ... 47)
        var result: Set<Int> = []
        for (index, xf) in (styles.child("cellXfs")?.children("xf") ?? []).enumerated() {
            guard let formatID = Int(xf.attribute("numFmtId") ?? "0") else { continue }
            if builtInDates.contains(formatID) || customDateFormats.contains(formatID) { result.insert(index) }
        }
        return result
    }

    private static func rows(in sheet: XElement, sharedStrings: [String], dateStyles: Set<Int>, uses1904: Bool) -> [[CellValue]] {
        guard let data = sheet.child("sheetData") else { return [] }
        var grid: [[CellValue]] = []
        var nextRow = 0
        for row in data.children("row") {
            let rowIndex = (Int(row.attribute("r") ?? "") ?? (nextRow + 1)) - 1
            guard rowIndex < 1_000_000 else { break }
            while grid.count <= rowIndex { grid.append([]) }
            var nextColumn = 0
            for cell in row.children("c") {
                let column = cell.attribute("r").flatMap(columnIndex(fromReference:)) ?? nextColumn
                guard column < 16_384 else { continue }
                nextColumn = column + 1
                let value = cellValue(cell, sharedStrings: sharedStrings, dateStyles: dateStyles, uses1904: uses1904)
                while grid[rowIndex].count <= column { grid[rowIndex].append(.empty) }
                grid[rowIndex][column] = value
            }
            nextRow = rowIndex + 1
        }
        return grid
    }

    private static func cellValue(_ cell: XElement, sharedStrings: [String], dateStyles: Set<Int>, uses1904: Bool) -> CellValue {
        let type = cell.attribute("t") ?? "n"
        let raw = cell.child("v")?.text
        // Files written by scripts (not Excel) can carry a formula with no calculated result.
        // Show the formula rather than an empty cell.
        if raw?.isEmpty ?? true, let formula = cell.child("f")?.text, !formula.isEmpty, type != "inlineStr" {
            return .string("=" + formula)
        }
        switch type {
        case "s":
            guard let index = raw.flatMap(Int.init), index < sharedStrings.count else { return .empty }
            return .string(sharedStrings[index])
        case "inlineStr":
            let text = cell.child("is").map { inline in
                inline.child("t")?.text ?? inline.children("r").compactMap { $0.child("t")?.text }.joined()
            } ?? ""
            return text.isEmpty ? .empty : .string(text)
        case "str":
            return raw.map(CellValue.string) ?? .empty
        case "b":
            return .bool(raw == "1" || raw?.lowercased() == "true")
        case "e":
            return raw.map(CellValue.string) ?? .empty
        case "d":
            if let raw, let date = ISO8601DateFormatter().date(from: raw) ?? CellValue.dateFormatter.date(from: raw) { return .date(date) }
            return raw.map(CellValue.string) ?? .empty
        default:
            guard let raw, let number = Double(raw) else { return .empty }
            if let style = Int(cell.attribute("s") ?? ""), dateStyles.contains(style) {
                return .date(excelDate(number, uses1904: uses1904))
            }
            return .number(number)
        }
    }

    static func excelDate(_ serial: Double, uses1904: Bool) -> Date {
        // 1900 system: serial 1 = 1900-01-01, with Excel's fictional 1900-02-29 (so epoch 1899-12-30).
        let epoch = uses1904 ? -2_082_844_800.0 : -2_209_161_600.0
        return Date(timeIntervalSince1970: epoch + serial * 86_400)
    }

    static func excelSerial(_ date: Date) -> Double {
        (date.timeIntervalSince1970 + 2_209_161_600.0) / 86_400
    }

    /// "B12" → 1, "AA3" → 26.
    static func columnIndex(fromReference reference: String) -> Int? {
        var value = 0
        var sawLetter = false
        for scalar in reference.uppercased().unicodeScalars {
            guard scalar.value >= 65, scalar.value <= 90 else { break }
            value = value * 26 + Int(scalar.value - 64)
            sawLetter = true
        }
        return sawLetter ? value - 1 : nil
    }

    static func columnName(_ index: Int) -> String {
        var name = ""
        var n = index + 1
        while n > 0 {
            let remainder = (n - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            n = (n - 1) / 26
        }
        return name
    }
}
