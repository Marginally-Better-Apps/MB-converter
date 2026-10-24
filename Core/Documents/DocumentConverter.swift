import Foundation

/// Reads any supported document into the shared model and writes it back out in another format.
enum DocumentConverter {
    enum Layout: String, CaseIterable, Identifiable, Hashable, Sendable {
        /// Re-flow content using the chosen page, font and spacing settings.
        case reformat
        /// Keep the source's own styling (WebKit's Office/HTML renderer). PDF output only.
        case original

        var id: String { rawValue }
        var label: String { self == .original ? "Keep original" : "Use my settings" }
    }

    /// Formats whose original layout WebKit can reproduce when producing a PDF.
    static let originalLayoutSources: Set<FileFormat> = [.docx, .pptx, .xlsx, .rtf, .html, .txt]

    static func read(_ url: URL, format: FileFormat, password: String? = nil) throws -> RichDocument {
        let document: RichDocument
        switch format {
        case .docx: document = try DOCXReader.read(url: url)
        case .odt: document = try ODTReader.read(url: url)
        case .rtf: document = try RTFReader.read(url: url)
        case .txt: document = try PlainTextReader.read(url: url)
        case .markdown: document = try MarkdownReader.read(url: url)
        case .html: document = try HTMLReader.read(url: url)
        case .epub: document = try EPUBReader.read(url: url)
        case .pptx: document = try PPTXReader.read(url: url)
        case .pdf: document = try PDFTextReader.read(url: url, password: password)
        case .xlsx, .ods, .csv, .tsv, .json, .xml:
            let workbook = try SpreadsheetConverter.read(url, format: format)
            document = workbook.asDocument()
        default:
            throw DocumentError.unsupportedFormat(format.displayName)
        }
        return document
    }

    @MainActor
    static func write(_ document: RichDocument, as format: FileFormat, options: DocumentExportOptions, to url: URL) async throws {
        switch format {
        case .docx: try DOCXWriter.write(document, options: options, to: url)
        case .odt: try ODTWriter.write(document, options: options, to: url)
        case .rtf: try RTFWriter.data(document, options: options).write(to: url)
        case .txt: try PlainTextWriter.data(document).write(to: url)
        case .markdown: try MarkdownWriter.data(document).write(to: url)
        case .html: try HTMLWriter.data(document, options: options).write(to: url)
        case .epub: try EPUBWriter.write(document, options: options, to: url)
        case .pdf:
            let html = HTMLWriter.render(document, options: options, mode: .print)
            let setup = WebPDFRenderer.PageSetup(options: options, title: document.resolvedTitle, author: document.metadata.author)
            try await WebPDFRenderer.renderHTML(html, setup: setup).write(to: url)
        default:
            throw DocumentError.unsupportedFormat(format.displayName)
        }
    }

    @MainActor
    static func convert(
        input: URL,
        from source: FileFormat,
        to target: FileFormat,
        options: DocumentExportOptions = .default,
        layout: Layout = .reformat,
        password: String? = nil,
        output: URL
    ) async throws {
        if target == .pdf, layout == .original, originalLayoutSources.contains(source) {
            let setup = WebPDFRenderer.PageSetup(options: options, title: nil, author: nil)
            try await WebPDFRenderer.renderFile(input, setup: setup).write(to: output)
            return
        }
        let document = try read(input, format: source, password: password)
        guard !document.isEffectivelyEmpty else {
            throw DocumentError.empty("No readable content was found in this file.")
        }
        try await write(document, as: target, options: options, to: output)
    }
}
