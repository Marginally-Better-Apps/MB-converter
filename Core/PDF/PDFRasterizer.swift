import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum PDFRasterizer {
    /// Displayed page size in points, honoring /Rotate.
    static func displaySize(of page: PDFPage, box: PDFDisplayBox = .cropBox) -> CGSize {
        let bounds = page.bounds(for: box)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    /// Draws a page (with annotations) upright into a UIKit-flipped context of `size`.
    static func draw(_ page: PDFPage, in context: CGContext, size: CGSize, box: PDFDisplayBox = .cropBox) {
        let display = displaySize(of: page, box: box)
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        if display.width > 0, display.height > 0, display != size {
            context.scaleBy(x: size.width / display.width, y: size.height / display.height)
        }
        context.concatenate(page.transform(for: box))
        page.draw(with: box, to: context)
        context.restoreGState()
    }

    static func image(page: PDFPage, dpi: CGFloat, grayscale: Bool = false, background: UIColor = .white) -> CGImage? {
        let size = displaySize(of: page)
        let scale = dpi / 72
        let pixelWidth = max(1, Int((size.width * scale).rounded()))
        let pixelHeight = max(1, Int((size.height * scale).rounded()))
        // Guard against pathological page sizes eating all memory.
        guard pixelWidth * pixelHeight < 120_000_000 else { return nil }
        let colorSpace = grayscale ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = grayscale ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo) else { return nil }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        // Bitmap contexts are bottom-left origin, which matches PDF space.
        context.scaleBy(x: CGFloat(pixelWidth) / size.width, y: CGFloat(pixelHeight) / size.height)
        context.concatenate(page.transform(for: .cropBox))
        page.draw(with: .cropBox, to: context)
        return context.makeImage()
    }

    static func jpegData(page: PDFPage, dpi: CGFloat, quality: CGFloat, grayscale: Bool = false) -> Data? {
        guard let image = image(page: page, dpi: dpi, grayscale: grayscale) else { return nil }
        return encode(image, type: .jpeg, quality: quality, dpi: dpi)
    }

    static func encode(_ image: CGImage, type: UTType, quality: CGFloat = 0.9, dpi: CGFloat? = nil) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        if let dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
