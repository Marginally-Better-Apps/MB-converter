import CoreGraphics
import CoreText
import Foundation
import PDFKit
import UIKit

/// Re-renders PDF pages into a new document with content drawn on top (or underneath).
/// Vector page content and text survive; only pages marked for rasterization are flattened to pixels.
enum PDFStamper {
    typealias Overlay = (_ context: CGContext, _ pageIndex: Int, _ size: CGSize) -> Void

    static func render(
        _ source: PDFDocument,
        underlay: Overlay? = nil,
        overlay: Overlay? = nil,
        rasterize: (Int) -> Bool = { _ in false },
        rasterDPI: CGFloat = 200,
        grayscale: Bool = false
    ) -> Data {
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = documentInfo(from: source)
        let firstSize = source.page(at: 0).map { PDFRasterizer.displaySize(of: $0) } ?? CGSize(width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: firstSize), format: format)
        return renderer.pdfData { context in
            for index in 0 ..< source.pageCount {
                guard let page = source.page(at: index) else { continue }
                let size = PDFRasterizer.displaySize(of: page)
                let bounds = CGRect(origin: .zero, size: size)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                let cg = context.cgContext
                if rasterize(index) || grayscale {
                    // Compose page + overlays in a bitmap so nothing underneath survives (redaction, grayscale).
                    if let image = composedImage(page: page, index: index, size: size, dpi: rasterDPI, grayscale: grayscale, underlay: underlay, overlay: overlay) {
                        cg.saveGState()
                        cg.translateBy(x: 0, y: size.height)
                        cg.scaleBy(x: 1, y: -1)
                        cg.draw(image, in: bounds)
                        cg.restoreGState()
                    }
                    continue
                }
                if let underlay {
                    cg.saveGState(); underlay(cg, index, size); cg.restoreGState()
                }
                PDFRasterizer.draw(page, in: cg, size: size)
                if let overlay {
                    cg.saveGState(); overlay(cg, index, size); cg.restoreGState()
                }
            }
        }
    }

    private static func composedImage(page: PDFPage, index: Int, size: CGSize, dpi: CGFloat, grayscale: Bool, underlay: Overlay?, overlay: Overlay?) -> CGImage? {
        let scale = dpi / 72
        let pixelSize = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: pixelSize, format: format).image { context in
            let cg = context.cgContext
            UIColor.white.setFill()
            cg.fill(CGRect(origin: .zero, size: pixelSize))
            cg.scaleBy(x: scale, y: scale)
            if let underlay { cg.saveGState(); underlay(cg, index, size); cg.restoreGState() }
            PDFRasterizer.draw(page, in: cg, size: size)
            if let overlay { cg.saveGState(); overlay(cg, index, size); cg.restoreGState() }
        }
        guard var cgImage = image.cgImage else { return nil }
        if grayscale, let gray = ImageToolkit.grayscale(cgImage) { cgImage = gray }
        // Re-encode as JPEG so rasterized pages stay small.
        if let jpeg = PDFRasterizer.encode(cgImage, type: .jpeg, quality: 0.82),
           let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
           let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            return decoded
        }
        return cgImage
    }

    static func documentInfo(from source: PDFDocument) -> [String: Any] {
        var info: [String: Any] = [kCGPDFContextCreator as String: "MB Converter"]
        let attributes = source.documentAttributes ?? [:]
        if let title = attributes[PDFDocumentAttribute.titleAttribute] as? String { info[kCGPDFContextTitle as String] = title }
        if let author = attributes[PDFDocumentAttribute.authorAttribute] as? String { info[kCGPDFContextAuthor as String] = author }
        if let subject = attributes[PDFDocumentAttribute.subjectAttribute] as? String { info[kCGPDFContextSubject as String] = subject }
        return info
    }

    // MARK: - Watermark

    enum Placement: String, CaseIterable, Identifiable, Hashable, Sendable {
        case center, tiled, top, bottom, topLeft, topRight, bottomLeft, bottomRight

        var id: String { rawValue }
        var label: String {
            switch self {
            case .center: "Center"
            case .tiled: "Tiled"
            case .top: "Top"
            case .bottom: "Bottom"
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
    }

    struct TextWatermark: Hashable, Sendable {
        var text: String
        var fontSize: CGFloat = 48
        var colorHex: UInt32 = 0x9AA5B1
        var opacity: CGFloat = 0.35
        var rotation: CGFloat = -35
        var placement: Placement = .center
        var behindContent = false
        var bold = true
    }

    static func watermark(_ source: PDFDocument, _ mark: TextWatermark, pages: Set<Int>? = nil) -> Data {
        let draw: Overlay = { context, index, size in
            guard pages == nil || pages!.contains(index) else { return }
            drawText(mark, in: context, size: size)
        }
        return mark.behindContent ? render(source, underlay: draw) : render(source, overlay: draw)
    }

    static func drawText(_ mark: TextWatermark, in context: CGContext, size: CGSize) {
        let font = mark.bold ? UIFont.systemFont(ofSize: mark.fontSize, weight: .bold) : UIFont.systemFont(ofSize: mark.fontSize)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor(hex: mark.colorHex).withAlphaComponent(mark.opacity)
        ]
        let text = mark.text as NSString
        let textSize = text.size(withAttributes: attributes)
        func stamp(at center: CGPoint) {
            UIGraphicsPushContext(context)
            context.saveGState()
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: mark.rotation * .pi / 180)
            text.draw(at: CGPoint(x: -textSize.width / 2, y: -textSize.height / 2), withAttributes: attributes)
            context.restoreGState()
            UIGraphicsPopContext()
        }
        let margin: CGFloat = 36
        switch mark.placement {
        case .tiled:
            let stepX = max(textSize.width * 1.2, 120)
            let stepY = max(textSize.height * 3.5, 120)
            var row = 0
            var y: CGFloat = 0
            while y < size.height + stepY {
                var x: CGFloat = row % 2 == 0 ? 0 : stepX / 2
                while x < size.width + stepX {
                    stamp(at: CGPoint(x: x, y: y))
                    x += stepX
                }
                y += stepY
                row += 1
            }
        default:
            stamp(at: anchor(for: mark.placement, size: size, item: textSize, margin: margin))
        }
    }

    static func anchor(for placement: Placement, size: CGSize, item: CGSize, margin: CGFloat) -> CGPoint {
        let left = margin + item.width / 2
        let right = size.width - margin - item.width / 2
        let top = margin + item.height / 2
        let bottom = size.height - margin - item.height / 2
        switch placement {
        case .center, .tiled: return CGPoint(x: size.width / 2, y: size.height / 2)
        case .top: return CGPoint(x: size.width / 2, y: top)
        case .bottom: return CGPoint(x: size.width / 2, y: bottom)
        case .topLeft: return CGPoint(x: left, y: top)
        case .topRight: return CGPoint(x: right, y: top)
        case .bottomLeft: return CGPoint(x: left, y: bottom)
        case .bottomRight: return CGPoint(x: right, y: bottom)
        }
    }

    struct ImageWatermark: Hashable, Sendable {
        var imageData: Data
        /// Width as a fraction of the page width.
        var relativeWidth: CGFloat = 0.3
        var opacity: CGFloat = 0.5
        var placement: Placement = .center
    }

    static func watermark(_ source: PDFDocument, image mark: ImageWatermark, pages: Set<Int>? = nil) -> Data {
        guard let image = UIImage(data: mark.imageData) else { return source.dataRepresentation() ?? Data() }
        return render(source, overlay: { context, index, size in
            guard pages == nil || pages!.contains(index) else { return }
            let width = size.width * mark.relativeWidth
            let height = width * image.size.height / max(image.size.width, 1)
            let itemSize = CGSize(width: width, height: height)
            UIGraphicsPushContext(context)
            if mark.placement == .tiled {
                var y: CGFloat = 0
                while y < size.height {
                    var x: CGFloat = 0
                    while x < size.width {
                        image.draw(in: CGRect(origin: CGPoint(x: x, y: y), size: itemSize), blendMode: .normal, alpha: mark.opacity)
                        x += width * 1.5
                    }
                    y += height * 1.5
                }
            } else {
                let center = anchor(for: mark.placement, size: size, item: itemSize, margin: 36)
                image.draw(in: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height), blendMode: .normal, alpha: mark.opacity)
            }
            UIGraphicsPopContext()
        })
    }

    // MARK: - Page numbers

    enum NumberFormat: String, CaseIterable, Identifiable, Hashable, Sendable {
        case plain, page, pageOfTotal, slashTotal

        var id: String { rawValue }
        var label: String {
            switch self {
            case .plain: "1"
            case .page: "Page 1"
            case .pageOfTotal: "Page 1 of 9"
            case .slashTotal: "1 / 9"
            }
        }

        func text(number: Int, total: Int) -> String {
            switch self {
            case .plain: "\(number)"
            case .page: "Page \(number)"
            case .pageOfTotal: "Page \(number) of \(total)"
            case .slashTotal: "\(number) / \(total)"
            }
        }
    }

    struct PageNumbering: Hashable, Sendable {
        var format: NumberFormat = .plain
        var placement: Placement = .bottom
        var fontSize: CGFloat = 10
        var startAt = 1
        var skipFirstPage = false
        var margin: CGFloat = 28
    }

    static func addPageNumbers(_ source: PDFDocument, _ numbering: PageNumbering) -> Data {
        let total = source.pageCount - (numbering.skipFirstPage ? 1 : 0) + numbering.startAt - 1
        return render(source, overlay: { context, index, size in
            if numbering.skipFirstPage, index == 0 { return }
            let number = index + numbering.startAt - (numbering.skipFirstPage ? 1 : 0)
            let text = numbering.format.text(number: number, total: total) as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.monospacedDigitSystemFont(ofSize: numbering.fontSize, weight: .regular),
                .foregroundColor: UIColor(white: 0.25, alpha: 1)
            ]
            let textSize = text.size(withAttributes: attributes)
            let placement = numbering.placement == .center || numbering.placement == .tiled ? .bottom : numbering.placement
            let center = anchor(for: placement, size: size, item: textSize, margin: numbering.margin)
            UIGraphicsPushContext(context)
            text.draw(at: CGPoint(x: center.x - textSize.width / 2, y: center.y - textSize.height / 2), withAttributes: attributes)
            UIGraphicsPopContext()
        })
    }

    // MARK: - Overlay items (edit, sign, annotate, redact)

    static func apply(_ items: [PDFOverlayItem], to source: PDFDocument) -> Data {
        let byPage = Dictionary(grouping: items, by: \.pageIndex)
        let redactedPages = Set(items.filter { $0.kind == .redaction }.map(\.pageIndex))
        return render(source, overlay: { context, index, size in
            for item in byPage[index] ?? [] {
                draw(item, in: context, pageSize: size)
            }
        }, rasterize: { redactedPages.contains($0) })
    }

    static func draw(_ item: PDFOverlayItem, in context: CGContext, pageSize: CGSize) {
        let rect = CGRect(
            x: item.frame.minX * pageSize.width,
            y: item.frame.minY * pageSize.height,
            width: item.frame.width * pageSize.width,
            height: item.frame.height * pageSize.height
        )
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        switch item.kind {
        case .text(let string, let fontSize, let colorHex, let bold):
            let font = bold ? UIFont.systemFont(ofSize: fontSize, weight: .semibold) : UIFont.systemFont(ofSize: fontSize)
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            (string as NSString).draw(
                with: rect,
                options: [.usesLineFragmentOrigin],
                attributes: [.font: font, .foregroundColor: UIColor(hex: colorHex), .paragraphStyle: paragraph],
                context: nil
            )
        case .image(let data):
            UIImage(data: data)?.draw(in: rect)
        case .highlight(let colorHex):
            context.setBlendMode(.multiply)
            UIColor(hex: colorHex).withAlphaComponent(0.45).setFill()
            context.fill(rect)
        case .whiteout:
            UIColor.white.setFill()
            context.fill(rect)
        case .redaction:
            UIColor.black.setFill()
            context.fill(rect)
        case .rectangle(let colorHex, let lineWidth):
            UIColor(hex: colorHex).setStroke()
            context.setLineWidth(lineWidth)
            context.stroke(rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
        case .strikeLine(let colorHex):
            UIColor(hex: colorHex).setStroke()
            context.setLineWidth(max(1, rect.height * 0.12))
            context.move(to: CGPoint(x: rect.minX, y: rect.midY))
            context.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            context.strokePath()
        }
    }

    /// Converts a selection's bounds on a page to a normalized, top-left-origin frame.
    static func normalizedFrame(of rect: CGRect, on page: PDFPage) -> CGRect {
        let size = PDFRasterizer.displaySize(of: page)
        let transformed = rect.applying(page.transform(for: .cropBox))
        let topLeft = CGRect(x: transformed.minX, y: size.height - transformed.maxY, width: transformed.width, height: transformed.height)
        return CGRect(
            x: topLeft.minX / size.width,
            y: topLeft.minY / size.height,
            width: topLeft.width / size.width,
            height: topLeft.height / size.height
        )
    }

    /// Finds every occurrence of the given terms and returns redaction boxes for them.
    static func redactionItems(for terms: [String], in document: PDFDocument, caseSensitive: Bool = false) -> [PDFOverlayItem] {
        var items: [PDFOverlayItem] = []
        for term in terms.compactMap(\.nilIfBlank) {
            let options: NSString.CompareOptions = caseSensitive ? [] : [.caseInsensitive]
            for selection in document.findString(term, withOptions: options) {
                for page in selection.pages {
                    let index = document.index(for: page)
                    for line in selection.selectionsByLine() {
                        let bounds = line.bounds(for: page)
                        guard bounds.width > 0, bounds.height > 0 else { continue }
                        let frame = normalizedFrame(of: bounds.insetBy(dx: -1, dy: -1), on: page)
                        items.append(PDFOverlayItem(pageIndex: index, frame: frame, kind: .redaction))
                    }
                }
            }
        }
        return items
    }

    // MARK: - Invisible text (searchable layers)

    /// Draws text that is selectable and searchable but not visible, fitted to `rect` (top-left space).
    static func drawInvisibleText(_ text: String, in rect: CGRect, context: CGContext) {
        guard !text.isEmpty, rect.width > 1, rect.height > 1 else { return }
        let fontSize = max(1, rect.height * 0.82)
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard width > 0 else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        context.textMatrix = .identity
        context.translateBy(x: rect.minX, y: rect.maxY - rect.height * 0.18)
        context.scaleBy(x: rect.width / width, y: -1)
        context.textPosition = .zero
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

struct PDFOverlayItem: Hashable, Identifiable, Sendable {
    enum Kind: Hashable, Sendable {
        case text(String, fontSize: CGFloat, colorHex: UInt32, bold: Bool)
        case image(Data)
        case highlight(colorHex: UInt32)
        case whiteout
        case redaction
        case rectangle(colorHex: UInt32, lineWidth: CGFloat)
        case strikeLine(colorHex: UInt32)
    }

    let id: UUID
    var pageIndex: Int
    /// Normalized (0…1) frame with a top-left origin, independent of zoom level.
    var frame: CGRect
    var kind: Kind

    init(id: UUID = UUID(), pageIndex: Int, frame: CGRect, kind: Kind) {
        self.id = id
        self.pageIndex = pageIndex
        self.frame = frame
        self.kind = kind
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
