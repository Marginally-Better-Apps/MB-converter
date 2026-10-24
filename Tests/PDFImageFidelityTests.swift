import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import Converter

/// Builds PDFs object-by-object so tests can reproduce what print workflows (InDesign,
/// Illustrator, Acrobat) actually emit — CMYK JPEGs with soft masks, Decode arrays,
/// Indexed images, form XObjects — which UIKit's PDF renderer never produces.
struct RawPDF {
    private var objects: [Data] = []

    @discardableResult
    mutating func add(_ object: String) -> Int {
        objects.append(Data(object.utf8))
        return objects.count
    }

    @discardableResult
    mutating func add(stream dictionary: String, _ data: Data) -> Int {
        var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        body.append(data)
        body.append(Data("\nendstream".utf8))
        objects.append(body)
        return objects.count
    }

    /// Finishes a document with one page per (content, XObject map) pair.
    mutating func document(pages: [(content: String, xObjects: [String: Int])], size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let fontID = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pagesID = objects.count + 1 + pages.count * 2
        var pageIDs: [Int] = []
        for page in pages {
            let contentID = add(stream: "", Data(page.content.utf8))
            let xObjects = page.xObjects.map { "/\($0.key) \($0.value) 0 R" }.joined(separator: " ")
            pageIDs.append(add("<< /Type /Page /Parent \(pagesID) 0 R /MediaBox [0 0 \(Int(size.width)) \(Int(size.height))] /Resources << /Font << /F1 \(fontID) 0 R >> /XObject << \(xObjects) >> >> /Contents \(contentID) 0 R >>"))
        }
        let actualPages = add("<< /Type /Pages /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageIDs.count) >>")
        precondition(actualPages == pagesID)
        let root = add("<< /Type /Catalog /Pages \(pagesID) 0 R >>")
        var output = Data("%PDF-1.6\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(output.count)
            output.append(Data("\(index + 1) 0 obj\n".utf8))
            output.append(body)
            output.append(Data("\nendobj\n".utf8))
        }
        let xref = output.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        output.append(Data(table.utf8))
        return output
    }

    /// A CMYK JPEG like Photoshop writes (Adobe APP14, inverted samples — PDFs pair these with
    /// `/Decode [1 0 1 0 1 0 1 0]`): left half pure green (C+Y), right half white.
    static func cmykJPEG(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [0, 0, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [1, 0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
}

/// Reads RGBA pixels (top-left origin) from encoded image data.
struct PixelProbe {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ data: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try #require(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// (r, g, b, a) at a fractional position, x/y in 0…1 from the top-left.
    func at(_ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
        let px = min(width - 1, Int(x * Double(width)))
        let py = min(height - 1, Int(y * Double(height)))
        let index = (py * width + px) * 4
        let alpha = Int(bytes[index + 3])
        func unpremultiply(_ value: UInt8) -> Int { alpha == 0 ? 0 : min(255, Int(value) * 255 / alpha) }
        return (unpremultiply(bytes[index]), unpremultiply(bytes[index + 1]), unpremultiply(bytes[index + 2]), alpha)
    }
}

@Suite struct PDFImageFidelityTests {
    /// The "matching game" case: DCT CMYK image + FlateDecode-free gray SMask with a transparent corner.
    static func cmykMaskedPDF() throws -> Data {
        var pdf = RawPDF()
        let size = 64
        var mask = Data(repeating: 255, count: size * size)
        for row in 0 ..< size / 2 { for column in size / 2 ..< size { mask[row * size + column] = 0 } } // top-right transparent
        let maskID = pdf.add(stream: "/Type /XObject /Subtype /Image /Width \(size) /Height \(size) /ColorSpace /DeviceGray /BitsPerComponent 8", mask)
        let jpeg = try RawPDF.cmykJPEG(width: size, height: size)
        let imageID = pdf.add(stream: "/Type /XObject /Subtype /Image /Width \(size) /Height \(size) /ColorSpace /DeviceCMYK /BitsPerComponent 8 /Decode [1 0 1 0 1 0 1 0] /Filter /DCTDecode /SMask \(maskID) 0 R", jpeg)
        return pdf.document(pages: [(content: "q 200 0 0 200 100 400 cm /Im0 Do Q", xObjects: ["Im0": imageID])])
    }

    @Test func cmykJPEGWithSoftMaskComesOutAsSeen() throws {
        let document = try #require(PDFDocument(data: try Self.cmykMaskedPDF()))
        let extracted = PDFImageExtractor.extract(document)
        #expect(extracted.count == 1)
        let image = try #require(extracted.first)
        #expect(image.fileExtension == "png", "Masked images must keep their transparency")
        let pixels = try PixelProbe(image.data)
        #expect(pixels.width == 64 && pixels.height == 64)

        let green = pixels.at(0.2, 0.75)
        #expect(green.a == 255)
        #expect(green.g > 120 && green.r < 90 && green.b < 140, "CMYK green rendered as \(green)")
        let white = pixels.at(0.8, 0.75)
        #expect(white.r > 225 && white.g > 225 && white.b > 225 && white.a == 255, "CMYK white rendered as \(white)")
        let hole = pixels.at(0.8, 0.2)
        #expect(hole.a == 0, "Soft-masked area must be transparent, got \(hole)")

        // And it must match what PDFKit itself paints for that part of the page (on white).
        let page = try #require(document.page(at: 0))
        let pageImage = try #require(PDFRasterizer.image(page: page, dpi: 72))
        let pagePNG = try #require(PDFRasterizer.encode(pageImage, type: .png))
        let rendered = try PixelProbe(pagePNG)
        for (x, y) in [(0.2, 0.75), (0.8, 0.75), (0.8, 0.2), (0.3, 0.3)] {
            // The image occupies x 100…300, y 400…600 (PDF space) on a 612×792 page.
            let onPage = rendered.at((100 + x * 200) / 612, (792 - 600 + y * 200) / 792)
            let extracted = pixels.at(x, y)
            let composited = extracted.a == 0 ? (r: 255, g: 255, b: 255) : (r: extracted.r, g: extracted.g, b: extracted.b)
            #expect(abs(composited.r - onPage.r) < 24 && abs(composited.g - onPage.g) < 24 && abs(composited.b - onPage.b) < 24,
                    "At (\(x), \(y)) extracted \(composited) but the page shows \(onPage)")
        }
    }

    @Test func reportsWhereImagesArePainted() throws {
        let document = try #require(PDFDocument(data: try Self.cmykMaskedPDF()))
        let placed = PDFPageImages.images(in: document)
        let rect = try #require(placed.first?.rect)
        #expect(abs(rect.minX - 100) < 0.5 && abs(rect.minY - 400) < 0.5 && abs(rect.width - 200) < 0.5 && abs(rect.height - 200) < 0.5)
    }

    @Test func plainRGBJPEGIsSavedByteForByte() throws {
        let jpeg = try ImageToolkit.encode(TestSupport.makeImage(width: 120, height: 80), as: .jpeg, quality: 0.8)
        var pdf = RawPDF()
        let id = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 120 /Height 80 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        let document = try #require(PDFDocument(data: pdf.document(pages: [(content: "q 120 0 0 80 0 0 cm /Im0 Do Q", xObjects: ["Im0": id])])))
        let extracted = try #require(PDFImageExtractor.extract(document).first)
        #expect(extracted.fileExtension == "jpg")
        #expect(extracted.data == jpeg)
    }

    @Test func decodeArrayAndIndexedColorAreApplied() throws {
        var pdf = RawPDF()
        // Gray image stored inverted: all-zero samples with /Decode [1 0] must come out white.
        let inverted = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 32 /Height 32 /ColorSpace /DeviceGray /BitsPerComponent 8 /Decode [1 0]", Data(repeating: 0, count: 32 * 32))
        // Indexed palette: index 0 = red, index 1 = blue; left half 0, right half 1.
        var indices = Data(count: 32 * 32)
        for row in 0 ..< 32 { for column in 16 ..< 32 { indices[row * 32 + column] = 1 } }
        let indexed = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 32 /Height 32 /ColorSpace [/Indexed /DeviceRGB 1 <FF00000000FF>] /BitsPerComponent 8", indices)
        let data = pdf.document(pages: [(content: "q 32 0 0 32 0 0 cm /A Do Q q 32 0 0 32 50 0 cm /B Do Q", xObjects: ["A": inverted, "B": indexed])])
        let images = PDFImageExtractor.extract(try #require(PDFDocument(data: data)))
        #expect(images.count == 2)
        let white = try PixelProbe(images[0].data).at(0.5, 0.5)
        #expect(white.r > 240 && white.g > 240 && white.b > 240, "Decode [1 0] ignored: \(white)")
        let palette = try PixelProbe(images[1].data)
        let red = palette.at(0.2, 0.5), blue = palette.at(0.8, 0.5)
        #expect(red.r > 200 && red.b < 60, "Indexed red came out \(red)")
        #expect(blue.b > 200 && blue.r < 60, "Indexed blue came out \(blue)")
    }

    @Test func findsImagesInsideFormXObjects() throws {
        var pdf = RawPDF()
        let jpeg = try ImageToolkit.encode(TestSupport.makeImage(width: 40, height: 40), as: .jpeg)
        let image = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 40 /Height 40 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        let form = pdf.add(stream: "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Matrix [1 0 0 1 100 50] /Resources << /XObject << /Pic \(image) 0 R >> >>", Data("q 80 0 0 80 10 10 cm /Pic Do Q".utf8))
        let document = try #require(PDFDocument(data: pdf.document(pages: [(content: "q 1.5 0 0 1.5 0 0 cm /Fm Do Q", xObjects: ["Fm": form])])))
        let placed = PDFPageImages.images(in: document)
        let rect = try #require(placed.first?.rect)
        // Page CTM ×1.5, form Matrix translates by (100, 50), image cm at (10, 10) sized 80.
        #expect(abs(rect.minX - 165) < 0.5 && abs(rect.minY - 90) < 0.5 && abs(rect.width - 120) < 0.5)
    }

    @Test func clippingHidesOrCropsPictures() throws {
        var pdf = RawPDF()
        let jpeg = try ImageToolkit.encode(TestSupport.makeImage(width: 100, height: 100, color: .systemRed, square: .systemBlue), as: .jpeg)
        let hidden = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        let cropped = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 100 /Height 100 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        let content = """
        q 500 500 10 10 re W n 200 0 0 200 50 50 cm /H Do Q
        q 300 300 100 200 re W n 200 0 0 200 300 300 cm /C Do Q
        """
        let document = try #require(PDFDocument(data: pdf.document(pages: [(content: content, xObjects: ["H": hidden, "C": cropped])])))
        let placed = PDFPageImages.images(in: document)
        #expect(placed.count == 1, "A picture clipped completely away is not content")
        let image = try #require(placed.first)
        let visible = try #require(image.visibleRect)
        #expect(abs(visible.minX - 300) < 0.5 && abs(visible.width - 100) < 0.5 && abs(visible.height - 200) < 0.5)
        #expect(abs(image.visibleFraction - 0.5) < 0.01)
        // Documents get only the visible left half.
        let block = PDFTextReader.visibleImageBlock(image)
        let pixels = try PixelProbe(block.data)
        #expect(pixels.width == 50 && pixels.height == 100, "Got \(pixels.width)×\(pixels.height)")
        #expect(PDFImageExtractor.extract(document).count == 1)
    }

    @Test func smallIconsAndStencilMasksAreSkipped() throws {
        var pdf = RawPDF()
        let tiny = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceGray /BitsPerComponent 8", Data(repeating: 9, count: 16))
        let stencil = pdf.add(stream: "/Type /XObject /Subtype /Image /Width 64 /Height 64 /ImageMask true /BitsPerComponent 1", Data(repeating: 0xAA, count: 8 * 64))
        let document = try #require(PDFDocument(data: pdf.document(pages: [(content: "/A Do /B Do", xObjects: ["A": tiny, "B": stencil])])))
        #expect(PDFImageExtractor.extract(document).isEmpty)
    }
}

@Suite struct PDFTextLayerTests {
    @Test func redactionRemovesOnlyTheRedactedText() throws {
        let document = TestSupport.makePDF(pages: 1, body: "Quarterly numbers for Page review. Account 555-0100.")
        let items = PDFStamper.redactionItems(for: ["555-0100"], in: document)
        #expect(!items.isEmpty)
        let output = try #require(PDFDocument(data: PDFStamper.apply(items, to: document)))
        let text = output.string ?? ""
        #expect(!text.contains("555"), "Redacted digits must not survive in the text layer: \(text)")
        #expect(!text.contains("0100"))
        #expect(text.contains("Quarterly numbers for Page review. Account"), "Unredacted text must stay searchable: \(text)")
        #expect(output.findString("Quarterly", withOptions: []).count == 1)
    }

    @Test func grayscaleKeepsSelectableText() throws {
        let document = TestSupport.makePDF(pages: 2, body: "Quarterly numbers for review.", picture: true)
        let output = try #require(PDFDocument(data: PDFStamper.render(document, rasterDPI: 100, grayscale: true)))
        #expect(output.pageCount == 2)
        #expect(output.string?.contains("Quarterly numbers for review.") == true)
        // And it really is gray: the orange/teal picture has no color left.
        let page = try #require(output.page(at: 0))
        let image = try #require(PDFRasterizer.image(page: page, dpi: 72))
        let pixels = try PixelProbe(try #require(PDFRasterizer.encode(image, type: .png)))
        let sample = pixels.at(120.0 / 612, 400.0 / 792)
        #expect(abs(sample.r - sample.g) < 6 && abs(sample.g - sample.b) < 6, "Grayscale page still has color \(sample)")
    }
}

/// PDF → editable formats keep the pictures, in reading order, side by side when they share a row.
@Suite @MainActor struct PDFReflowImageTests {
    /// Heading, a row of three pictures, a paragraph, then one picture below it.
    static func layoutPDF() throws -> Data {
        var pdf = RawPDF()
        func picture(_ color: UIColor) throws -> Int {
            let jpeg = try ImageToolkit.encode(TestSupport.makeImage(width: 90, height: 90, color: color, square: .white), as: .jpeg)
            return pdf.add(stream: "/Type /XObject /Subtype /Image /Width 90 /Height 90 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode", jpeg)
        }
        let red = try picture(.systemRed), green = try picture(.systemGreen), blue = try picture(.systemBlue), orange = try picture(.systemOrange)
        let content = """
        BT /F1 24 Tf 72 720 Td (Memory match) Tj ET
        q 120 0 0 120 72 560 cm /R Do Q
        q 120 0 0 120 246 560 cm /G Do Q
        q 120 0 0 120 420 560 cm /B Do Q
        BT /F1 12 Tf 72 520 Td (Cut out each card along the dotted lines.) Tj ET
        q 200 0 0 200 72 280 cm /O Do Q
        """
        return pdf.document(pages: [(content: content, xObjects: ["R": red, "G": green, "B": blue, "O": orange])])
    }

    @Test func readerInterleavesImagesWithText() throws {
        let document = try #require(PDFDocument(data: try Self.layoutPDF()))
        let blocks = PDFTextReader.read(document: document).blocks
        let kinds = blocks.map { block -> String in
            switch block {
            case .heading, .paragraph: "text"
            case .imageRow(let row): "row\(row.count)"
            case .image: "image"
            default: "other"
            }
        }
        #expect(kinds == ["text", "row3", "text", "image"], "Got \(kinds)")
    }

    @Test func wordAndOpenDocumentEmbedEveryPicture() async throws {
        let url = TestSupport.tempURL("pdf")
        try Self.layoutPDF().write(to: url)
        for format in [FileFormat.docx, .odt, .epub] {
            let output = TestSupport.tempURL(format.fileExtension)
            try await DocumentConverter.convert(input: url, from: .pdf, to: format, output: output)
            let back = try DocumentConverter.read(output, format: format)
            #expect(back.allImages.count == 4, "\(format) kept \(back.allImages.count) of 4 pictures")
            #expect(back.plainText.contains("Cut out each card"))
        }
    }

    @Test func reflowableHTMLKeepsTheRowTogether() async throws {
        let url = TestSupport.tempURL("pdf")
        try Self.layoutPDF().write(to: url)
        let output = TestSupport.tempURL("html")
        try await DocumentConverter.convert(input: url, from: .pdf, to: .html, output: output)
        let html = try String(contentsOf: output, encoding: .utf8)
        #expect(html.components(separatedBy: "<img").count - 1 == 4)
        #expect(html.contains("class=\"image-row\""))
    }

    @Test func markdownSavesPicturesBesideTheFile() async throws {
        let url = TestSupport.tempURL("pdf")
        try Self.layoutPDF().write(to: url)
        let tool = try #require(ToolCatalog.tool("convert.pdf.md"))
        let output = try await tool.run(ToolContext(inputs: [try ToolInputFile(url: url)], options: ToolOptionValues(defaults: tool.options)))
        let markdown = try #require(output.files.first { $0.format == .markdown })
        let pictures = output.files.filter { $0.format?.family == .image }
        #expect(pictures.count == 4)
        let text = try String(contentsOf: markdown.url, encoding: .utf8)
        #expect(!text.contains("base64"), "Markdown should link to image files, not inline them")
        for picture in pictures {
            #expect(text.contains("](\(picture.name))"), "\(picture.name) isn't referenced")
            #expect(FileManager.default.fileExists(atPath: markdown.url.deletingLastPathComponent().appendingPathComponent(picture.name).path))
        }
    }

    @Test func exactHTMLLooksLikeThePDFAndKeepsText() async throws {
        let url = TestSupport.tempURL("pdf")
        try Self.layoutPDF().write(to: url)
        let tool = try #require(ToolCatalog.tool("convert.pdf.html"))
        var options = ToolOptionValues(defaults: tool.options)
        options["htmlLayout"] = .string("exact")
        let output = try await tool.run(ToolContext(inputs: [try ToolInputFile(url: url)], options: options))
        let html = try String(contentsOf: try #require(output.files.first).url, encoding: .utf8)
        #expect(html.contains("<section class=\"page\""))
        #expect(html.contains("data:image/jpeg;base64,"), "Page must be drawn as an image")
        #expect(html.contains(">Cut out each card along the dotted lines.</p>"), "Text must stay selectable")
        #expect(html.contains("aspect-ratio: 612 / 792"))
    }

    @Test func layoutChoiceOnlyAppearsForPDFs() throws {
        let tool = try #require(ToolCatalog.tool("convert.any"))
        let option = try #require(tool.options.first { $0.key == "htmlLayout" })
        guard case .dynamicChoice(let provider) = option.kind else { Issue.record("expected dynamic choice"); return }
        #expect(provider([try ToolInputFile(url: URL(fileURLWithPath: "/tmp/a.pdf"))]).map(\.value) == ["exact", "reflow"])
        #expect(provider([try ToolInputFile(url: URL(fileURLWithPath: "/tmp/a.docx"))]).isEmpty)
    }
}

@Suite struct RedactionMatchingTests {
    @Test func catchesPhrasesWrappedAcrossLinesAndCurlyQuotes() throws {
        let narrow = "The applicant’s account at East Carroll Parish office was closed."
        let document = TestSupport.makePDF(pages: 1, size: CGSize(width: 260, height: 400), body: narrow)
        // The narrow page wraps the body, so at least one phrase is split across lines.
        let items = PDFStamper.redactionItems(for: ["applicant's account", "East Carroll Parish office"], in: document)
        let output = try #require(PDFDocument(data: PDFStamper.apply(items, to: document)))
        let text = (output.string ?? "").lowercased()
        #expect(!text.contains("applicant"), "Straight quote in the term must match the curly quote in the PDF: \(text)")
        #expect(!text.contains("carroll"), "Wrapped phrase must be found: \(text)")
        #expect(text.contains("closed"))
    }
}



