import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

enum ImagesToPDF {
    enum PageSizing: String, CaseIterable, Identifiable, Hashable, Sendable {
        case fitImage, a4, letter, legal

        var id: String { rawValue }
        var label: String {
            switch self {
            case .fitImage: "Same as image"
            case .a4: "A4"
            case .letter: "US Letter"
            case .legal: "US Legal"
            }
        }
    }

    enum Orientation: String, CaseIterable, Identifiable, Hashable, Sendable {
        case auto, portrait, landscape
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    enum Fit: String, CaseIterable, Identifiable, Hashable, Sendable {
        case fit, fill
        var id: String { rawValue }
        var label: String { self == .fit ? "Fit" : "Fill" }
    }

    struct Options: Hashable, Sendable {
        var pageSizing: PageSizing = .fitImage
        var orientation: Orientation = .auto
        var margin: CGFloat = 0
        var fit: Fit = .fit
        /// Longest edge in pixels; larger images are downsampled. nil keeps originals.
        var maxPixelSize: CGFloat? = 2_400
        var jpegQuality: CGFloat = 0.85
    }

    static func makePDF(from imageURLs: [URL], options: Options = Options()) throws -> Data {
        guard !imageURLs.isEmpty else { throw DocumentError.empty("Add at least one image.") }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextCreator as String: "MB Converter"]
        var failures = 0
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792), format: format).pdfData { context in
            for url in imageURLs {
                guard let image = loadImage(url, maxPixelSize: options.maxPixelSize, quality: options.jpegQuality) else {
                    failures += 1
                    continue
                }
                let imageSize = CGSize(width: image.width, height: image.height)
                // Treat pixels as 72 dpi when sizing pages to the image, capped to a sensible page size.
                var pageSize: CGSize
                switch options.pageSizing {
                case .fitImage:
                    let scale = min(1, 1_440 / max(imageSize.width, imageSize.height))
                    pageSize = CGSize(width: imageSize.width * scale + options.margin * 2, height: imageSize.height * scale + options.margin * 2)
                case .a4: pageSize = PageSize.a4.points
                case .letter: pageSize = PageSize.letter.points
                case .legal: pageSize = PageSize.legal.points
                }
                if options.pageSizing != .fitImage {
                    let landscape: Bool = switch options.orientation {
                    case .auto: imageSize.width > imageSize.height
                    case .portrait: false
                    case .landscape: true
                    }
                    if landscape != (pageSize.width > pageSize.height) {
                        pageSize = CGSize(width: pageSize.height, height: pageSize.width)
                    }
                }
                let pageRect = CGRect(origin: .zero, size: pageSize)
                context.beginPage(withBounds: pageRect, pageInfo: [:])
                let available = pageRect.insetBy(dx: options.margin, dy: options.margin)
                let scale = options.fit == .fit
                    ? min(available.width / imageSize.width, available.height / imageSize.height)
                    : max(available.width / imageSize.width, available.height / imageSize.height)
                let drawSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
                let drawRect = CGRect(x: available.midX - drawSize.width / 2, y: available.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
                let cg = context.cgContext
                cg.saveGState()
                cg.clip(to: available)
                cg.translateBy(x: 0, y: pageSize.height)
                cg.scaleBy(x: 1, y: -1)
                cg.draw(image, in: CGRect(x: drawRect.minX, y: pageSize.height - drawRect.maxY, width: drawRect.width, height: drawRect.height))
                cg.restoreGState()
            }
        }
        if failures == imageURLs.count { throw DocumentError.unreadable("None of the images could be read.") }
        return data
    }

    /// Loads an image upright (EXIF orientation applied), downsampled, and JPEG-recompressed
    /// so CoreGraphics can embed it with DCT compression.
    static func loadImage(_ url: URL, maxPixelSize: CGFloat?, quality: CGFloat) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if let maxPixelSize {
            options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize
        } else if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
                  let height = properties[kCGImagePropertyPixelHeight] as? CGFloat {
            options[kCGImageSourceThumbnailMaxPixelSize] = max(width, height)
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
        if hasAlpha { return image }
        guard let jpeg = PDFRasterizer.encode(image, type: .jpeg, quality: quality),
              let jpegSource = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(jpegSource, 0, nil)
        else { return image }
        return decoded
    }
}

enum PDFToImages {
    enum Format: String, CaseIterable, Identifiable, Hashable, Sendable {
        case jpeg, png, heic, tiff

        var id: String { rawValue }
        var label: String { rawValue == "jpeg" ? "JPEG" : rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
        var utType: UTType {
            switch self {
            case .jpeg: .jpeg
            case .png: .png
            case .heic: .heic
            case .tiff: .tiff
            }
        }
    }

    static func render(_ document: PDFDocument, pages: [Int]? = nil, format: Format, dpi: CGFloat, quality: CGFloat = 0.9) throws -> [(index: Int, data: Data)] {
        let indices = pages ?? Array(0 ..< document.pageCount)
        var output: [(Int, Data)] = []
        for index in indices {
            guard let page = document.page(at: index),
                  let image = PDFRasterizer.image(page: page, dpi: dpi),
                  let data = PDFRasterizer.encode(image, type: format.utType, quality: quality, dpi: dpi)
            else { throw DocumentError.writeFailed("Page \(index + 1) couldn't be rendered.") }
            output.append((index, data))
        }
        return output
    }

    /// One multi-page TIFF containing every selected page.
    static func multipageTIFF(_ document: PDFDocument, pages: [Int]? = nil, dpi: CGFloat) throws -> Data {
        let indices = pages ?? Array(0 ..< document.pageCount)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.tiff.identifier as CFString, indices.count, nil) else {
            throw DocumentError.writeFailed("TIFF encoder unavailable.")
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: dpi,
            kCGImagePropertyDPIHeight: dpi,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFCompression: 5] // LZW
        ]
        for index in indices {
            guard let page = document.page(at: index), let image = PDFRasterizer.image(page: page, dpi: dpi) else { continue }
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw DocumentError.writeFailed("TIFF encoding failed.") }
        return data as Data
    }
}

/// Pulls the images out of a PDF as they appear on screen (see `PDFPageImages`).
enum PDFImageExtractor {
    struct ExtractedImage {
        let pageIndex: Int
        let data: Data
        let fileExtension: String
    }

    static func extract(_ document: PDFDocument, pages: [Int]? = nil, minimumSide: Int = 16) -> [ExtractedImage] {
        var seen: Set<Data> = []
        return PDFPageImages.images(in: document, pages: pages, minimumSide: minimumSide, includeUnplaced: true).compactMap { placed in
            // The same picture embedded on several pages is saved once.
            guard seen.insert(placed.image.data).inserted else { return nil }
            return ExtractedImage(pageIndex: placed.pageIndex, data: placed.image.data, fileExtension: placed.image.fileExtension)
        }
    }
}
