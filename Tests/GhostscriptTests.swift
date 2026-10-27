import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import Converter

/// Ghostscript-backed features, checked on real output: what the pages look like, what text they
/// keep, and that hostile PostScript can't reach outside the files it was given.
@MainActor
struct GhostscriptTests {
    private func write(_ text: String, _ ext: String) throws -> URL {
        let url = TestSupport.tempURL(ext)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func firstPDF(_ urls: [URL]) throws -> PDFDocument {
        let url = try #require(urls.first)
        return try #require(PDFDocument(url: url))
    }

    private func convert(_ url: URL, to target: FileFormat) async throws -> [URL] {
        let context = ToolContext(inputs: [], options: ToolOptionValues())
        return try await ConversionEngine.convert(try ToolInputFile(url: url), to: target, settings: .init(), context: context)
    }

    @Test func bundlesPinnedVersion() {
        #expect(Ghostscript.isAvailable)
        #expect(Ghostscript.version == "10.08.0")
    }

    // MARK: PostScript in

    @Test func epsBecomesCroppedVectorPDF() async throws {
        let eps = try write(SelfTestFixtures.epsArtwork, "eps")
        #expect(ConversionTargets.targets(for: .eps).first == .pdf)
        let outputs = try await convert(eps, to: .pdf)
        let pdf = try firstPDF(outputs)
        let page = try #require(pdf.page(at: 0))
        let box = page.bounds(for: .mediaBox)
        // Cropped to the 200 × 120 pt bounding box, not a whole Letter page.
        #expect(abs(box.width - 200) < 1.5 && abs(box.height - 120) < 1.5, "page is \(box.size)")
        #expect((page.string ?? "").contains("Hello EPS"), "EPS text must stay text")
    }

    @Test func epsRendersSharpPNG() async throws {
        let eps = try write(SelfTestFixtures.epsArtwork, "eps")
        let png = try #require(try await convert(eps, to: .png).first)
        let pixels = try PixelProbe(try Data(contentsOf: png))
        // 200 × 120 pt artwork at 300 dpi.
        #expect(abs(pixels.width - 833) <= 2 && abs(pixels.height - 500) <= 2, "\(pixels.width)×\(pixels.height)")
        let card = pixels.at(0.9, 0.9)
        #expect(card.b > 150 && card.r < 80 && card.a == 255, "card should be opaque blue, got \(card)")
        let line = pixels.at(0.5, 0.5)
        #expect(line.r < 60 && line.g < 60 && line.b < 60, "the diagonal crosses the middle, got \(line)")
    }

    @Test func epsToJPEGAndWebP() async throws {
        let eps = try write(SelfTestFixtures.epsArtwork, "eps")
        for target in [FileFormat.jpeg, .webp] {
            let url = try #require(try await convert(eps, to: target).first)
            #expect(url.pathExtension == target.fileExtension)
            let card = try PixelProbe(try Data(contentsOf: url)).at(0.9, 0.9)
            #expect(card.b > 140 && card.r < 90, "\(target): \(card)")
        }
    }

    @Test func multiPagePostScriptDocument() async throws {
        let ps = try write(SelfTestFixtures.postScriptDocument(pages: 2), "ps")
        let pdf = try firstPDF(try await convert(ps, to: .pdf))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        #expect((pdf.page(at: 1)?.string ?? "").contains("PostScript page 2"))

        let pages = try await convert(ps, to: .png)
        #expect(pages.count == 2)
        #expect(pages.map(\.lastPathComponent).allSatisfy { $0.contains("-page-") })
        let red = try PixelProbe(try Data(contentsOf: pages[1])).at(172 / 612, 1 - 650 / 792)
        #expect(red.r > 180 && red.g < 60, "page 2's red box, got \(red)")
        let white = try PixelProbe(try Data(contentsOf: pages[1])).at(0.8, 0.8)
        #expect(white.r > 240 && white.g > 240 && white.b > 240, "documents render on white, got \(white)")
    }

    @Test func illustratorFileOpens() async throws {
        let ai = TestSupport.tempURL("ai")
        try PDFToolkit.write(TestSupport.makePDF(pages: 1, body: "Illustrator artboard"), to: ai)
        #expect(FileFormat(url: ai) == .ai)
        let pdf = try firstPDF(try await convert(ai, to: .pdf))
        #expect((pdf.string ?? "").contains("Illustrator artboard"))
    }

    // MARK: PostScript out

    // PostScript carries no Unicode text mapping, so round trips are judged by how pages look.

    @Test func pdfExportsEPSPerPageAndRoundTrips() async throws {
        let document = Corpus.documents.first { $0.name == "usgs-streamstats.pdf" }!
        let source = try #require(PDFDocument(url: try document.url))
        let epsFiles = try await convert(try document.url, to: .eps)
        #expect(epsFiles.count == 4)
        #expect(epsFiles.map(\.lastPathComponent) == (1 ... 4).map { "usgs-streamstats-page-\($0).eps" })
        for file in epsFiles {
            let header = String(decoding: try Data(contentsOf: file).prefix(40), as: UTF8.self)
            #expect(header.hasPrefix("%!PS-Adobe-3.0 EPSF-3.0"), "\(file.lastPathComponent): \(header)")
        }
        let back = try firstPDF(try await convert(epsFiles[3], to: .pdf))
        try CorpusPageToolTests.expectSameLook(back, 0, as: source, 3, tolerance: 10, "EPS page 4 round trip")
    }

    @Test func pdfExportsPostScriptAndRoundTrips() async throws {
        let document = Corpus.documents.first { $0.name == "irs-p1544.pdf" }!
        let source = try #require(PDFDocument(url: try document.url))
        let outputs = try await convert(try document.url, to: .ps)
        #expect(outputs.count == 1)
        let ps = try #require(outputs.first)
        #expect(String(decoding: try Data(contentsOf: ps).prefix(10), as: UTF8.self).hasPrefix("%!PS"))
        let back = try firstPDF(try await convert(ps, to: .pdf))
        #expect(back.pageCount == 6)
        try CorpusPageToolTests.expectSameLook(back, 0, as: source, 0, tolerance: 10, "PostScript page 1 round trip")
        try CorpusPageToolTests.expectSameLook(back, 5, as: source, 5, tolerance: 10, "PostScript page 6 round trip")
    }

    // MARK: PDF tools

    @Test func compressionKeepsVectorsTextAndLinks() async throws {
        let document = Corpus.documents.first { $0.name == "usgs-streamstats.pdf" }!
        let input = try Corpus.input(document)
        let output = try await Corpus.run("pdf.compress", [input])
        let pdf = try #require(PDFDocument(url: output.files[0].url))
        #expect(output.files[0].byteCount < input.byteCount * 6 / 10, "\(input.byteCount) → \(output.files[0].byteCount)")
        #expect((pdf.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String ?? "").contains("Ghostscript"),
                "Balanced should use the vector-preserving Ghostscript result here")
        #expect(Corpus.contains(pdf.string ?? "", "References Cited"))
        let links = (0 ..< pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }.filter { $0.type == "Link" }
        #expect(links.count == 9, "links: \(links.count)")
    }

    @Test func compressionKeepsFormFields() async throws {
        let document = Corpus.documents.first { $0.name == "irs-w4-form.pdf" }!
        let input = try Corpus.input(document)
        let source = try #require(PDFDocument(url: input.url))
        let output = try await Corpus.run("pdf.compress", [input], ["level": .string("strong")])
        let pdf = try #require(PDFDocument(url: output.files[0].url))
        func widgets(_ pdf: PDFDocument) -> Int {
            (0 ..< pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }.filter { $0.type == "Widget" }.count
        }
        #expect(widgets(pdf) == widgets(source), "fillable fields must survive compression")
    }

    @Test func grayscaleKeepsVectors() async throws {
        let document = Corpus.documents.first { $0.name == "usgs-streamstats.pdf" }!
        let output = try await Corpus.run("pdf.grayscale", [try Corpus.input(document)])
        let pdf = try #require(PDFDocument(url: output.files[0].url))
        #expect((pdf.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String ?? "").contains("Ghostscript"))
        // Rasterized pages at 150 dpi would be well over 1 MB; vector gray stays small.
        #expect(output.files[0].byteCount < 900_000, "\(output.files[0].byteCount) bytes")
        let selection = pdf.findString("StreamStats", withOptions: []).first
        #expect(selection != nil)
    }

    @Test func repairRecoversDamagedFile() async throws {
        let damaged = try SelfTestFixtures.damagedPDF()
        let output = try await Corpus.run("pdf.repair", [try ToolInputFile(url: damaged)])
        let pdf = try #require(PDFDocument(url: output.files[0].url))
        #expect(pdf.pageCount == 4)
        #expect(Corpus.contains(pdf.page(at: 3)?.string ?? "", "References Cited"))
        #expect(output.summary?.hasPrefix("Fixed") == true, "summary: \(output.summary ?? "nil")")
        // Every page must look like the undamaged report, figures included.
        let original = try #require(PDFDocument(url: try SelfTestFixtures.sample("usgs-streamstats.pdf")))
        for index in 0 ..< 4 {
            try CorpusPageToolTests.expectSameLook(pdf, index, as: original, index, tolerance: 6, "repaired page \(index + 1)")
        }
        // The rebuilt file has a sound cross-reference table: CoreGraphics opens it without repair.
        let data = try Data(contentsOf: output.files[0].url)
        let tail = String(decoding: data.suffix(64), as: UTF8.self)
        #expect(tail.contains("startxref") && !tail.contains("12345"))
    }

    @Test func repairRejectsUnrecoverableFile() async throws {
        let junk = TestSupport.tempURL("pdf")
        try Data((0 ..< 4_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }).write(to: junk)
        await #expect(throws: (any Error).self) {
            _ = try await Corpus.run("pdf.repair", [try ToolInputFile(url: junk)])
        }
    }

    @Test(arguments: [1, 2, 3])
    func pdfAHasArchivalStructure(part: Int) async throws {
        let document = Corpus.documents.first { $0.name == "irs-p1544.pdf" }!
        let output = try await Corpus.run("pdf.pdfa", [try Corpus.input(document)], ["part": .string("\(part)")])
        let url = output.files[0].url
        let data = try Data(contentsOf: url)
        #expect(data.range(of: Data("pdfaid:part='\(part)'".utf8)) != nil || data.range(of: Data("pdfaid:part=\"\(part)\"".utf8)) != nil)
        let cg = try #require(CGPDFDocument(url as CFURL))
        let catalog = try #require(cg.catalog)
        var intents: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents) && CGPDFArrayGetCount(intents!) > 0, "missing OutputIntents")
        #expect(PDFArchival.unembeddedFonts(in: cg).isEmpty, "unembedded: \(PDFArchival.unembeddedFonts(in: cg))")
        let pdf = try #require(PDFDocument(url: url))
        #expect(Corpus.contains(pdf.string ?? "", document.phrase))
        // Links survive: they're marked printable, as PDF/A requires, instead of being dropped.
        let links = (0 ..< pdf.pageCount).flatMap { pdf.page(at: $0)!.annotations }.filter { $0.type == "Link" }
        #expect(links.count == 26, "links: \(links.count)")
    }

    /// Apple's PDF writer embeds TrueType fonts without ToUnicode maps. PDF/A turns those into CIDFonts,
    /// and without the bundled patch (ToUnicode from glyph names) their text could no longer be read.
    @Test(arguments: ["pdf.pdfa", "pdf.grayscale", "pdf.compress"])
    func keepsTextOfAppleMadePDFs(tool: String) async throws {
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.write(TestSupport.makePDF(pages: 2, body: "Quarterly numbers for Page review. Account 555-0100."), to: url)
        let output = try await Corpus.run(ToolID(rawValue: tool), [try ToolInputFile(url: url)])
        let text = PDFDocument(url: output.files[0].url)?.string ?? ""
        #expect(text.contains("Quarterly numbers"), "\(tool) lost the text: “\(text.prefix(80))”")
        #expect(text.contains("555-0100"))
    }

    /// The fidelity guard must catch Ghostscript's soft-mask rewrite that Apple renders without the
    /// background (East Carroll), while passing faithful rewrites of the other corpus documents.
    @Test(arguments: Corpus.documents)
    func fidelityGuardSeparatesFaithfulRewrites(_ document: Corpus.Document) throws {
        let source = try #require(PDFDocument(url: try document.url))
        let output = TestSupport.tempURL("pdf")
        try Ghostscript.compress(try document.url, to: output, quality: .ebook)
        let rewrite = try #require(PDFDocument(url: output))
        let difference = try #require(PDFFidelity.worstPageDifference(source, rewrite))
        print("fidelity \(document.name): \(String(format: "%.2f", difference))")
        if document.name == "usgs-east-carroll.pdf" {
            #expect(!PDFFidelity.looksTheSame(source, rewrite), "difference \(difference)")
        } else {
            #expect(PDFFidelity.looksTheSame(source, rewrite), "difference \(difference)")
        }
    }

    @Test func repairReportParsesGhostscriptSummary() {
        let log = """
        Page 1

        The following errors were encountered at least once while processing this file:
        \tstartxref offset invalid
        \txref table was repaired

        The following warnings were encountered at least once while processing this file:
        \tThe file has a bad /Info dictionary

           **** This file had errors that were repaired or ignored.
        """
        #expect(Ghostscript.reportedProblems(in: log) == ["startxref offset invalid", "xref table was repaired", "The file has a bad /Info dictionary"])
        #expect(Ghostscript.reportedProblems(in: "Page 1\nPage 2\n").isEmpty)
    }

    // MARK: Safety

    @Test func postScriptCannotReadFiles() async throws {
        let secret = TestSupport.tempURL("txt")
        try Data("top secret".utf8).write(to: secret)
        let hostile = try write("""
        %!PS
        /f (\(secret.path)) (r) file def
        /Helvetica findfont 12 scalefont setfont 72 700 moveto f 100 string readstring pop show showpage
        """, "ps")
        let output = TestSupport.tempURL("pdf")
        #expect(throws: Ghostscript.Failure.self) { try Ghostscript.postScriptToPDF(hostile, to: output, crop: false) }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func postScriptCannotWriteFiles() throws {
        let target = TestSupport.tempURL("txt")
        let hostile = try write("""
        %!PS
        /f (\(target.path)) (w) file def f (pwned) writestring f closefile
        72 700 moveto /Helvetica findfont 12 scalefont setfont (hi) show showpage
        """, "ps")
        _ = try? Ghostscript.postScriptToPDF(hostile, to: TestSupport.tempURL("pdf"), crop: false)
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func pipesNeverRun() throws {
        let marker = TestSupport.tempURL("txt")
        let eps = try write(SelfTestFixtures.epsArtwork, "eps")
        #expect(throws: Ghostscript.Failure.self) {
            try Ghostscript.run(["-sDEVICE=pdfwrite", "-sOutputFile=%pipe%touch \(marker.path)", eps.path])
        }
        let hostile = try write("%!PS\n(%pipe%touch \(marker.path)) (w) file closefile showpage\n", "ps")
        _ = try? Ghostscript.postScriptToPDF(hostile, to: TestSupport.tempURL("pdf"), crop: false)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func garbageInputFailsCleanly() throws {
        let junk = try write(String(repeating: "not postscript at all \u{1}\u{2}", count: 200), "eps")
        #expect(throws: Ghostscript.Failure.self) { try Ghostscript.postScriptToPDF(junk, to: TestSupport.tempURL("pdf"), crop: true) }
    }

    @Test func cancellingStopsTheJob() async throws {
        let source = try Corpus.documents.first { $0.name == "usgs-streamstats.pdf" }!.url
        let directory = TestSupport.tempURL("render")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let started = Date()
        let task = Task.detached {
            try await Ghostscript.cancellable { flag in
                try Ghostscript.renderPNG(source, dpi: 900, transparent: false, crop: false, into: directory, cancel: flag)
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(Date().timeIntervalSince(started) < 15)
        // The engine is usable straight after a cancelled job.
        let pdf = TestSupport.tempURL("pdf")
        try Ghostscript.postScriptToPDF(try write(SelfTestFixtures.epsArtwork, "eps"), to: pdf, crop: true)
        #expect(PDFDocument(url: pdf)?.pageCount == 1)
    }
}
