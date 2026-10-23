import CoreGraphics
import Foundation
import PDFKit
import UIKit

enum PDFCompressor {
    enum Level: String, CaseIterable, Identifiable, Hashable, Sendable {
        case light, balanced, strong

        var id: String { rawValue }

        var label: String {
            switch self {
            case .light: "Light"
            case .balanced: "Balanced"
            case .strong: "Strong"
            }
        }

        var detail: String {
            switch self {
            case .light: "Recompresses images. Text and vectors untouched."
            case .balanced: "Re-renders pages at 150 dpi. Text stays searchable."
            case .strong: "Re-renders pages at 96 dpi for the smallest file."
            }
        }

        var raster: (dpi: CGFloat, quality: CGFloat)? {
            switch self {
            case .light: nil
            case .balanced: (150, 0.6)
            case .strong: (96, 0.42)
            }
        }
    }

    struct Result: Sendable {
        let originalBytes: Int64
        let compressedBytes: Int64
        /// True when no strategy beat the original, so the original bytes were kept.
        let keptOriginal: Bool
    }

    static func compress(_ url: URL, password: String? = nil, level: Level, to output: URL) throws -> Result {
        let document = try PDFToolkit.open(url, password: password)
        let originalBytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0

        var candidates: [Data] = []
        let lightURL = FileManager.default.temporaryDirectory.appendingPathComponent("compress-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: lightURL) }
        let copy = PDFToolkit.document(from: document, pageIndices: Array(0 ..< document.pageCount))
        if copy.write(to: lightURL, withOptions: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]),
           let data = try? Data(contentsOf: lightURL) {
            candidates.append(data)
        }
        if let raster = level.raster {
            candidates.append(rasterized(document, dpi: raster.dpi, quality: raster.quality))
        }
        let best = candidates.filter { !$0.isEmpty }.min { $0.count < $1.count }
        try? FileManager.default.removeItem(at: output)
        if let best, Int64(best.count) < originalBytes || originalBytes == 0 {
            try best.write(to: output)
            return Result(originalBytes: originalBytes, compressedBytes: Int64(best.count), keptOriginal: false)
        }
        try FileManager.default.copyItem(at: url, to: output)
        return Result(originalBytes: originalBytes, compressedBytes: originalBytes, keptOriginal: true)
    }

    /// Replaces each page with a JPEG of itself, then lays the original text back invisibly so it stays searchable.
    static func rasterized(_ document: PDFDocument, dpi: CGFloat, quality: CGFloat) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = PDFStamper.documentInfo(from: document)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format)
        return renderer.pdfData { context in
            for index in 0 ..< document.pageCount {
                guard let page = document.page(at: index) else { continue }
                let size = PDFRasterizer.displaySize(of: page)
                context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                let cg = context.cgContext
                if let jpeg = PDFRasterizer.jpegData(page: page, dpi: dpi, quality: quality),
                   let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
                   let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
                    cg.saveGState()
                    cg.translateBy(x: 0, y: size.height)
                    cg.scaleBy(x: 1, y: -1)
                    cg.draw(image, in: CGRect(origin: .zero, size: size))
                    cg.restoreGState()
                }
                PDFStamper.drawTextLayer(of: page, size: size, context: cg)
            }
        }
    }
}
