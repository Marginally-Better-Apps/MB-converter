import Foundation
import PDFKit
import Testing
@testable import Converter

/// Helpers to query a document tree.
extension RichDocument {
    var headings: [(Int, String)] {
        blocks.compactMap { if case .heading(let level, let runs) = $0 { (level, runs.plainText) } else { nil } }
    }

    var allBlocks: [Block] {
        func flatten(_ blocks: [Block]) -> [Block] {
            blocks.flatMap { block -> [Block] in
                switch block {
                case .list(_, let items): [block] + items.flatMap(flatten)
                case .quote(let inner): [block] + flatten(inner)
                case .table(let table): [block] + table.rows.flatMap { $0.flatMap(flatten) }
                default: [block]
                }
            }
        }
        return flatten(blocks)
    }

    var allRuns: [Run] {
        allBlocks.flatMap { block -> [Run] in
            switch block {
            case .heading(_, let runs), .paragraph(let runs, _): runs
            default: []
            }
        }
    }

    var tables: [TableBlock] { allBlocks.compactMap { if case .table(let t) = $0 { t } else { nil } } }
    var lists: [(Bool, Int)] { allBlocks.compactMap { if case .list(let ordered, let items) = $0 { (ordered, items.count) } else { nil } } }
}

struct DocumentFixtureTests {
    @Test func readsWordDocument() throws {
        let document = try DOCXReader.read(url: TestSupport.fixture("sample.docx"))
        #expect(document.metadata.title == "Quarterly Report")
        #expect(document.metadata.author == "Ada Lovelace")
        #expect(document.headings.map(\.1) == ["Quarterly Report", "Highlights"])
        #expect(document.headings.map(\.0) == [1, 2])
        #expect(document.allRuns.contains { $0.text == "twelve percent" && $0.style.bold })
        #expect(document.allRuns.contains { $0.text == "flat" && $0.style.italic })
        #expect(document.lists.contains { !$0.0 && $0.1 == 2 })
        #expect(document.lists.contains { $0.0 && $0.1 == 2 })
        let table = try #require(document.tables.first)
        #expect(table.rows.count == 3)
        #expect(table.rows[1][0].first?.plainText == "EMEA")
        #expect(document.plainText.contains("Ünïcödé & <special> \"chars\" — done."))
    }

    @Test func readsOpenDocumentText() throws {
        let document = try ODTReader.read(url: TestSupport.fixture("sample.odt"))
        #expect(document.headings.map(\.1) == ["Field Notes", "Observations"])
        #expect(document.allRuns.contains { $0.text == "quick" && $0.style.bold })
        #expect(document.allRuns.contains { $0.text == "fox" && $0.style.italic })
        #expect(document.plainText.contains("The quick brown fox jumps."))
        #expect(document.lists.first?.1 == 2)
        #expect(document.tables.first?.rows.count == 2)
    }

    @Test func readsRichText() throws {
        let document = try RTFReader.read(url: TestSupport.fixture("sample.rtf"))
        #expect(document.plainText.contains("Travel Log"))
        #expect(document.allRuns.contains { $0.text.contains("Kyoto") && $0.style.bold })
        #expect(document.allRuns.contains { $0.text.contains("Osaka") && $0.style.italic })
        #expect(document.headings.contains { $0.1 == "Travel Log" })
        #expect(document.lists.first?.1 == 2)
    }

    @Test func readsPowerPointText() throws {
        let document = try PPTXReader.read(url: TestSupport.fixture("sample.pptx"))
        #expect(document.headings.map(\.1) == ["Launch Plan", "Goals"])
        #expect(document.plainText.contains("Grow to 1M users"))
        #expect(document.blocks.contains(.pageBreak))
        #expect(PPTXReader.slideCount(url: try TestSupport.fixture("sample.pptx")) == 2)
    }
}

struct DocumentRoundTripTests {
    static let writableTextFormats: [FileFormat] = [.docx, .odt, .rtf, .html, .markdown, .epub, .txt]

    @MainActor
    @Test(arguments: writableTextFormats)
    func roundTripsContent(format: FileFormat) async throws {
        let url = TestSupport.tempURL(format.fileExtension)
        try await DocumentConverter.write(TestSupport.sampleDocument, as: format, options: .default, to: url)
        let back = try DocumentConverter.read(url, format: format)
        let text = back.plainText
        for needle in ["Sample Title", "Apples", "Nested two", "Nuts & washers", "42", "To be or not to be.", "Ünïcödé", "😀", "<tags>"] {
            #expect(text.contains(needle), "\(format) lost “\(needle)”")
        }
        guard format != .txt else { return }
        #expect(back.allRuns.contains { $0.text.contains("bold") && $0.style.bold }, "\(format) lost bold")
        #expect(back.allRuns.contains { $0.text.contains("italic") && $0.style.italic }, "\(format) lost italic")
        if format != .rtf {
            #expect(back.headings.map(\.1).contains("Lists"), "\(format) lost headings")
            #expect(back.allRuns.contains { $0.style.link == "https://example.com" }, "\(format) lost link")
            let table = try #require(back.tables.first, "\(format) lost table")
            #expect(table.rows.count == 3)
            #expect(back.lists.contains { $0.0 == false && $0.1 == 2 }, "\(format) lost bullet list")
            #expect(back.lists.contains { $0.0 == true && $0.1 == 2 }, "\(format) lost nested ordered list")
        }
    }

    @MainActor
    @Test func writesPaginatedPDFWithSettings() async throws {
        var options = DocumentExportOptions()
        options.pageSize = .letter
        options.orientation = .landscape
        options.pageNumbers = true
        let long = RichDocument(blocks: (1 ... 120).map { .paragraph(runs: [Run("Paragraph number \($0) with enough words to wrap around the line at least once in landscape.")]) })
        let url = TestSupport.tempURL("pdf")
        try await DocumentConverter.write(long, as: .pdf, options: options, to: url)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.pageCount > 2)
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 792) < 1 && abs(bounds.height - 612) < 1)
        #expect(pdf.string?.contains("Paragraph number 120") == true)
    }

    @MainActor
    @Test func docxToPDFKeepingOriginalLayout() async throws {
        let url = TestSupport.tempURL("pdf")
        try await DocumentConverter.convert(input: TestSupport.fixture("sample.docx"), from: .docx, to: .pdf, layout: .original, output: url)
        let pdf = try #require(PDFDocument(url: url))
        #expect(pdf.string?.contains("twelve percent") == true)
    }

    @MainActor
    @Test func pdfToWordRecoversStructure() async throws {
        let pdfURL = TestSupport.tempURL("pdf")
        try await DocumentConverter.write(TestSupport.sampleDocument, as: .pdf, options: .default, to: pdfURL)
        let docxURL = TestSupport.tempURL("docx")
        try await DocumentConverter.convert(input: pdfURL, from: .pdf, to: .docx, output: docxURL)
        let back = try DOCXReader.read(url: docxURL)
        #expect(back.headings.contains { $0.1.contains("Sample Title") })
        #expect(back.plainText.contains("Apples"))
        #expect(back.allRuns.contains { $0.text.contains("bold") && $0.style.bold })
    }

    @Test func docxImagesSurviveRoundTrip() throws {
        let png = try ImageToolkit.encode(TestSupport.makeImage(width: 40, height: 20), as: .png)
        let document = RichDocument(blocks: [.paragraph(runs: [Run("Figure")]), .image(ImageBlock(data: png, mimeType: "image/png", size: nil, altText: "chart"))])
        for (writer, reader, ext) in [
            ({ (url: URL) in try DOCXWriter.write(document, to: url) }, { try DOCXReader.read(url: $0) }, "docx"),
            ({ (url: URL) in try ODTWriter.write(document, to: url) }, { try ODTReader.read(url: $0) }, "odt"),
            ({ (url: URL) in try EPUBWriter.write(document, to: url) }, { try EPUBReader.read(url: $0) }, "epub")
        ] as [((URL) throws -> Void, (URL) throws -> RichDocument, String)] {
            let url = TestSupport.tempURL(ext)
            try writer(url)
            let back = try reader(url)
            let image = back.allBlocks.compactMap { if case .image(let image) = $0 { image } else { nil } }.first
            #expect(image?.data == png, "\(ext) lost the image")
        }
    }

    @Test func odtPackageStartsWithStoredMimetype() throws {
        let url = TestSupport.tempURL("odt")
        try ODTWriter.write(TestSupport.sampleDocument, to: url)
        let bytes = try Data(contentsOf: url)
        // Local file header: name at offset 30, compression method at offset 8 (0 = stored).
        #expect(String(decoding: bytes[30 ..< 38], as: UTF8.self) == "mimetype")
        #expect(bytes[8] == 0 && bytes[9] == 0)
        #expect(String(decoding: bytes[38 ..< 77], as: UTF8.self) == ODTWriter.mimeType)
    }

    @Test func epubHasValidPackageStructure() throws {
        let url = TestSupport.tempURL("epub")
        var document = TestSupport.sampleDocument
        document.blocks += [.heading(level: 1, runs: [Run("Second Chapter")]), .paragraph(runs: [Run("More text.")])]
        try EPUBWriter.write(document, to: url)
        let package = try ZipPackageReader(url: url)
        #expect(package.entryPaths.first == "mimetype")
        #expect(package.contains("OEBPS/nav.xhtml"))
        #expect(package.contains("OEBPS/chapter2.xhtml"))
        // Chapters must be well-formed XML for strict readers.
        _ = try package.xml(at: "OEBPS/chapter1.xhtml")
        _ = try package.xml(at: "OEBPS/content.opf")
        let back = try EPUBReader.read(url: url)
        #expect(back.metadata.title == "Sample Title")
        #expect(back.metadata.author == "Grace Hopper")
    }

    @Test func docxPageNumbersAddFooterPart() throws {
        var options = DocumentExportOptions()
        options.pageNumbers = true
        let url = TestSupport.tempURL("docx")
        try DOCXWriter.write(TestSupport.sampleDocument, options: options, to: url)
        let package = try ZipPackageReader(url: url)
        #expect(package.contains("word/footer1.xml"))
        let document = String(decoding: try package.data(at: "word/document.xml"), as: UTF8.self)
        #expect(document.contains("footerReference"))
        // Every XML part must parse.
        for path in package.entryPaths where path.hasSuffix(".xml") || path.hasSuffix(".rels") {
            _ = try package.xml(at: path)
        }
    }
}

struct MarkdownAndHTMLTests {
    @Test func parsesCommonMarkdown() {
        let markdown = """
        ---
        title: Notes
        ---
        # Heading *one*

        Some **bold**, _italic_, `code`, ~~gone~~ and [a link](https://a.b/c "t").
        Line two of same paragraph.

        - one
        - two
          1. inner
          2. inner2
        - three

        > quoted
        > text

        ```swift
        let a = 1
        ```

        | A | B |
        |---|:-:|
        | 1 | x \\| y |

        ***
        Setext
        ======
        """
        let document = MarkdownReader.read(markdown: markdown)
        #expect(document.metadata.title == "Notes")
        #expect(document.headings.map(\.0) == [1, 1])
        #expect(document.headings.first?.1 == "Heading one")
        let runs = document.allRuns
        #expect(runs.contains { $0.text == "bold" && $0.style.bold })
        #expect(runs.contains { $0.text == "italic" && $0.style.italic })
        #expect(runs.contains { $0.text == "code" && $0.style.code })
        #expect(runs.contains { $0.text == "gone" && $0.style.strikethrough })
        #expect(runs.contains { $0.text == "a link" && $0.style.link == "https://a.b/c" })
        #expect(document.plainText.contains("and a link. Line two"))
        #expect(document.lists.contains { $0 == (false, 3) })
        #expect(document.lists.contains { $0 == (true, 2) })
        #expect(document.allBlocks.contains(.code("let a = 1")))
        #expect(document.allBlocks.contains(.rule))
        let table = try? #require(document.tables.first)
        #expect(table?.hasHeaderRow == true)
        #expect(table?.rows[1][1].first?.plainText == "x | y")
        #expect(document.allBlocks.contains { if case .quote = $0 { true } else { false } })
    }

    @Test func markdownWriterEscapesAndReparses() {
        let document = RichDocument(blocks: [.paragraph(runs: [Run("Use *stars* and _underscores_ [literally]")]), .paragraph(runs: [Run("- not a list")])])
        let reparsed = MarkdownReader.read(markdown: MarkdownWriter.render(document))
        #expect(reparsed.plainText == document.plainText)
        #expect(reparsed.lists.isEmpty)
    }

    @Test func parsesTagSoupHTML() {
        let html = """
        <html><head><title>Page &amp; Title</title><meta name="author" content="Ann"><style>p{}</style><script>var x="<p>no</p>";</script></head>
        <body><h2>Intro</h2><p>Hello <b>bold <i>both</i></b> &copy; 2026<br>next line<p>Second para <a href="/x">link</a>
        <ul><li>One<li>Two<ul><li>Deep</ul></ul>
        <table><tr><th>H1<th>H2<tr><td>a<td>b</table>
        <div style="text-align:center">Centered</div><!-- comment --><pre>  code
          block</pre><img src="data:image/png;base64,iVBORw0KGgo=" alt="pic"></body></html>
        """
        let document = HTMLReader.read(html: html)
        #expect(document.metadata.title == "Page & Title")
        #expect(document.metadata.author == "Ann")
        #expect(document.headings.first?.1 == "Intro")
        #expect(document.allRuns.contains { $0.text.contains("both") && $0.style.bold && $0.style.italic })
        #expect(document.plainText.contains("© 2026\nnext line"))
        #expect(!document.plainText.contains("no</p>"))
        #expect(document.allRuns.contains { $0.style.link == "/x" })
        #expect(document.lists.contains { $0 == (false, 2) })
        #expect(document.tables.first?.hasHeaderRow == true)
        #expect(document.tables.first?.rows.count == 2)
        #expect(document.allBlocks.contains(.code("  code\n  block")))
        #expect(document.blocks.contains { if case .paragraph(let runs, .center) = $0 { runs.plainText == "Centered" } else { false } })
    }

    @Test func decodesEntities() {
        #expect(HTMLEntities.decode("&lt;a&gt; &#169; &#x1F600; &unknown; &amp;") == "<a> © 😀 &unknown; &")
    }

    @Test func plainTextParagraphsAndPageBreaks() {
        let document = PlainTextReader.read(text: "Line one\nline two\n\n\nNext\u{0C}After")
        #expect(document.blocks.count == 4)
        #expect(document.blocks[2] == .pageBreak)
    }

    @Test func rtfEscapingRoundTrips() {
        let original = "Braces {} back\\slash ünï 😀"
        #expect(RTFWriter.unescape(RTFWriter.escape(original)) == original)
    }
}

struct XMLAndZipTests {
    @Test func parsesNamespacedXML() throws {
        let root = try XMLDocumentParser.parse("<w:doc xmlns:w=\"x\"><w:p w:val=\"1\">a<w:r>b</w:r>c</w:p><![CDATA[<raw>]]></w:doc>")
        #expect(root.localName == "doc")
        #expect(root.child("p")?.attribute("val") == "1")
        #expect(root.child("w:p")?.text == "abc")
        #expect(root.text == "abc<raw>")
    }

    @Test func rejectsMalformedXML() {
        #expect(throws: DocumentError.self) { try XMLDocumentParser.parse("<a><b></a>") }
    }

    @Test func escapesXMLSpecials() {
        #expect(XMLEscaping.escape("a<b>&\"'\u{1}") == "a&lt;b&gt;&amp;&quot;&apos;")
    }

    @Test func zipWriterAndReaderRoundTrip() throws {
        let writer = ZipPackageWriter()
        writer.add("a.txt", string: "hello")
        writer.add("dir/b.bin", data: Data([0, 1, 2, 255]), compressed: false)
        let url = TestSupport.tempURL("zip")
        try writer.write(to: url)
        let reader = try ZipPackageReader(url: url)
        #expect(reader.entryPaths == ["a.txt", "dir/b.bin"])
        #expect(try reader.data(at: "a.txt") == Data("hello".utf8))
        #expect(try reader.data(at: "/dir/b.bin") == Data([0, 1, 2, 255]))
        #expect(ZipPackageReader.resolve("../media/x.png", against: "word/sub/document.xml") == "word/media/x.png")
    }
}
