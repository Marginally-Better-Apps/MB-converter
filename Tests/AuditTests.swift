import Foundation
import Testing
import PDFKit
import UIKit
@testable import Converter

/// Opt-in visual audit: runs every tool on the Self-Test's real inputs and saves inputs, outputs
/// and a report to a folder so a person can look through them. Enable with
///   TEST_RUNNER_MB_AUDIT_DIR=/tmp/mbaudit xcodebuild test -only-testing:ConverterTests/AuditTests …
/// then run Scripts/AuditSheets.sh /tmp/mbaudit to make contact sheets.
@MainActor
struct AuditTests {
    static let directory = ProcessInfo.processInfo.environment["MB_AUDIT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test(.enabled(if: directory != nil), arguments: SelfTestPlan.tools.map(\.id.rawValue))
    func dumpTool(_ id: String) async throws {
        let tool = try #require(ToolCatalog.tool(ToolID(rawValue: id)))
        let folder = try #require(Self.directory).appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var report = "\(tool.title)\n"
        // The same inputs, kept for the UI tour (UITests ToolTourUITests opens each tool with them).
        let inputFolder = folder.appendingPathComponent("inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: inputFolder, withIntermediateDirectories: true)
        let inputs = try await SelfTestPlan.inputs(for: tool)
        var inputPaths: [String] = []
        for (index, input) in inputs.enumerated() {
            let copy = inputFolder.appendingPathComponent("\(index + 1)-\(input.url.lastPathComponent)")
            try? FileManager.default.copyItem(at: input.url, to: copy)
            inputPaths.append(copy.path)
        }
        try Data(inputPaths.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("inputs.txt"))
        do {
            let result = try await SelfTestPlan.check(tool)
            report += "summary: \(result.summary ?? "-")\nproblems: \(result.problems.isEmpty ? "none" : result.problems.joined(separator: "; "))\n"
            for (index, url) in result.outputs.enumerated() {
                try? FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("out-\(index + 1)-\(url.lastPathComponent)"))
            }
        } catch {
            report += "ERROR: \(error.localizedDescription)\n"
        }
        try Data(report.utf8).write(to: folder.appendingPathComponent("report.txt"))
    }

    /// Meme captions at several sizes, fonts and positions, with long text, emoji and a busy photo.
    @Test(.enabled(if: directory != nil))
    func dumpMemes() async throws {
        let folder = try #require(Self.directory).appendingPathComponent("memes", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let photo = try ImageToolkit.load(try SelfTestFixtures.sample("astronaut-portrait.jpg"), maxPixelSize: 1_200)
        let cases: [(String, [ImageToolkit.Caption])] = [
            ("default", [.init(text: "ALEX", placement: .top, relativeSize: 0.1, font: .meme), .init(text: "LETTER LEAGUE", placement: .bottom, relativeSize: 0.1, font: .meme)]),
            ("long-wrap", [.init(text: "WHEN YOU FINALLY GET THE TEXT TO WRAP ACROSS SEVERAL LINES", placement: .top, relativeSize: 0.09, font: .meme)]),
            ("moved", [.init(text: "MOVED HERE", relativeSize: 0.08, font: .meme, position: CGPoint(x: 0.3, y: 0.6))]),
            ("fonts", CaptionRenderer.Font.allCases.enumerated().map { index, font in
                .init(text: "\(font.label) AVWX", relativeSize: 0.07, font: font, position: CGPoint(x: 0.5, y: 0.12 + Double(index) * 0.18))
            }),
            ("emoji", [.init(text: "MOOD 😂🔥", placement: .bottom, relativeSize: 0.1, font: .meme)]),
            ("watermark", [.init(text: "© Shlok 2026", placement: .bottomRight, relativeSize: 0.05, opacity: 0.6, rotation: -15)])
        ]
        for (name, captions) in cases {
            let image = try #require(ImageToolkit.addText(photo, captions))
            try ImageToolkit.encode(image, as: .png).write(to: folder.appendingPathComponent("\(name).png"))
        }
    }
}

/// SVG rendering fills the output at the SVG's own aspect ratio and keeps transparency.
@MainActor
struct SVGRenderTests {
    @Test func svgFillsOutputAtItsAspectRatio() async throws {
        let url = TestSupport.tempURL("svg")
        // Blue bar across the full width, a transparent band below it.
        try Data(##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="40" fill="#0b5fa5"/></svg>"##.utf8).write(to: url)
        let image = try await WebPDFRenderer.renderSVG(url)
        #expect(abs(Double(image.width) / Double(image.height) - 1.5) < 0.02, "\(image.width)×\(image.height)")
        #expect(max(image.width, image.height) >= 2_000)
        let pixels = try PixelProbe(try ImageToolkit.encode(image, as: .png))
        let topRight = pixels.at(0.97, 0.1), bottom = pixels.at(0.5, 0.9)
        #expect(topRight.b > 150 && topRight.a == 255, "the bar must reach the right edge, got \(topRight)")
        #expect(bottom.a == 0, "below the bar must stay transparent, got \(bottom)")
    }
}

/// Captions are clean glyph shapes: no outline seams inside letters (the bug in system fonts whose
/// contours overlap), placed where they were dragged.
@MainActor
struct CaptionRenderTests {
    private func rgba(_ image: CGImage) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &buffer, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }

    @Test(arguments: CaptionRenderer.Font.allCases.map(\.rawValue))
    func outlineNeverShowsInsideLetters(_ font: String) throws {
        let background = TestSupport.makeImage(width: 900, height: 300, color: .gray, square: nil)
        let font = try #require(CaptionRenderer.Font(rawValue: font))
        var caption = ImageToolkit.Caption(text: "AVWX KEMB 8&", placement: .center, relativeSize: 0.3, font: font)
        caption.outlined = false
        let fill = rgba(try #require(ImageToolkit.addText(background, caption)))
        caption.outlined = true
        let outlined = rgba(try #require(ImageToolkit.addText(background, caption)))
        let width = 900, height = 300, inset = 4
        func white(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return pixels[i] > 245 && pixels[i + 1] > 245 && pixels[i + 2] > 245
        }
        var interior = 0, seams = 0
        for y in inset ..< height - inset {
            for x in inset ..< width - inset where white(fill, x, y) {
                // Well inside the letter: every neighbor within `inset` pixels is fill too.
                guard white(fill, x - inset, y), white(fill, x + inset, y), white(fill, x, y - inset), white(fill, x, y + inset) else { continue }
                interior += 1
                if !white(outlined, x, y) { seams += 1 }
            }
        }
        #expect(interior > 2_000, "\(font): too little text rendered (\(interior))")
        #expect(seams == 0, "\(font): \(seams) outline pixels inside letters")
    }

    /// Control for the check above: the old renderer (stroke drawn over the fill) must be caught.
    @Test func detectorCatchesTheOldStrokeOverFillSeams() throws {
        let size = CGSize(width: 900, height: 300)
        func render(outlined: Bool) -> [UInt8] {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                UIColor.gray.setFill()
                UIRectFill(CGRect(origin: .zero, size: size))
                var attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 90, weight: .heavy), .foregroundColor: UIColor.white]
                if outlined { attributes[.strokeColor] = UIColor.black; attributes[.strokeWidth] = -3.0 }
                ("AVWX KEMB 8&" as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: attributes)
            }.cgImage!
            return rgba(image)
        }
        let fill = render(outlined: false), outlined = render(outlined: true)
        let width = 900, inset = 4
        func white(_ pixels: [UInt8], _ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            return pixels[i] > 245 && pixels[i + 1] > 245 && pixels[i + 2] > 245
        }
        var seams = 0
        for y in inset ..< 300 - inset {
            for x in inset ..< width - inset where white(fill, x, y) && white(fill, x - inset, y) && white(fill, x + inset, y) && white(fill, x, y - inset) && white(fill, x, y + inset) {
                if !white(outlined, x, y) { seams += 1 }
            }
        }
        #expect(seams > 50, "the seam detector didn't see the old renderer's seams (\(seams))")
    }

    @Test func draggedCaptionLandsWhereItWasPlaced() throws {
        let caption = ImageToolkit.Caption(text: "MOVED", relativeSize: 0.1, font: .meme, position: CGPoint(x: 0.25, y: 0.7))
        let frame = CaptionRenderer.frame(caption, imageSize: CGSize(width: 1_000, height: 800))
        #expect(abs(frame.midX - 250) < 1 && abs(frame.midY - 560) < 1, "\(frame)")
    }
}

struct MarkdownTableTests {
    @Test func headerlessTableUsesFirstRowAsHeader() throws {
        let document = RichDocument(blocks: [.table(TableBlock(textRows: [["Region", "Sales"], ["EMEA", "1,200"]], hasHeaderRow: false))])
        let markdown = String(decoding: MarkdownWriter.data(document), as: UTF8.self)
        #expect(markdown.contains("| Region | Sales |\n| --- | --- |\n| EMEA | 1,200 |"), "\(markdown)")
        #expect(!markdown.contains("|  |  |"))
    }
}

/// Pages whose crop box doesn't start at the origin (any cropped PDF) render where they should.
struct CroppedPageRenderTests {
    @Test(arguments: [0, 90])
    func croppedPageRendersItsOwnContent(rotation: Int) throws {
        // A red square at (300, 400)–(400, 500), cropped to (250, 350)–(450, 550): the square must fill the middle half.
        let format = UIGraphicsPDFRendererFormat()
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format).pdfData { context in
            context.beginPage()
            UIColor.red.setFill()
            // UIKit is top-left origin: PDF y 400–500 is UIKit y 292–392.
            UIRectFill(CGRect(x: 300, y: 292, width: 100, height: 100))
        }
        let document = try #require(PDFDocument(data: data))
        let page = try #require(document.page(at: 0))
        page.setBounds(CGRect(x: 250, y: 350, width: 200, height: 200), for: .cropBox)
        page.rotation = rotation
        let image = try #require(PDFRasterizer.image(page: page, dpi: 72))
        #expect(image.width == 200 && image.height == 200)
        let pixels = try PixelProbe(try #require(PDFRasterizer.encode(image, type: .png)))
        let center = pixels.at(0.5, 0.5), corner = pixels.at(0.1, 0.1)
        #expect(center.r > 200 && center.g < 60, "rotation \(rotation): center should be red, got \(center)")
        #expect(corner.r > 240 && corner.g > 240, "rotation \(rotation): corner should be white, got \(corner)")
    }
}
