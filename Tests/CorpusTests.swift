import Foundation
import ImageIO
import PDFKit
import Testing
import UIKit
import WebKit
@testable import Converter

/// Real-world PDFs (see `Fixtures/Corpus/README.md`) run through every PDF tool and conversion.
/// Each test states what a user would check by eye — the output looks like the source, keeps its
/// text and pictures — and compares renders against the source PDF rather than stored goldens,
/// so results stay valid across iOS versions.
enum Corpus {
    struct Document: CustomTestStringConvertible, Sendable {
        let name: String
        let pages: Int
        /// A phrase from the body that every text-bearing output must keep.
        let phrase: String
        /// A second phrase from a later page (checks page order and that later pages survive).
        let laterPhrase: String
        let hasForm: Bool
        let minImages: Int

        var url: URL {
            get throws {
                guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: nil, subdirectory: "Corpus") else {
                    throw DocumentError.unreadable("Missing corpus file \(name)")
                }
                return url
            }
        }

        var testDescription: String { name }
    }

    static let documents: [Document] = [
        Document(name: "fda-nutrition-label.pdf", pages: 1, phrase: "Nutrition Facts", laterPhrase: "Serving sizes", hasForm: false, minImages: 0),
        Document(name: "usgs-streamstats.pdf", pages: 4, phrase: "StreamStats", laterPhrase: "References Cited", hasForm: false, minImages: 2),
        Document(name: "usgs-east-carroll.pdf", pages: 6, phrase: "East Carroll Parish", laterPhrase: "References Cited", hasForm: false, minImages: 1),
        Document(name: "irs-w4-form.pdf", pages: 5, phrase: "Employee’s Withholding Certificate", laterPhrase: "Deductions Worksheet", hasForm: true, minImages: 0),
        Document(name: "irs-w9-form.pdf", pages: 6, phrase: "Request for Taxpayer", laterPhrase: "Privacy Act Notice", hasForm: true, minImages: 0),
        Document(name: "irs-p1544.pdf", pages: 6, phrase: "Reporting Cash Payments", laterPhrase: "How To Get Tax Help", hasForm: false, minImages: 0)
    ]

    static func input(_ document: Document) throws -> ToolInputFile {
        let copy = TestSupport.tempURL("pdf").deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let url = copy.appendingPathComponent(document.name)
        try FileManager.default.copyItem(at: try document.url, to: url)
        return try ToolInputFile(url: url)
    }

    @MainActor
    static func run(_ id: ToolID, _ inputs: [ToolInputFile], _ overrides: [String: OptionValue] = [:], editor: ToolEditorState = .none) async throws -> ToolOutput {
        let tool = try #require(ToolCatalog.tool(id))
        var options = ToolOptionValues(defaults: tool.options)
        for option in tool.options {
            if case .dynamicChoice(let provider) = option.kind { options[option.key] = .string(provider(inputs).first?.value ?? "") }
        }
        for (key, value) in overrides { options[key] = value }
        return try await tool.run(ToolContext(inputs: inputs, options: options, editor: editor))
    }

    static func text(_ url: URL) -> String {
        normalize(PDFDocument(url: url)?.string ?? "")
    }

    /// PDF text extraction varies in whitespace and quote style; compare on a normalized form.
    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00AD}", with: "")
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            .lowercased()
    }

    /// Text a reader would see or select: tags removed, each element on its own line.
    static func visibleText(ofHTML html: String) -> String {
        var text = html
        for block in ["<script[\\s\\S]*?</script>", "<style[\\s\\S]*?</style>", "<img[^>]*>"] {
            text = text.replacingOccurrences(of: block, with: " ", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "<[^>]+>", with: "\n", options: .regularExpression)
        for (entity, character) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'")] {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        return text
    }

    static func contains(_ haystack: String, _ phrase: String) -> Bool {
        normalize(haystack).contains(normalize(phrase))
    }

    static func render(_ page: PDFPage, dpi: CGFloat = 50) throws -> CGImage {
        try #require(PDFRasterizer.image(page: page, dpi: dpi))
    }
}

// MARK: - Reading and rendering

@Suite(.timeLimit(.minutes(3)))
struct CorpusReadingTests {
    @Test(arguments: Corpus.documents)
    func opensWithExpectedPagesAndText(_ document: Corpus.Document) throws {
        let pdf = try #require(PDFDocument(url: try document.url))
        #expect(pdf.pageCount == document.pages)
        let text = pdf.string ?? ""
        #expect(Corpus.contains(text, document.phrase), "\(document.name) text lacks “\(document.phrase)”")
        #expect(Corpus.contains(text, document.laterPhrase), "\(document.name) text lacks “\(document.laterPhrase)”")
    }

    @Test(arguments: Corpus.documents)
    func everyPageRendersWithContent(_ document: Corpus.Document) throws {
        let pdf = try #require(PDFDocument(url: try document.url))
        for index in 0 ..< pdf.pageCount {
            let image = try Corpus.render(try #require(pdf.page(at: index)), dpi: 40)
            #expect(ImageStats(image, side: 160).inkFraction > 0.005, "\(document.name) page \(index + 1) renders blank")
        }
    }

    @Test(arguments: Corpus.documents)
    func readerRecoversTextAndPictures(_ document: Corpus.Document) throws {
        let pdf = try #require(PDFDocument(url: try document.url))
        let rich = PDFTextReader.read(document: pdf)
        #expect(Corpus.contains(rich.plainText, document.phrase))
        #expect(Corpus.contains(rich.plainText, document.laterPhrase))
        #expect(rich.allImages.count >= document.minImages, "\(document.name): reader kept \(rich.allImages.count) pictures")
    }
}

// MARK: - Image extraction

@Suite(.timeLimit(.minutes(3)))
struct CorpusImageTests {
    @Test(arguments: Corpus.documents)
    func extractedImagesLookLikeThePage(_ document: Corpus.Document) throws {
        let pdf = try #require(PDFDocument(url: try document.url))
        let placed = PDFPageImages.images(in: pdf, minimumSide: 64)
        #expect(placed.count >= document.minImages, "\(document.name): found \(placed.count) images")
        for image in placed {
            let decoded = try #require(CGImageSourceCreateWithData(image.image.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
            let stats = ImageStats(decoded)
            #expect(!stats.isFullyTransparent, "\(document.name): an extracted image is fully transparent")
            #expect(stats.spread > 4, "\(document.name): an extracted image is a flat color \(stats.mean)")

            // Large, unrotated pictures must match the page where they're painted. Text or shapes
            // drawn on top add some difference; inverted or black-boxed colors add far more.
            // Compare only the part clipping leaves visible.
            // Page-sized backgrounds can be painted over by the layout (USGS covers a full-page photo
            // with a white panel); conversions skip them, so only compare pictures that are content.
            guard let rect = image.visibleRect, rect.width > 120, rect.height > 120, image.isUpright,
                  let pageBox = pdf.page(at: image.pageIndex)?.bounds(for: .cropBox),
                  rect.width * rect.height < pageBox.width * pageBox.height * 0.85,
                  let pixelCrop = image.visiblePixelRect, let shown = decoded.cropping(to: pixelCrop),
                  let page = pdf.page(at: image.pageIndex), page.rotation == 0 else { continue }
            let box = page.bounds(for: .cropBox)
            let pageImage = try Corpus.render(page, dpi: 72)
            let scale = CGFloat(pageImage.width) / box.width
            let crop = CGRect(x: (rect.minX - box.minX) * scale, y: (box.maxY - rect.maxY) * scale, width: rect.width * scale, height: rect.height * scale).integral
            guard let region = pageImage.cropping(to: crop) else { continue }
            let difference = Look.difference(shown, region)
            #expect(difference < 45, "\(document.name) page \(image.pageIndex + 1): extracted picture differs from the page by \(difference)")
        }
    }

    @MainActor
    @Test func extractImagesToolSavesEveryPicture() async throws {
        let document = Corpus.documents.first { $0.name == "usgs-streamstats.pdf" }!
        let output = try await Corpus.run("pdf.extractimages", [try Corpus.input(document)])
        #expect(output.files.count >= document.minImages)
        for file in output.files {
            #expect(await OutputValidator.problems(in: file.url).isEmpty)
        }
    }
}

// MARK: - Conversions

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct CorpusConversionTests {
    static let editableTargets: [FileFormat] = [.docx, .odt, .epub, .rtf, .markdown, .txt]

    @Test(arguments: Corpus.documents)
    func editableFormatsKeepTextAndPictures(_ document: Corpus.Document) async throws {
        let input = try Corpus.input(document)
        for target in Self.editableTargets {
            let output = try await Corpus.run("convert.any", [input], ["target": .string(target.rawValue)])
            let main = try #require(output.files.first { $0.format == target }, "\(document.name) → \(target): no \(target) file")
            let back = try DocumentConverter.read(main.url, format: target)
            #expect(Corpus.contains(back.plainText, document.phrase), "\(document.name) → \(target) lost “\(document.phrase)”")
            #expect(Corpus.contains(back.plainText, document.laterPhrase), "\(document.name) → \(target) lost “\(document.laterPhrase)”")
            let pictures = target == .markdown
                ? output.files.filter { $0.format?.family == .image }.count
                : back.allImages.count
            if [.docx, .odt, .epub, .markdown].contains(target) {
                #expect(pictures >= document.minImages, "\(document.name) → \(target) kept \(pictures) pictures")
            }
        }
    }

    @Test(arguments: Corpus.documents)
    func reflowableHTMLKeepsTextAndPictures(_ document: Corpus.Document) async throws {
        let output = try await Corpus.run("convert.pdf.html", [try Corpus.input(document)], ["htmlLayout": .string("reflow")])
        let html = try String(contentsOf: try #require(output.files.first).url, encoding: .utf8)
        #expect(Corpus.contains(Corpus.visibleText(ofHTML: html), document.phrase))
        #expect(html.components(separatedBy: "<img").count - 1 >= document.minImages)
    }

    /// The exact-copy HTML, rendered by WebKit, must look like the PDF page.
    @Test(arguments: Corpus.documents)
    func exactHTMLLooksLikeThePDF(_ document: Corpus.Document) async throws {
        let output = try await Corpus.run("convert.pdf.html", [try Corpus.input(document)], ["htmlLayout": .string("exact")])
        let url = try #require(output.files.first).url
        let html = try String(contentsOf: url, encoding: .utf8)
        #expect(Corpus.contains(Corpus.visibleText(ofHTML: html), document.phrase), "Text must stay selectable/searchable")
        #expect(html.components(separatedBy: "<section class=\"page\"").count - 1 == document.pages)

        let pdf = try #require(PDFDocument(url: try document.url))
        let page = try #require(pdf.page(at: 0))
        let webImage = try await WebSnapshot.firstPage(of: url)
        let pdfImage = try Corpus.render(page, dpi: 96)
        let difference = Look.difference(webImage, pdfImage)
        #expect(difference < 12, "\(document.name): exact HTML differs from the PDF by \(difference)")
    }

    @Test(arguments: Corpus.documents.filter { $0.minImages == 0 }.prefix(2))
    func spreadsheetsRecoverRows(_ document: Corpus.Document) async throws {
        let output = try await Corpus.run("convert.pdf.xlsx", [try Corpus.input(document)])
        let workbook = try SpreadsheetConverter.read(try #require(output.files.first).url, format: .xlsx)
        #expect(!workbook.isEmpty)
        #expect(Corpus.contains(workbook.asDocument().plainText, document.phrase))
    }
}

// MARK: - Page tools

@Suite(.timeLimit(.minutes(5)))
@MainActor
struct CorpusPageToolTests {
    static func pdf(_ output: ToolOutput, _ index: Int = 0) throws -> PDFDocument {
        try #require(PDFDocument(url: output.files[index].url))
    }

    /// Output page `index` must look like source page `sourceIndex`.
    static func expectSameLook(_ output: PDFDocument, _ index: Int, as source: PDFDocument, _ sourceIndex: Int, tolerance: Double = 8, _ label: String) throws {
        let a = try Corpus.render(try #require(output.page(at: index)))
        let b = try Corpus.render(try #require(source.page(at: sourceIndex)))
        let difference = Look.difference(a, b)
        #expect(difference < tolerance, "\(label): page \(index + 1) differs from source page \(sourceIndex + 1) by \(difference)")
    }

    @Test(arguments: Corpus.documents)
    func compressKeepsLookAndText(_ document: Corpus.Document) async throws {
        let source = try #require(PDFDocument(url: try document.url))
        let output = try await Corpus.run("pdf.compress", [try Corpus.input(document)])
        let result = try Self.pdf(output)
        #expect(result.pageCount == document.pages)
        try Self.expectSameLook(result, 0, as: source, 0, tolerance: 10, "\(document.name) compress")
        #expect(Corpus.contains(result.string ?? "", document.phrase), "Compression must keep text searchable")
        let before = try FileManager.default.attributesOfItem(atPath: try document.url.path)[.size] as? Int64 ?? 0
        #expect(output.files[0].byteCount <= max(before, 1) * 11 / 10, "\(document.name): compressed file grew from \(before) to \(output.files[0].byteCount)")
    }

    @Test(arguments: Corpus.documents)
    func pageOrderToolsMoveTheRightPages(_ document: Corpus.Document) async throws {
        let input = try Corpus.input(document)
        let source = try #require(PDFDocument(url: input.url))
        let count = document.pages

        let reversed = try Self.pdf(try await Corpus.run("pdf.reverse", [input]))
        #expect(reversed.pageCount == count)
        try Self.expectSameLook(reversed, 0, as: source, count - 1, "\(document.name) reverse")

        let rotated = try Self.pdf(try await Corpus.run("pdf.rotate", [input], ["angle": .string("90")]))
        #expect((0 ..< rotated.pageCount).allSatisfy { rotated.page(at: $0)!.rotation % 360 == (source.page(at: $0)!.rotation + 90) % 360 })

        guard count >= 2 else { return }
        let extracted = try Self.pdf(try await Corpus.run("pdf.extract", [input], ["pages": .string("\(count),1")]))
        #expect(extracted.pageCount == 2)
        try Self.expectSameLook(extracted, 0, as: source, count - 1, "\(document.name) extract")
        try Self.expectSameLook(extracted, 1, as: source, 0, "\(document.name) extract")

        let deleted = try Self.pdf(try await Corpus.run("pdf.delete", [input], ["pages": .string("1")]))
        #expect(deleted.pageCount == count - 1)
        try Self.expectSameLook(deleted, 0, as: source, 1, "\(document.name) delete")

        let split = try await Corpus.run("pdf.split", [input], ["mode": .string("each")])
        #expect(split.files.count == count)
        #expect(split.files.compactMap { PDFDocument(url: $0.url)?.pageCount }.allSatisfy { $0 == 1 })
    }

    @Test func mergeCombinesDocumentsInOrder() async throws {
        let first = Corpus.documents[0], second = Corpus.documents[4]
        let output = try await Corpus.run("pdf.merge", [try Corpus.input(first), try Corpus.input(second)])
        let merged = try Self.pdf(output)
        #expect(merged.pageCount == first.pages + second.pages)
        let firstSource = try #require(PDFDocument(url: try first.url)), secondSource = try #require(PDFDocument(url: try second.url))
        try Self.expectSameLook(merged, 0, as: firstSource, 0, "merge")
        try Self.expectSameLook(merged, first.pages, as: secondSource, 0, "merge")
    }

    @Test(arguments: Corpus.documents)
    func stampsKeepTheOriginalUnderneath(_ document: Corpus.Document) async throws {
        let input = try Corpus.input(document)
        let source = try #require(PDFDocument(url: input.url))

        let watermarked = try Self.pdf(try await Corpus.run("pdf.watermark", [input], ["text": .string("DRAFT COPY")]))
        #expect(Corpus.contains(watermarked.string ?? "", "DRAFT COPY"))
        #expect(Corpus.contains(watermarked.string ?? "", document.phrase))
        try Self.expectSameLook(watermarked, 0, as: source, 0, tolerance: 20, "\(document.name) watermark")

        let numbered = try Self.pdf(try await Corpus.run("pdf.pagenumbers", [input]))
        #expect(Corpus.contains(numbered.string ?? "", document.phrase))
        try Self.expectSameLook(numbered, 0, as: source, 0, tolerance: 6, "\(document.name) page numbers")
    }

    @Test(arguments: Corpus.documents)
    func grayscaleAndFlattenKeepContent(_ document: Corpus.Document) async throws {
        let input = try Corpus.input(document)
        let source = try #require(PDFDocument(url: input.url))

        let gray = try Self.pdf(try await Corpus.run("pdf.grayscale", [input]))
        #expect(gray.pageCount == document.pages)
        #expect(Corpus.contains(gray.string ?? "", document.phrase), "Grayscale must keep text")
        let grayImage = try Corpus.render(try #require(gray.page(at: 0)))
        let pixels = ImageStats.pixels(grayImage, side: 64)
        var maxChroma = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            maxChroma = max(maxChroma, max(r, g, b) - min(r, g, b))
        }
        #expect(maxChroma < 12, "\(document.name): grayscale page still has color (\(maxChroma))")

        let flattened = try Self.pdf(try await Corpus.run("pdf.flatten", [input]))
        #expect(flattened.pageCount == document.pages)
        try Self.expectSameLook(flattened, 0, as: source, 0, tolerance: 8, "\(document.name) flatten")
        if document.hasForm {
            let widgets = (0 ..< flattened.pageCount).flatMap { flattened.page(at: $0)!.annotations }.filter { $0.type == "Widget" }
            #expect(widgets.isEmpty, "\(document.name): \(widgets.count) form fields survived flattening")
        }
    }

    @Test(arguments: Corpus.documents)
    func redactionRemovesOnlyTheTerm(_ document: Corpus.Document) async throws {
        let input = try Corpus.input(document)
        let output = try await Corpus.run("pdf.redact", [input], ["terms": .string(document.phrase)])
        let text = Corpus.text(output.files[0].url)
        #expect(!text.contains(Corpus.normalize(document.phrase)), "\(document.name): “\(document.phrase)” survived redaction")
        #expect(text.contains(Corpus.normalize(document.laterPhrase)), "\(document.name): unrelated text was lost")
    }

    @Test(arguments: Corpus.documents.prefix(3))
    func protectAndUnlockRoundTrip(_ document: Corpus.Document) async throws {
        let protected = try await Corpus.run("pdf.protect", [try Corpus.input(document)], ["password": .string("s3cret"), "confirm": .string("s3cret")])
        let locked = try #require(PDFDocument(url: protected.files[0].url))
        #expect(locked.isLocked)
        #expect(locked.unlock(withPassword: "s3cret"))
        #expect(Corpus.contains(locked.string ?? "", document.phrase))

        let unlocked = try await Corpus.run("pdf.unlock", [try ToolInputFile(url: protected.files[0].url)], ["password": .string("s3cret")])
        let open = try Self.pdf(unlocked)
        #expect(!open.isEncrypted && open.pageCount == document.pages)
    }

    @Test(arguments: Corpus.documents.prefix(3))
    func pagesToImagesMatchThePages(_ document: Corpus.Document) async throws {
        let source = try #require(PDFDocument(url: try document.url))
        let output = try await Corpus.run("pdf.toimages", [try Corpus.input(document)], ["format": .string("png"), "dpi": .string("72")])
        #expect(output.files.count == document.pages)
        for (index, file) in output.files.enumerated() {
            let image = try ImageToolkit.load(file.url)
            let difference = Look.difference(image, try Corpus.render(try #require(source.page(at: index))))
            #expect(difference < 6, "\(document.name) page \(index + 1) image differs by \(difference)")
        }
    }

    @Test func ocrMakesARasterizedPageSearchableAgain() async throws {
        let document = Corpus.documents.first { $0.name == "irs-p1544.pdf" }!
        let source = try #require(PDFDocument(url: try document.url))
        let page = try #require(source.page(at: 0))
        let scan = try TestSupport.writeImage(try Corpus.render(page, dpi: 200), format: .png)
        let scanned = try await Corpus.run("pdf.fromimages", [try ToolInputFile(url: scan)])
        #expect(!PDFToolkit.hasTextLayer(try Self.pdf(scanned)))
        let output = try await Corpus.run("pdf.ocr", [try ToolInputFile(url: scanned.files[0].url)])
        #expect(Corpus.contains(Corpus.text(output.files[0].url), "Reporting Cash Payments"))
    }
}
