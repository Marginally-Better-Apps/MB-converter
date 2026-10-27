import Foundation

enum SpreadsheetConverter {
    static func read(_ url: URL, format: FileFormat) throws -> Workbook {
        let workbook: Workbook
        switch format {
        case .csv: workbook = try DelimitedText.read(url: url)
        case .tsv: workbook = try DelimitedText.read(url: url, delimiter: "\t")
        case .xlsx: workbook = try XLSXReader.read(url: url)
        case .ods: workbook = try ODSFormat.read(url: url)
        case .json: workbook = try JSONTableFormat.read(url: url)
        case .xml: workbook = try XMLTableFormat.read(url: url)
        case .pdf:
            let tables = try DocumentConverter.read(url, format: format).extractedTables()
            workbook = tables.sheets.isEmpty ? try pdfTextColumns(url) : tables
        case .docx, .odt, .html, .markdown, .epub, .rtf, .pptx:
            let tables = try DocumentConverter.read(url, format: format).extractedTables()
            guard !tables.sheets.isEmpty else {
                throw DocumentError.empty("No tables were found in this \(format.displayName) file.")
            }
            workbook = tables
        default:
            throw DocumentError.unsupportedFormat(format.displayName)
        }
        return workbook
    }

    /// PDFs rarely carry table structure, so lay text lines out as rows and split
    /// columns wherever there's a wide horizontal gap (two or more spaces or a tab).
    static func pdfTextColumns(_ url: URL) throws -> Workbook {
        let document = try PDFToolkit.open(url)
        var sheets: [Sheet] = []
        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let rows = PDFTextReader.lines(on: page).map { line -> [CellValue] in
                line.plain
                    .replacingOccurrences(of: "\t", with: "  ")
                    .components(separatedBy: "  ")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .map(CellValue.inferred)
            }.filter { !$0.isEmpty }
            if !rows.isEmpty { sheets.append(Sheet(name: "Page \(index + 1)", rows: rows)) }
        }
        guard !sheets.isEmpty else { throw DocumentError.empty("No text was found in this PDF. Try Make Searchable (OCR) first.") }
        return Workbook(sheets: sheets)
    }

    @MainActor
    static func write(_ workbook: Workbook, as format: FileFormat, options: DocumentExportOptions = .default, sheetIndex: Int? = nil, to url: URL) async throws {
        let selected = sheetIndex.map { index in Workbook(sheets: [workbook.sheets[min(max(index, 0), workbook.sheets.count - 1)]]) } ?? workbook
        switch format {
        case .csv, .tsv:
            let delimiter: Character = format == .tsv ? "\t" : ","
            // Delimited formats hold one sheet; the caller chooses which (first by default).
            let sheet = selected.sheets.first ?? Sheet(name: "Sheet1", rows: [])
            try Data(DelimitedText.render(sheet, delimiter: delimiter).utf8).write(to: url)
        case .xlsx: try XLSXWriter.write(selected, to: url)
        case .ods: try ODSFormat.write(selected, to: url)
        case .json: try JSONTableFormat.render(selected).write(to: url)
        case .xml: try XMLTableFormat.render(selected).write(to: url)
        case .html, .markdown, .pdf, .docx, .odt, .rtf, .txt, .epub:
            var document = selected.asDocument()
            document.metadata.title = selected.sheets.count == 1 ? selected.sheets[0].name : nil
            try await DocumentConverter.write(document, as: format, options: options, to: url)
        default:
            throw DocumentError.unsupportedFormat(format.displayName)
        }
    }
}
