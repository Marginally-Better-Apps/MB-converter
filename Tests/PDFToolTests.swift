import Foundation
import PDFKit
import Testing
import UIKit
@testable import Converter

struct PageRangeTests {
    @Test func parsesRangesInOrder() throws {
        #expect(try PageRangeParser.parse("1-3, 5", pageCount: 6) == [0, 1, 2, 4])
        #expect(try PageRangeParser.parse("4-2", pageCount: 6) == [3, 2, 1])
        #expect(try PageRangeParser.parse("5-", pageCount: 6) == [4, 5])
        #expect(try PageRangeParser.parse("-2, last", pageCount: 6) == [0, 1, 5])
        #expect(try PageRangeParser.parseGroups("1-2;3", pageCount: 3) == [[0, 1], [2]])
    }

    @Test func rejectsInvalidRanges() {
        #expect(throws: PageRangeParser.ParseError.outOfBounds(9, pageCount: 3)) { try PageRangeParser.parse("9", pageCount: 3) }
        #expect(throws: PageRangeParser.ParseError.invalid("x")) { try PageRangeParser.parse("x", pageCount: 3) }
        #expect(throws: PageRangeParser.ParseError.empty) { try PageRangeParser.parse(" , ", pageCount: 3) }
    }

    @Test func describesIndices() {
        #expect(PageRangeParser.describe([0, 1, 2, 4, 6, 7]) == "1–3, 5, 7–8")
    }
}

struct PDFStructureTests {
    @Test func mergesInOrder() {
        let merged = PDFToolkit.merge([TestSupport.makePDF(pages: 2), TestSupport.makePDF(pages: 1)])
        #expect(TestSupport.pageTitles(merged) == ["Page 1", "Page 2", "Page 1"])
    }

    @Test func splitsByRangesAndEveryN() throws {
        let source = TestSupport.makePDF(pages: 5)
        let ranges = try PDFToolkit.split(source, mode: .ranges("1-2, 5"))
        #expect(ranges.map(\.pageCount) == [2, 1])
        #expect(TestSupport.pageTitles(ranges[1]) == ["Page 5"])
        #expect(try PDFToolkit.split(source, mode: .everyNPages(2)).map(\.pageCount) == [2, 2, 1])
        #expect(try PDFToolkit.split(source, mode: .eachPage).count == 5)
        let bySize = try PDFToolkit.split(source, mode: .maxFileSize(bytes: 4_000))
        #expect(bySize.map(\.pageCount).reduce(0, +) == 5)
    }

    @Test func organizesReorderRotateDeleteAndInsert() throws {
        let source = TestSupport.makePDF(pages: 3)
        let output = try PDFToolkit.organize(source, edits: [
            .init(sourceIndex: 2, rotation: 90),
            .init(sourceIndex: nil),
            .init(sourceIndex: 0, rotation: -90)
        ])
        #expect(output.pageCount == 3)
        #expect(output.page(at: 0)?.string?.contains("Page 3") == true)
        #expect(output.page(at: 0)?.rotation == 90)
        #expect(output.page(at: 1)?.string?.isEmpty ?? true)
        #expect(output.page(at: 2)?.rotation == 270)
        #expect(source.page(at: 0)?.rotation == 0, "source must not be mutated")
    }

    @Test func deleteReverseAndBlankDetection() throws {
        let source = PDFToolkit.organize(TestSupport.makePDF(pages: 3), withBlankAt: 1)
        #expect(PDFToolkit.blankPageIndices(source) == [1])
        let cleaned = try PDFToolkit.deletePages(source, remove: [1])
        #expect(TestSupport.pageTitles(PDFToolkit.reverse(cleaned)) == ["Page 3", "Page 2", "Page 1"])
        #expect(throws: DocumentError.self) { try PDFToolkit.deletePages(cleaned, remove: [0, 1, 2]) }
    }

    @Test func protectsAndUnlocks() throws {
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.protect(TestSupport.makePDF(pages: 2), userPassword: "s3cret", ownerPassword: nil, permissions: .init(allowPrinting: false, allowCopying: false), to: url)
        let locked = try #require(PDFDocument(url: url))
        #expect(locked.isEncrypted && locked.isLocked)
        #expect(throws: DocumentError.passwordRequired) { try PDFToolkit.open(url) }
        #expect(throws: DocumentError.wrongPassword) { try PDFToolkit.open(url, password: "nope") }
        let opened = try PDFToolkit.open(url, password: "s3cret")
        let unlockedURL = TestSupport.tempURL("pdf")
        try PDFToolkit.removePassword(opened, to: unlockedURL)
        let unlocked = try #require(PDFDocument(url: unlockedURL))
        #expect(!unlocked.isEncrypted)
        #expect(TestSupport.pageTitles(unlocked) == ["Page 1", "Page 2"])
    }

    @Test func cropsAndAutoTrims() throws {
        let source = TestSupport.makePDF(pages: 1)
        let cropped = try PDFToolkit.crop(source, insets: .uniform(50))
        #expect(cropped.page(at: 0)?.bounds(for: .cropBox).width == 512)
        #expect(throws: DocumentError.self) { try PDFToolkit.crop(source, insets: .uniform(400)) }
        let trimmed = PDFToolkit.autoTrim(source)
        let box = try #require(trimmed.page(at: 0)?.bounds(for: .cropBox))
        #expect(box.width < 300 && box.height < 120)
    }

    @Test func editsMetadata() throws {
        let document = TestSupport.makePDF(pages: 1)
        PDFToolkit.setMetadata(.init(title: "T", author: "A", subject: nil, keywords: "x, y", creator: nil), on: document)
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.write(document, to: url)
        let back = PDFToolkit.metadata(of: try #require(PDFDocument(url: url)))
        #expect(back.title == "T" && back.author == "A" && back.keywords == "x, y")
    }

    @Test func extractsText() {
        let text = PDFToolkit.text(of: TestSupport.makePDF(pages: 2, body: "Hello world"))
        #expect(text.contains("— Page 2 —"))
        #expect(text.contains("Hello world"))
    }

    @Test func flattensAnnotations() throws {
        let document = TestSupport.makePDF(pages: 1)
        let page = try #require(document.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 100, y: 100, width: 200, height: 40), forType: .freeText, withProperties: nil)
        note.contents = "Burned in"
        page.addAnnotation(note)
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.flatten(document, to: url)
        let back = try #require(PDFDocument(url: url))
        #expect(back.page(at: 0)?.annotations.isEmpty == true)
    }
}

extension PDFToolkit {
    static func organize(_ source: PDFDocument, withBlankAt index: Int) -> PDFDocument {
        var edits = PageEdit.identity(pageCount: source.pageCount)
        edits.insert(PageEdit(sourceIndex: nil), at: index)
        return try! organize(source, edits: edits)
    }
}

struct PDFRenderingTests {
    @Test func watermarksEveryPageKeepingText() throws {
        let data = PDFStamper.watermark(TestSupport.makePDF(pages: 2), PDFStamper.TextWatermark(text: "CONFIDENTIAL"))
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount == 2)
        #expect(pdf.page(at: 1)?.string?.contains("CONFIDENTIAL") == true)
        #expect(pdf.page(at: 1)?.string?.contains("Page 2") == true)
    }

    @Test func addsPageNumbers() throws {
        var numbering = PDFStamper.PageNumbering()
        numbering.format = .pageOfTotal
        numbering.skipFirstPage = true
        let pdf = try #require(PDFDocument(data: PDFStamper.addPageNumbers(TestSupport.makePDF(pages: 3), numbering)))
        #expect(pdf.page(at: 0)?.string?.contains("of") == false)
        #expect(pdf.page(at: 2)?.string?.contains("Page 2 of 2") == true)
    }

    @Test func rotatedPagesKeepOrientationWhenStamped() throws {
        let rotated = PDFToolkit.rotate(TestSupport.makePDF(pages: 1), by: 90)
        let pdf = try #require(PDFDocument(data: PDFStamper.watermark(rotated, .init(text: "X"))))
        let bounds = try #require(pdf.page(at: 0)).bounds(for: .mediaBox)
        #expect(bounds.width == 792 && bounds.height == 612)
    }

    @Test func redactionRemovesUnderlyingText() throws {
        let source = TestSupport.makePDF(pages: 2, body: "The account number is 123-456 and nothing else.")
        let items = PDFStamper.redactionItems(for: ["123-456"], in: source)
        #expect(items.count == 2)
        let pdf = try #require(PDFDocument(data: PDFStamper.apply(items, to: source)))
        #expect(pdf.string?.contains("123-456") == false)
    }

    @Test func overlayItemsDrawText() throws {
        let item = PDFOverlayItem(pageIndex: 0, frame: CGRect(x: 0.1, y: 0.5, width: 0.6, height: 0.1), kind: .text("Signed by Ada", fontSize: 18, colorHex: 0x000000, bold: false))
        let pdf = try #require(PDFDocument(data: PDFStamper.apply([item], to: TestSupport.makePDF(pages: 1))))
        #expect(pdf.string?.contains("Signed by Ada") == true)
    }

    @Test func grayscaleRendersAllPages() throws {
        let pdf = try #require(PDFDocument(data: PDFStamper.render(TestSupport.makePDF(pages: 2), grayscale: true)))
        #expect(pdf.pageCount == 2)
    }

    @Test func compressionShrinksImageHeavyPDF() throws {
        let photo = try TestSupport.writeImage(noiseImage(width: 2400, height: 1800), format: .png)
        let source = TestSupport.tempURL("pdf")
        var options = ImagesToPDF.Options()
        options.maxPixelSize = nil
        options.jpegQuality = 1
        try ImagesToPDF.makePDF(from: [photo, photo], options: options).write(to: source)
        let output = TestSupport.tempURL("pdf")
        let result = try PDFCompressor.compress(source, level: .strong, to: output)
        #expect(!result.keptOriginal)
        #expect(result.compressedBytes < result.originalBytes / 2)
        #expect(PDFDocument(url: output)?.pageCount == 2)
    }

    @Test func compressionNeverGrowsFile() throws {
        let source = TestSupport.tempURL("pdf")
        try PDFToolkit.write(TestSupport.makePDF(pages: 1), to: source)
        let output = TestSupport.tempURL("pdf")
        let result = try PDFCompressor.compress(source, level: .balanced, to: output)
        #expect(result.compressedBytes <= result.originalBytes)
    }

    @Test func imagesToPDFPageSizing() throws {
        let landscape = try TestSupport.writeImage(TestSupport.makeImage(width: 400, height: 200))
        let portrait = try TestSupport.writeImage(TestSupport.makeImage(width: 200, height: 400), format: .jpeg)
        var options = ImagesToPDF.Options()
        options.pageSizing = .a4
        options.margin = 36
        let pdf = try #require(PDFDocument(data: ImagesToPDF.makePDF(from: [landscape, portrait], options: options)))
        let first = try #require(pdf.page(at: 0)).bounds(for: .mediaBox).size
        let second = try #require(pdf.page(at: 1)).bounds(for: .mediaBox).size
        #expect(first.width > first.height)
        #expect(second.height > second.width)
        options.pageSizing = .fitImage
        options.margin = 0
        let fitted = try #require(PDFDocument(data: ImagesToPDF.makePDF(from: [landscape], options: options)))
        #expect(fitted.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 400, height: 200))
    }

    @Test func pdfToImagesAndTIFF() throws {
        let source = TestSupport.makePDF(pages: 3)
        let images = try PDFToImages.render(source, pages: [0, 2], format: .png, dpi: 144)
        #expect(images.map(\.index) == [0, 2])
        let first = try ImageToolkit.load(data: images[0].data)
        #expect(first.width == 1224 && first.height == 1584)
        let tiff = try PDFToImages.multipageTIFF(source, dpi: 50)
        let tiffSource = try #require(CGImageSourceCreateWithData(tiff as CFData, nil))
        #expect(CGImageSourceGetCount(tiffSource) == 3)
    }

    @Test func extractsEmbeddedImages() throws {
        let jpeg = try TestSupport.writeImage(TestSupport.makeImage(width: 300, height: 200), format: .jpeg)
        let pdf = try #require(PDFDocument(data: ImagesToPDF.makePDF(from: [jpeg, jpeg])))
        let extracted = PDFImageExtractor.extract(pdf)
        #expect(!extracted.isEmpty)
        let image = try ImageToolkit.load(data: extracted[0].data)
        #expect(image.width == 300 && image.height == 200)
    }

    @Test func ocrMakesScannedPDFSearchable() throws {
        let scan = try TestSupport.writeImage(TestSupport.textImage("Invoice 2026"))
        let scanned = try #require(PDFDocument(data: ImagesToPDF.makePDF(from: [scan])))
        #expect(!PDFToolkit.hasTextLayer(scanned))
        let result = try PDFOCR.makeSearchable(scanned, languages: ["en-US"])
        #expect(result.text.contains("Invoice"))
        let searchable = try #require(PDFDocument(data: result.data))
        #expect(searchable.string?.contains("Invoice") == true)
    }

    private func noiseImage(width: Int, height: Int) -> CGImage {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let value = UInt8.random(in: 0 ... 255, using: &generator)
            bytes[index] = value
            bytes[index + 1] = value &+ 40
            bytes[index + 2] = 255 - value
            bytes[index + 3] = 255
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}
