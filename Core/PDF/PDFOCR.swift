import CoreGraphics
import Foundation
import PDFKit
import UIKit
import Vision

/// On-device text recognition (Vision) for images and scanned PDFs.
enum TextRecognizer {
    struct Line: Sendable {
        let text: String
        /// Normalized, top-left-origin bounding box.
        let frame: CGRect
        let confidence: Float
    }

    static func recognize(_ image: CGImage, languages: [String]? = nil, fast: Bool = false) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = languages == nil
        if let languages { request.recognitionLanguages = languages }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return Line(
                text: candidate.string,
                frame: CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height),
                confidence: candidate.confidence
            )
        }
    }

    /// Joins recognized lines into reading-order text with paragraph breaks at large gaps.
    static func text(from lines: [Line]) -> String {
        let sorted = lines.sorted { a, b in
            abs(a.frame.midY - b.frame.midY) < min(a.frame.height, b.frame.height) * 0.5 ? a.frame.minX < b.frame.minX : a.frame.minY < b.frame.minY
        }
        var output = ""
        var previous: Line?
        for line in sorted {
            if let previous {
                let gap = line.frame.minY - previous.frame.maxY
                let sameRow = abs(line.frame.midY - previous.frame.midY) < previous.frame.height * 0.5
                output += sameRow ? "  " : (gap > previous.frame.height * 0.9 ? "\n\n" : "\n")
            }
            output += line.text
            previous = line
        }
        return output
    }
}

enum PDFOCR {
    /// Makes every page searchable: pages are re-rendered as images with an invisible recognized-text layer.
    /// Pages that already have text are left vector unless `force` is set.
    static func makeSearchable(_ document: PDFDocument, languages: [String]? = nil, force: Bool = false, progress: ((Double) -> Void)? = nil) throws -> (data: Data, text: String) {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = PDFStamper.documentInfo(from: document)
        var allText: [String] = []
        var failure: Error?
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format).pdfData { context in
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let size = PDFRasterizer.displaySize(of: page)
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                let cg = context.cgContext
                let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !force, existing.count > 8 {
                    PDFRasterizer.draw(page, in: cg, size: size)
                    allText.append(existing)
                } else if let image = PDFRasterizer.image(page: page, dpi: 200) {
                    cg.saveGState()
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    cg.draw(image, in: CGRect(origin: .zero, size: size))
                    cg.restoreGState()
                    do {
                        let lines = try TextRecognizer.recognize(image, languages: languages)
                        for line in lines {
                            let rect = CGRect(x: line.frame.minX * size.width, y: line.frame.minY * size.height, width: line.frame.width * size.width, height: line.frame.height * size.height)
                            PDFStamper.drawInvisibleText(line.text, in: rect, context: cg)
                        }
                        allText.append(TextRecognizer.text(from: lines))
                    } catch {
                        failure = error
                    }
                }
                progress?(Double(index + 1) / Double(max(document.pageCount, 1)))
            }
        }
        if let failure, allText.allSatisfy(\.isEmpty) { throw failure }
        return (data, allText.joined(separator: "\n\n"))
    }
}
