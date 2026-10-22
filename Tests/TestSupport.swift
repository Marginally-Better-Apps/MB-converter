import Foundation
import PDFKit
import UIKit
@testable import Converter

final class BundleToken {}

enum TestSupport {
    static func fixture(_ name: String) throws -> URL {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: nil) else {
            throw DocumentError.unreadable("Missing fixture \(name)")
        }
        return url
    }

    static func tempURL(_ ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// A PDF whose pages each say "Page N" (plus optional body text), for structural tests.
    static func makePDF(pages: Int, size: CGSize = CGSize(width: 612, height: 792), body: String? = nil) -> PDFDocument {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for index in 0 ..< pages {
                context.beginPage()
                let title = "Page \(index + 1)" as NSString
                title.draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
                if let body {
                    (body as NSString).draw(in: CGRect(x: 72, y: 130, width: size.width - 144, height: size.height - 200), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                }
            }
        }
        return PDFDocument(data: data)!
    }

    static func pageTitles(_ document: PDFDocument) -> [String] {
        (0 ..< document.pageCount).map { index in
            document.page(at: index)?.string?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    /// Solid-color test image with an optional colored square.
    static func makeImage(width: Int, height: Int, color: UIColor = .systemBlue, square: UIColor? = .white) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let square {
                square.setFill()
                context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            }
        }.cgImage!
    }

    static func writeImage(_ image: CGImage, format: ImageToolkit.OutputFormat = .png) throws -> URL {
        let url = tempURL(format.fileExtension)
        try ImageToolkit.encode(image, as: format).write(to: url)
        return url
    }

    /// Image containing rendered text, for OCR tests.
    static func textImage(_ text: String, size: CGSize = CGSize(width: 1200, height: 300)) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: UIColor.black])
        }.cgImage!
    }

    static let sampleDocument = RichDocument(
        metadata: DocumentMetadata(title: "Sample Title", author: "Grace Hopper"),
        blocks: [
            .heading(level: 1, runs: [Run("Sample Title")]),
            .paragraph(runs: [Run("Plain "), Run("bold", .bold), Run(" and "), Run("italic", .italic), Run(" with a "), Run("link", RunStyle(link: "https://example.com")), Run(".")]),
            .heading(level: 2, runs: [Run("Lists")]),
            .list(ordered: false, items: [
                [.paragraph(runs: [Run("Apples")])],
                [.paragraph(runs: [Run("Pears")]), .list(ordered: true, items: [[.paragraph(runs: [Run("Nested one")])], [.paragraph(runs: [Run("Nested two")])]])]
            ]),
            .table(TableBlock(textRows: [["Name", "Qty"], ["Bolts", "42"], ["Nuts & washers", "7"]], hasHeaderRow: true)),
            .quote([.paragraph(runs: [Run("To be or not to be.")])]),
            .code("let x = 1 < 2"),
            .paragraph(runs: [Run("Unicode: Ünïcödé — “quotes” 😀 & <tags>")])
        ]
    )
}
