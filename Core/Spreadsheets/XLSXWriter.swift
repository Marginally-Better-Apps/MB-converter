import Foundation

/// Writes minimal-but-valid .xlsx workbooks with typed cells, bold header rows and date formatting.
enum XLSXWriter {
    static func write(_ workbook: Workbook, boldHeader: Bool = true, to url: URL) throws {
        let package = ZipPackageWriter()
        let sheets = workbook.sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : workbook.sheets
        let names = uniqueSheetNames(sheets.map(\.name))
        var contentOverrides = ""
        var workbookSheets = ""
        var workbookRels = ""
        for index in sheets.indices {
            contentOverrides += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>"
            workbookSheets += "<sheet name=\"\(XMLEscaping.escape(names[index]))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>"
            workbookRels += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>"
        }
        workbookRels += "<Relationship Id=\"rId\(sheets.count + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"

        package.add("[Content_Types].xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>\(contentOverrides)<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
        """)
        package.add("_rels/.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
        """)
        package.add("docProps/core.xml", string: DOCXWriter.coreProperties(DocumentMetadata(), options: .default))
        package.add("xl/workbook.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><bookViews><workbookView/></bookViews><sheets>\(workbookSheets)</sheets></workbook>
        """)
        package.add("xl/_rels/workbook.xml.rels", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(workbookRels)</Relationships>
        """)
        // Style 0 = default, 1 = bold header, 2 = date (yyyy-mm-dd).
        package.add("xl/styles.xml", string: """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><numFmts count="1"><numFmt numFmtId="164" formatCode="yyyy\\-mm\\-dd"/></numFmts><fonts count="2"><font><sz val="11"/><name val="Calibri"/></font><font><b/><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="3"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/><xf numFmtId="0" fontId="1" fillId="0" borderId="0" xfId="0" applyFont="1"/><xf numFmtId="164" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/></cellXfs><cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles></styleSheet>
        """)
        for (index, sheet) in sheets.enumerated() {
            package.add("xl/worksheets/sheet\(index + 1).xml", string: sheetXML(sheet, boldHeader: boldHeader))
        }
        try package.write(to: url)
    }

    private static func sheetXML(_ sheet: Sheet, boldHeader: Bool) -> String {
        let rows = sheet.normalizedRows
        var data = ""
        for (rowIndex, row) in rows.enumerated() {
            data += "<row r=\"\(rowIndex + 1)\">"
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let reference = XLSXReader.columnName(columnIndex) + String(rowIndex + 1)
                let headerStyle = boldHeader && rowIndex == 0 && rows.count > 1 ? " s=\"1\"" : ""
                switch value {
                case .empty:
                    continue
                case .string(let text):
                    data += "<c r=\"\(reference)\" t=\"inlineStr\"\(headerStyle)><is><t xml:space=\"preserve\">\(XMLEscaping.escape(text))</t></is></c>"
                case .number(let number):
                    data += "<c r=\"\(reference)\"\(headerStyle)><v>\(CellValue.format(number))</v></c>"
                case .bool(let flag):
                    data += "<c r=\"\(reference)\" t=\"b\"\(headerStyle)><v>\(flag ? 1 : 0)</v></c>"
                case .date(let date):
                    data += "<c r=\"\(reference)\" s=\"2\"><v>\(CellValue.format(XLSXReader.excelSerial(date)))</v></c>"
                }
            }
            data += "</row>"
        }
        let columns = rows.first?.count ?? 0
        var cols = ""
        if columns > 0 {
            for column in 0 ..< columns {
                let widest = rows.prefix(200).map { $0.indices.contains(column) ? $0[column].text.count : 0 }.max() ?? 8
                cols += "<col min=\"\(column + 1)\" max=\"\(column + 1)\" width=\"\(min(max(widest + 2, 8), 60))\" customWidth=\"1\"/>"
            }
            cols = "<cols>\(cols)</cols>"
        }
        let pane = boldHeader && rows.count > 1
            ? "<sheetViews><sheetView workbookViewId=\"0\"><pane ySplit=\"1\" topLeftCell=\"A2\" activePane=\"bottomLeft\" state=\"frozen\"/></sheetView></sheetViews>"
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\(pane)\(cols)<sheetData>\(data)</sheetData></worksheet>
        """
    }

    /// Excel limits sheet names to 31 characters, without []:*?/\ and requires uniqueness.
    static func uniqueSheetNames(_ names: [String]) -> [String] {
        var used: Set<String> = []
        return names.enumerated().map { index, raw in
            var name = raw.filter { !"[]:*?/\\".contains($0) }.trimmingCharacters(in: .whitespaces)
            if name.isEmpty { name = "Sheet\(index + 1)" }
            name = String(name.prefix(31))
            var candidate = name
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " (\(counter))"
                candidate = String(name.prefix(31 - suffix.count)) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }
}
