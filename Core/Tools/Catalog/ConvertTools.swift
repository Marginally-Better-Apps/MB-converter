import Foundation

extension ToolCatalog {
    // MARK: - Shared conversion options

    static let documentTargets: Set<FileFormat> = [.pdf, .docx, .odt, .rtf, .epub, .html]

    /// Page and typography settings shown when the output is a laid-out document.
    static func layoutOptions(fixedTarget: FileFormat?) -> [ToolOption] {
        func target(_ values: ToolOptionValues) -> FileFormat? {
            fixedTarget ?? FileFormat(rawValue: values.string("target"))
        }
        let reflows: (ToolOptionValues) -> Bool = { values in
            guard let target = target(values), documentTargets.contains(target) else { return false }
            return !(target == .pdf && values.string("layout") == DocumentConverter.Layout.original.rawValue)
        }
        let paged: (ToolOptionValues) -> Bool = { values in
            reflows(values) && [.pdf, .docx, .odt, .rtf].contains(target(values) ?? .txt)
        }
        return [
            .choice("layout", "Layout", DocumentConverter.Layout.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: DocumentConverter.Layout.reformat.rawValue, segmented: true, section: "Layout",
                    footnote: "“Keep original” renders Word, PowerPoint, Excel, RTF and web pages exactly as designed.",
                    visible: { target($0) == .pdf }),
            .choice("pageSize", "Page size", PageSize.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: PageSize.regionalDefault.rawValue, section: "Page", visible: paged),
            .choice("orientation", "Orientation", PageOrientation.allCases.map { ToolChoice($0.rawValue, $0.label) }, segmented: true, section: "Page", visible: paged),
            .choice("margins", "Margins", PageMargins.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: PageMargins.normal.rawValue, segmented: true, section: "Page", visible: paged),
            .toggle("pageNumbers", "Page numbers", section: "Page", visible: paged),
            .choice("font", "Font", FontChoice.allCases.map { ToolChoice($0.rawValue, $0.label) }, segmented: true, section: "Text", visible: reflows),
            .slider("fontSize", "Size", range: 8 ... 20, step: 0.5, default: 11, section: "Text", format: { $0.rounded() == $0 ? "\(Int($0)) pt" : String(format: "%.1f pt", $0) }, visible: reflows),
            .slider("lineSpacing", "Line spacing", range: 1 ... 2, step: 0.05, default: 1.25, section: "Text", format: { String(format: "%.2f×", $0) }, visible: reflows),
            .toggle("images", "Include images", default: true, section: "Text", visible: reflows),
            .text("title", "Title", placeholder: "Keep from file", section: "Document info", visible: reflows),
            .text("author", "Author", placeholder: "Keep from file", section: "Document info", visible: reflows)
        ]
    }

    static func conversionSettings(_ values: ToolOptionValues) -> ConversionEngine.Settings {
        var settings = ConversionEngine.Settings()
        var document = DocumentExportOptions()
        document.pageSize = PageSize(rawValue: values.string("pageSize")) ?? PageSize.regionalDefault
        document.orientation = PageOrientation(rawValue: values.string("orientation")) ?? .portrait
        document.margins = PageMargins(rawValue: values.string("margins")) ?? .normal
        document.fontFamily = FontChoice(rawValue: values.string("font")) ?? .serif
        if values["fontSize"] != nil { document.fontSize = values.double("fontSize") }
        if values["lineSpacing"] != nil { document.lineSpacing = values.double("lineSpacing") }
        if values["images"] != nil { document.includeImages = values.bool("images") }
        document.pageNumbers = values.bool("pageNumbers")
        document.title = values.string("title").nilIfBlank
        document.author = values.string("author").nilIfBlank
        settings.document = document
        settings.layout = DocumentConverter.Layout(rawValue: values.string("layout")) ?? .reformat
        if values["dpi"] != nil { settings.imageDPI = CGFloat(values.double("dpi")) }
        return settings
    }

    @MainActor
    static func runConversion(_ context: ToolContext, fixedTarget: FileFormat?) async throws -> ToolOutput {
        guard !context.inputs.isEmpty else { throw DocumentError.invalidOption("Add a file to convert.") }
        let settings = conversionSettings(context.options)
        var urls: [URL] = []
        var before: Int64 = 0
        for (index, input) in context.inputs.enumerated() {
            let target = fixedTarget ?? FileFormat(rawValue: context.options.string("target")) ?? ConversionTargets.targets(for: input.format).first ?? .pdf
            urls += try await ConversionEngine.convert(input, to: target, settings: settings, context: context)
            before += input.byteCount
            context.progress.report(Double(index + 1) / Double(context.inputs.count))
        }
        let after = urls.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }.reduce(0, +)
        let summary = urls.count > 1 ? "\(urls.count) files · \(after.formattedBytes)" : "\(before.formattedBytes) → \(after.formattedBytes)"
        return ToolOutput(files: urls, summary: summary)
    }

    /// A conversion tool between named formats (e.g. "PDF to Word").
    static func conversion(
        _ id: ToolID, _ title: String, summary: String, from sources: Set<FileFormat>, to target: FileFormat,
        category: ToolCategory, symbol: String? = nil, keywords: [String] = [], featured: Bool = false, extraOptions: [ToolOption] = []
    ) -> ToolDefinition {
        let noun = sources.count == 1 ? "\(sources.first!.displayName) file" : "files"
        return ToolDefinition(
            id: id, title: title, summary: summary,
            symbol: symbol ?? target.symbolName, category: category,
            input: .many(sources, noun: noun),
            options: extraOptions + layoutOptions(fixedTarget: target),
            keywords: keywords + sources.map(\.badge).map { $0.lowercased() } + [target.badge.lowercased(), "convert"],
            isFeatured: featured, actionTitle: "Convert"
        ) { context in
            try await runConversion(context, fixedTarget: target)
        }
    }

    // MARK: - Universal converter

    static let universalConverter = ToolDefinition(
        id: "convert.any", title: "Convert Document", summary: "Any document, spreadsheet or deck to another format",
        symbol: "arrow.left.arrow.right", category: .documents,
        input: .many(Set(FileFormat.documentReadable + FileFormat.spreadsheetReadable + [.svg]), noun: "files"),
        options: [
            .dynamicChoice("target", "Convert to", section: "Output") { inputs in
                guard let first = inputs.first else { return [] }
                let shared = inputs.dropFirst().reduce(Set(ConversionTargets.targets(for: first.format))) { $0.intersection(ConversionTargets.targets(for: $1.format)) }
                return ConversionTargets.targets(for: first.format).filter(shared.contains).map { ToolChoice($0.rawValue, "\($0.displayName) (.\($0.fileExtension))") }
            }
        ] + layoutOptions(fixedTarget: nil),
        keywords: ["converter", "change format", "export", "save as"], isFeatured: true, actionTitle: "Convert"
    ) { context in
        try await runConversion(context, fixedTarget: nil)
    }

    // MARK: - Named presets

    static let documentConversions: [ToolDefinition] = [
        conversion("convert.pdf.docx", "PDF to Word", summary: "Editable DOCX with headings, lists and tables", from: [.pdf], to: .docx, category: .pdf, symbol: "doc.text", keywords: ["pdf to doc", "edit pdf text"], featured: true),
        conversion("convert.pdf.odt", "PDF to OpenDocument", summary: "Editable ODT for LibreOffice", from: [.pdf], to: .odt, category: .pdf),
        conversion("convert.pdf.txt", "PDF to Text", summary: "Plain text from every page", from: [.pdf], to: .txt, category: .pdf, symbol: "text.alignleft", keywords: ["extract text", "copy text"]),
        conversion("convert.pdf.md", "PDF to Markdown", summary: "Clean Markdown for notes apps", from: [.pdf], to: .markdown, category: .pdf, symbol: "number.square"),
        conversion("convert.pdf.html", "PDF to HTML", summary: "A web page with the PDF's text", from: [.pdf], to: .html, category: .pdf, symbol: "chevron.left.forwardslash.chevron.right"),
        conversion("convert.pdf.epub", "PDF to EPUB", summary: "Reflowable e-book for Books and e-readers", from: [.pdf], to: .epub, category: .pdf, symbol: "book.closed", keywords: ["ebook", "kindle"]),
        conversion("convert.pdf.xlsx", "PDF to Excel", summary: "Tables recovered into a spreadsheet", from: [.pdf], to: .xlsx, category: .pdf, symbol: "tablecells", keywords: ["pdf to spreadsheet"]),
        conversion("convert.pdf.csv", "PDF to CSV", summary: "Tables recovered as CSV", from: [.pdf], to: .csv, category: .pdf, symbol: "tablecells"),

        conversion("convert.docx.pdf", "Word to PDF", summary: "DOCX to PDF, original or restyled", from: [.docx], to: .pdf, category: .documents, symbol: "doc.richtext", keywords: ["doc to pdf"], featured: true),
        conversion("convert.odt.pdf", "OpenDocument to PDF", summary: "ODT to PDF with your page settings", from: [.odt], to: .pdf, category: .documents, symbol: "doc.richtext", keywords: ["libreoffice", "open office"]),
        conversion("convert.docx.odt", "Word to OpenDocument", summary: "DOCX to ODT for LibreOffice", from: [.docx], to: .odt, category: .documents, keywords: ["libreoffice"]),
        conversion("convert.odt.docx", "OpenDocument to Word", summary: "ODT to DOCX for Microsoft Word", from: [.odt], to: .docx, category: .documents),
        conversion("convert.rtf.pdf", "RTF to PDF", summary: "Rich text documents to PDF", from: [.rtf], to: .pdf, category: .documents, symbol: "doc.richtext"),
        conversion("convert.txt.pdf", "Text to PDF", summary: "Plain text with real typography", from: [.txt], to: .pdf, category: .documents, symbol: "doc.richtext"),
        conversion("convert.md.pdf", "Markdown to PDF", summary: "Beautifully typeset Markdown", from: [.markdown], to: .pdf, category: .documents, symbol: "doc.richtext"),
        conversion("convert.md.docx", "Markdown to Word", summary: "Markdown to an editable DOCX", from: [.markdown], to: .docx, category: .documents),
        conversion("convert.html.pdf", "HTML to PDF", summary: "Save a web page file as PDF", from: [.html], to: .pdf, category: .documents, symbol: "doc.richtext"),
        conversion("convert.html.md", "HTML to Markdown", summary: "Clean Markdown from web pages", from: [.html], to: .markdown, category: .documents, symbol: "number.square"),
        conversion("convert.docx.md", "Word to Markdown", summary: "DOCX to portable Markdown", from: [.docx], to: .markdown, category: .documents, symbol: "number.square"),
        conversion("convert.docx.epub", "Word to EPUB", summary: "Publish an e-book from a document", from: [.docx, .odt], to: .epub, category: .documents, symbol: "book.closed", keywords: ["ebook"]),
        conversion("convert.epub.pdf", "EPUB to PDF", summary: "Print-ready PDF from an e-book", from: [.epub], to: .pdf, category: .documents, symbol: "doc.richtext", keywords: ["ebook"]),
        conversion("convert.epub.docx", "EPUB to Word", summary: "Edit an e-book's text in Word", from: [.epub], to: .docx, category: .documents),
        conversion("convert.pptx.pdf", "PowerPoint to PDF", summary: "Slides to a landscape PDF", from: [.pptx], to: .pdf, category: .documents, symbol: "rectangle.on.rectangle.angled", keywords: ["ppt", "slides", "presentation", "keynote"], featured: true),
        conversion("convert.pptx.png", "PowerPoint to Images", summary: "Each slide as a PNG", from: [.pptx], to: .png, category: .documents, symbol: "photo.on.rectangle", keywords: ["slides", "ppt"], extraOptions: [.choice("dpi", "Resolution", [ToolChoice("96", "Standard"), ToolChoice("150", "High"), ToolChoice("220", "Very high")], default: "150", segmented: true)]),
        conversion("convert.pptx.docx", "PowerPoint to Word", summary: "Slide text as an editable outline", from: [.pptx], to: .docx, category: .documents, keywords: ["slides", "outline"]),
        conversion("convert.svg.png", "SVG to PNG", summary: "Rasterize vector graphics", from: [.svg], to: .png, category: .images, symbol: "photo")
    ]

    static let spreadsheetConversions: [ToolDefinition] = [
        conversion("convert.xlsx.pdf", "Excel to PDF", summary: "Every sheet as a clean, printable table", from: [.xlsx, .ods], to: .pdf, category: .spreadsheets, symbol: "doc.richtext", keywords: ["xls", "spreadsheet to pdf"], featured: true),
        conversion("convert.xlsx.csv", "Excel to CSV", summary: "One CSV per sheet", from: [.xlsx, .ods], to: .csv, category: .spreadsheets, symbol: "tablecells", keywords: ["xls"]),
        conversion("convert.csv.xlsx", "CSV to Excel", summary: "Typed cells, bold header, frozen first row", from: [.csv, .tsv], to: .xlsx, category: .spreadsheets, symbol: "tablecells", featured: true),
        conversion("convert.xlsx.ods", "Excel to OpenDocument", summary: "XLSX to ODS for LibreOffice", from: [.xlsx], to: .ods, category: .spreadsheets, symbol: "tablecells"),
        conversion("convert.ods.xlsx", "OpenDocument to Excel", summary: "ODS to XLSX", from: [.ods], to: .xlsx, category: .spreadsheets, symbol: "tablecells"),
        conversion("convert.xlsx.json", "Excel to JSON", summary: "Rows as JSON objects keyed by header", from: [.xlsx, .ods, .csv], to: .json, category: .spreadsheets, symbol: "curlybraces", keywords: ["api", "csv to json"]),
        conversion("convert.json.xlsx", "JSON to Excel", summary: "Arrays of objects into a sheet", from: [.json], to: .xlsx, category: .spreadsheets, symbol: "tablecells"),
        conversion("convert.json.csv", "JSON to CSV", summary: "Flatten JSON records into CSV", from: [.json], to: .csv, category: .spreadsheets, symbol: "tablecells"),
        conversion("convert.xml.csv", "XML to CSV", summary: "Repeated XML records into rows", from: [.xml], to: .csv, category: .spreadsheets, symbol: "tablecells"),
        conversion("convert.xml.xlsx", "XML to Excel", summary: "XML records into a spreadsheet", from: [.xml], to: .xlsx, category: .spreadsheets, symbol: "tablecells"),
        conversion("convert.xml.json", "XML to JSON", summary: "XML records as JSON objects", from: [.xml], to: .json, category: .spreadsheets, symbol: "curlybraces"),
        conversion("convert.xlsx.xml", "Excel to XML", summary: "Sheets as structured XML", from: [.xlsx, .ods, .csv], to: .xml, category: .spreadsheets, symbol: "curlybraces"),
        conversion("convert.csv.md", "CSV to Markdown Table", summary: "Paste-ready tables for docs and READMEs", from: [.csv, .tsv, .xlsx], to: .markdown, category: .spreadsheets, symbol: "number.square")
    ]

    static let spreadsheetTools: [ToolDefinition] = [
        ToolDefinition(
            id: "sheet.split", title: "Split Spreadsheet", summary: "Break big CSV or Excel files into smaller ones",
            symbol: "square.split.1x2", category: .spreadsheets, input: .one([.csv, .tsv, .xlsx, .ods], noun: "spreadsheet"),
            options: [
                .choice("mode", "Split by", [ToolChoice("rows", "Row count"), ToolChoice("sheets", "Sheet")], segmented: true),
                .stepper("rows", "Rows per file", range: 10 ... 1_000_000, default: 1_000, visible: { $0.string("mode") == "rows" }),
                .toggle("header", "Repeat header row", default: true, visible: { $0.string("mode") == "rows" }),
                .choice("format", "Save as", [ToolChoice("same", "Same format"), ToolChoice("csv", "CSV"), ToolChoice("xlsx", "Excel")], segmented: true)
            ],
            keywords: ["split csv", "split excel", "chunk", "divide rows"], actionTitle: "Split"
        ) { context in
            let input = try context.first
            let workbook = try SpreadsheetConverter.read(input.url, format: input.format)
            let target: FileFormat = switch context.options.string("format") {
            case "csv": .csv
            case "xlsx": .xlsx
            default: input.format
            }
            var sheets: [Sheet]
            if context.options.string("mode") == "sheets" {
                sheets = workbook.sheets.filter { !$0.isEmpty }
            } else {
                sheets = workbook.sheets.filter { !$0.isEmpty }.flatMap {
                    DelimitedText.split($0, rowsPerFile: context.options.int("rows"), repeatHeader: context.options.bool("header"))
                }
            }
            guard !sheets.isEmpty else { throw DocumentError.empty("The spreadsheet is empty.") }
            var urls: [URL] = []
            for sheet in sheets {
                let url = context.outputURL("\(input.baseName)-\(sheet.name)", target.fileExtension)
                try await SpreadsheetConverter.write(Workbook(sheets: [sheet]), as: target, to: url)
                urls.append(url)
            }
            return ToolOutput(files: urls, summary: "\(urls.count) files")
        },

        ToolDefinition(
            id: "sheet.merge", title: "Merge Spreadsheets", summary: "Combine CSV or Excel files into one workbook",
            symbol: "square.stack.3d.up", category: .spreadsheets, input: .many([.csv, .tsv, .xlsx, .ods, .json], noun: "spreadsheets", min: 2),
            options: [
                .choice("mode", "Combine as", [ToolChoice("sheets", "Separate sheets"), ToolChoice("rows", "Append rows")], segmented: true,
                        footnote: "Append rows keeps the first file's header and skips matching headers in the rest."),
                .choice("format", "Save as", [ToolChoice("xlsx", "Excel"), ToolChoice("ods", "OpenDocument"), ToolChoice("csv", "CSV")], segmented: true)
            ],
            keywords: ["combine csv", "join", "append", "concatenate"], actionTitle: "Merge"
        ) { context in
            var sheets: [Sheet] = []
            for input in context.inputs {
                let workbook = try SpreadsheetConverter.read(input.url, format: input.format)
                for sheet in workbook.sheets where !sheet.isEmpty {
                    sheets.append(Sheet(name: workbook.sheets.count == 1 ? input.baseName : "\(input.baseName) \(sheet.name)", rows: sheet.normalizedRows))
                }
            }
            var target = FileFormat(rawValue: context.options.string("format")) ?? .xlsx
            if context.options.string("mode") == "rows" || target == .csv {
                var rows: [[CellValue]] = []
                for sheet in sheets {
                    var body = sheet.rows
                    if let header = body.first, let existing = rows.first, header == existing { body.removeFirst() }
                    rows += body
                }
                sheets = [Sheet(name: "Merged", rows: rows)]
            }
            if target == .csv, sheets.count > 1 { target = .xlsx }
            let url = context.outputURL("Merged", target.fileExtension)
            try await SpreadsheetConverter.write(Workbook(sheets: sheets), as: target, to: url)
            return ToolOutput(files: [url], summary: "\(sheets.map(\.rows.count).reduce(0, +)) rows")
        }
    ]
}
