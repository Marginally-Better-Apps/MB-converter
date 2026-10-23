import Foundation
import PDFKit
import Testing
@testable import Converter

struct CSVTests {
    @Test func parsesQuotedFieldsAndNewlines() {
        let csv = "name,notes\r\n\"Smith, J\",\"said \"\"hi\"\"\nthen left\"\r\nplain,\n"
        let rows = DelimitedText.parse(csv)
        #expect(rows == [["name", "notes"], ["Smith, J", "said \"hi\"\nthen left"], ["plain", ""]])
    }

    @Test func detectsDelimiters() {
        #expect(DelimitedText.detectDelimiter("a;b;c\n1;2;3\n") == ";")
        #expect(DelimitedText.detectDelimiter("a\tb\n1\t2\n") == "\t")
        #expect(DelimitedText.detectDelimiter("a,b\n\"x;y\",2\n") == ",")
    }

    @Test func infersCellTypes() {
        #expect(CellValue.inferred("42") == .number(42))
        #expect(CellValue.inferred("-3.5") == .number(-3.5))
        #expect(CellValue.inferred("TRUE") == .bool(true))
        #expect(CellValue.inferred("00501") == .string("00501"))
        #expect(CellValue.inferred("1e3x") == .string("1e3x"))
        #expect(CellValue.inferred("") == .empty)
    }

    @Test func rendersAndReparses() {
        let sheet = Sheet(name: "S", rows: [[.string("a,b"), .number(1.5)], [.string("line\nbreak"), .bool(false)]])
        let text = DelimitedText.render(sheet)
        #expect(DelimitedText.parse(text) == [["a,b", "1.5"], ["line\nbreak", "FALSE"]])
    }

    @Test func splitsKeepingHeader() {
        let rows: [[CellValue]] = [[.string("h")]] + (1 ... 5).map { [.number(Double($0))] }
        let parts = DelimitedText.split(Sheet(name: "data", rows: rows), rowsPerFile: 2, repeatHeader: true)
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { $0.rows.first == [.string("h")] })
        #expect(parts.last?.rows.count == 2)
    }
}

struct WorkbookFormatTests {
    @Test func readsExcelFixture() throws {
        let workbook = try XLSXReader.read(url: TestSupport.fixture("sample.xlsx"))
        #expect(workbook.sheets.map(\.name) == ["Sales", "Notes"])
        let sales = workbook.sheets[0].rows
        #expect(sales[0].prefix(4).map(\.text) == ["Region", "Units", "Price", "Shipped"])
        #expect(sales[1][1] == .number(120))
        #expect(sales[2][2] == .number(10.25))
        #expect(sales[1][3] == .bool(true))
        #expect(sales[3][0] == .string("Americas, North"))
        // A formula saved without a calculated result shows the formula instead of a blank cell.
        #expect(sales[1][4] == .string("=B2*C2"))
        let notes = workbook.sheets[1].rows
        #expect(notes[0][0] == .string("Shared “quotes” & ampersands"))
        #expect(notes[2][1] == .date(CellValue.dateFormatter.date(from: "2026-10-21")!))
    }

    @Test func readsOpenDocumentSpreadsheet() throws {
        let workbook = try ODSFormat.read(url: TestSupport.fixture("sample.ods"))
        #expect(workbook.sheets.first?.name == "Inventory")
        #expect(workbook.sheets.first?.normalizedRows == [[.string("Item"), .string("Qty")], [.string("Bolts"), .number(42)], [.string("Nuts"), .number(7)]])
    }

    static let sample = Workbook(sheets: [
        Sheet(name: "People", rows: [
            [.string("name"), .string("age"), .string("member"), .string("joined")],
            [.string("Ana <A&B>"), .number(31), .bool(true), .date(CellValue.dateFormatter.date(from: "2024-02-29")!)],
            [.string("Bo"), .number(4.5), .bool(false), .empty]
        ]),
        Sheet(name: "Second/Sheet", rows: [[.string("x")], [.number(1)]])
    ])

    @Test func xlsxRoundTripPreservesTypes() throws {
        let url = TestSupport.tempURL("xlsx")
        try XLSXWriter.write(Self.sample, to: url)
        let back = try XLSXReader.read(url: url)
        #expect(back.sheets.count == 2)
        #expect(back.sheets[1].name == "SecondSheet")
        #expect(back.sheets[0].normalizedRows == Self.sample.sheets[0].normalizedRows)
    }

    @Test func odsRoundTripPreservesTypes() throws {
        let url = TestSupport.tempURL("ods")
        try ODSFormat.write(Self.sample, to: url)
        let back = try ODSFormat.read(url: url)
        #expect(back.sheets[0].normalizedRows == Self.sample.sheets[0].normalizedRows)
    }

    @Test func jsonRoundTrip() throws {
        let single = Workbook(sheets: [Self.sample.sheets[0]])
        let url = TestSupport.tempURL("json")
        try JSONTableFormat.render(single).write(to: url)
        let back = try JSONTableFormat.read(url: url)
        let rows = back.sheets[0].normalizedRows
        #expect(rows[0].map(\.text) == ["age", "joined", "member", "name"])
        #expect(rows[1] == [.number(31), .string("2024-02-29"), .bool(true), .string("Ana <A&B>")])
        #expect(rows[2][1] == .empty)
    }

    @Test func jsonNestedObjectsFlatten() throws {
        let url = TestSupport.tempURL("json")
        try Data(#"[{"id":1,"user":{"name":"A","tags":["x"]}},{"id":2,"extra":null}]"#.utf8).write(to: url)
        let rows = try JSONTableFormat.read(url: url).sheets[0].rows
        #expect(rows[0].map(\.text) == ["id", "user.name", "user.tags", "extra"])
        #expect(rows[1][2] == .string("[\"x\"]"))
    }

    @Test func xmlRecordsBecomeRows() throws {
        let url = TestSupport.tempURL("xml")
        try Data("<catalog><book id=\"1\"><title>Dune</title><price>9.99</price></book><book id=\"2\"><title>Emma</title></book></catalog>".utf8).write(to: url)
        let rows = try XMLTableFormat.read(url: url).sheets[0].rows
        #expect(rows[0].map(\.text) == ["@id", "title", "price"])
        #expect(rows[1] == [.number(1), .string("Dune"), .number(9.99)])
        #expect(rows[2][2] == .empty)
        let rendered = String(decoding: XMLTableFormat.render(Workbook(sheets: [Sheet(name: "s", rows: rows)])), as: UTF8.self)
        _ = try XMLDocumentParser.parse(rendered)
        #expect(rendered.contains("<id>1</id><title>Dune</title>"))
    }

    @Test func sanitizesXMLElementNames() {
        #expect(XMLTableFormat.elementName("Unit Price ($)", index: 0) == "Unit_Price")
        #expect(XMLTableFormat.elementName("1st", index: 0) == "_1st")
        #expect(XMLTableFormat.elementName("", index: 2) == "column3")
    }

    @Test func excelColumnNames() {
        #expect(XLSXReader.columnName(0) == "A")
        #expect(XLSXReader.columnName(25) == "Z")
        #expect(XLSXReader.columnName(26) == "AA")
        #expect(XLSXReader.columnIndex(fromReference: "AB12") == 27)
    }

    @MainActor
    @Test(arguments: FileFormat.spreadsheetWritable)
    func excelConvertsToEveryTarget(target: FileFormat) async throws {
        let workbook = try SpreadsheetConverter.read(TestSupport.fixture("sample.xlsx"), format: .xlsx)
        let url = TestSupport.tempURL(target.fileExtension)
        try await SpreadsheetConverter.write(workbook, as: target, to: url)
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
        #expect(size > 20)
        switch target {
        case .pdf:
            #expect(PDFDocument(url: url)?.string?.contains("Americas, North") == true)
        case .html, .markdown, .csv, .tsv, .json, .xml:
            #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("Americas, North"))
        default:
            let back = try SpreadsheetConverter.read(url, format: target)
            #expect(back.sheets[0].rows.flatMap { $0 }.contains(.string("Americas, North")))
        }
    }

    @Test func tablesExtractFromWordDocuments() throws {
        let workbook = try SpreadsheetConverter.read(TestSupport.fixture("sample.docx"), format: .docx)
        #expect(workbook.sheets.first?.rows[2].map(\.text) == ["APAC", "950"])
    }
}
