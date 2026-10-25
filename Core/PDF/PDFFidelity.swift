import CoreGraphics
import PDFKit

/// Checks that a rewritten PDF still looks like its source in Apple's renderer, which is what people
/// see in Files, Mail and Quick Look. A rewrite can be valid PDF and still render differently there
/// (Ghostscript's soft-mask groups in some print PDFs, for example), so rewrites are compared before
/// they replace the original.
enum PDFFidelity {
    /// Mean per-channel difference (0…255) on the most different of up to `maxPages` evenly spaced
    /// pages, or nil when the page counts differ. `grayscale` compares luminance only.
    static func worstPageDifference(_ source: PDFDocument, _ rewrite: PDFDocument, maxPages: Int = 12, dpi: CGFloat = 36, grayscale: Bool = false) -> Double? {
        guard source.pageCount == rewrite.pageCount, source.pageCount > 0 else { return nil }
        let count = source.pageCount
        let samples = Set((0 ..< min(count, maxPages)).map { $0 * count / min(count, maxPages) })
        var worst = 0.0
        for index in samples.sorted() {
            guard let a = source.page(at: index).flatMap({ PDFRasterizer.image(page: $0, dpi: dpi) }),
                  let b = rewrite.page(at: index).flatMap({ PDFRasterizer.image(page: $0, dpi: dpi) }) else { return nil }
            worst = max(worst, difference(a, b, grayscale: grayscale))
        }
        return worst
    }

    /// True when the rewrite renders like the source. 8 allows recompressed photos and resampled
    /// images; missing or changed content scores well above it.
    static func looksTheSame(_ source: PDFDocument, _ rewrite: PDFDocument, grayscale: Bool = false, tolerance: Double = 8) -> Bool {
        guard let difference = worstPageDifference(source, rewrite, grayscale: grayscale) else { return false }
        return difference <= tolerance
    }

    static func difference(_ a: CGImage, _ b: CGImage, side: Int = 96, grayscale: Bool = false) -> Double {
        let pa = pixels(a, side: side), pb = pixels(b, side: side)
        var total = 0.0
        if grayscale {
            func luma(_ p: [UInt8], _ i: Int) -> Double { 0.299 * Double(p[i]) + 0.587 * Double(p[i + 1]) + 0.114 * Double(p[i + 2]) }
            for index in stride(from: 0, to: pa.count, by: 4) { total += abs(luma(pa, index) - luma(pb, index)) }
            return total / Double(side * side)
        }
        for index in pa.indices where index % 4 != 3 { total += abs(Double(pa[index]) - Double(pb[index])) }
        return total / Double(side * side * 3)
    }

    /// RGBA pixels of `image` scaled to side × side, on white.
    private static func pixels(_ image: CGImage, side: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 255, count: side * side * 4)
        buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        return buffer
    }
}
