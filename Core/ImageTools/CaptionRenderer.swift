import CoreText
import UIKit

/// Draws captions (memes, watermarks, labels) as glyph outlines: the outline is stroked first with
/// round joins and the fill drawn over it, so overlapping glyph contours (common in system fonts)
/// never show seams and sharp corners don't sprout miter spikes. Emoji, which have no outlines,
/// are drawn as-is on top.
enum CaptionRenderer {
    enum Font: String, CaseIterable, Hashable, Sendable {
        case meme, bold, rounded, serif, marker

        var label: String {
            switch self {
            case .meme: "Meme"
            case .bold: "Bold"
            case .rounded: "Rounded"
            case .serif: "Serif"
            case .marker: "Marker"
            }
        }

        func uiFont(size: CGFloat) -> UIFont {
            switch self {
            // Condensed black is the closest iOS has to Impact.
            case .meme: UIFont(name: "HelveticaNeue-CondensedBlack", size: size) ?? .systemFont(ofSize: size, weight: .black)
            case .bold: .systemFont(ofSize: size, weight: .heavy)
            case .rounded:
                UIFont(descriptor: UIFont.systemFont(ofSize: size, weight: .heavy).fontDescriptor.withDesign(.rounded) ?? UIFont.systemFont(ofSize: size).fontDescriptor, size: size)
            case .serif: UIFont(name: "Georgia-Bold", size: size) ?? .systemFont(ofSize: size, weight: .bold)
            case .marker: UIFont(name: "MarkerFelt-Wide", size: size) ?? .systemFont(ofSize: size, weight: .bold)
            }
        }
    }

    /// A caption laid out in its own top-left-origin box, `width` wide and centered within it.
    struct Layout {
        let outlines: CGPath
        /// Runs without outlines (emoji), drawn in a y-up box of `size.height`.
        let bitmapRuns: [(run: CTRun, origin: CGPoint)]
        let size: CGSize
        let fontSize: CGFloat
        /// Tight bounds of the ink within the box (outline width not included).
        let inkBounds: CGRect
    }

    static func fontSize(_ caption: ImageToolkit.Caption, imageSize: CGSize) -> CGFloat {
        max(8, min(imageSize.width, imageSize.height) * caption.relativeSize)
    }

    static func layout(_ caption: ImageToolkit.Caption, imageSize: CGSize) -> Layout {
        let size = fontSize(caption, imageSize: imageSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.95
        let attributed = NSAttributedString(string: caption.text, attributes: [.font: caption.font.uiFont(size: size), .paragraphStyle: paragraph])
        let maxWidth = max(1, imageSize.width * 0.92)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let suggested = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(), nil, CGSize(width: maxWidth, height: .greatestFiniteMagnitude), nil)
        let box = CGRect(x: 0, y: 0, width: maxWidth, height: ceil(suggested.height) + 2)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: box, transform: nil), nil)
        let lines = CTFrameGetLines(frame) as? [CTLine] ?? []
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(), &origins)

        let outlines = CGMutablePath()
        var bitmapRuns: [(CTRun, CGPoint)] = []
        // CoreText is y-up; flip into the top-left-origin box.
        let flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: box.height)
        for (line, origin) in zip(lines, origins) {
            for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
                let count = CTRunGetGlyphCount(run)
                guard count > 0 else { continue }
                let attributes = CTRunGetAttributes(run) as NSDictionary
                let font = attributes[kCTFontAttributeName] as! CTFont // swiftlint:disable:this force_cast
                var glyphs = [CGGlyph](repeating: 0, count: count)
                var positions = [CGPoint](repeating: .zero, count: count)
                CTRunGetGlyphs(run, CFRange(), &glyphs)
                CTRunGetPositions(run, CFRange(), &positions)
                var missingOutlines = false
                for (glyph, position) in zip(glyphs, positions) {
                    if let path = CTFontCreatePathForGlyph(font, glyph, nil) {
                        outlines.addPath(path, transform: CGAffineTransform(translationX: origin.x + position.x, y: origin.y + position.y).concatenating(flip))
                    } else if CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) {
                        missingOutlines = true
                    }
                }
                if missingOutlines { bitmapRuns.append((run, origin)) }
            }
        }
        var ink = outlines.isEmpty ? .null : outlines.boundingBoxOfPath
        for (run, origin) in bitmapRuns {
            var bounds = CTRunGetImageBounds(run, nil, CFRange())
            bounds = bounds.offsetBy(dx: origin.x, dy: origin.y).applying(flip)
            ink = ink.union(bounds)
        }
        if ink.isNull { ink = CGRect(x: box.width / 2, y: box.height / 2, width: 0, height: 0) }
        return Layout(outlines: outlines, bitmapRuns: bitmapRuns, size: box.size, fontSize: size, inkBounds: ink)
    }

    static func outlineWidth(_ layout: Layout) -> CGFloat { layout.fontSize * 0.16 }

    /// Center of the caption's ink in image pixels (top-left origin).
    static func center(_ caption: ImageToolkit.Caption, layout: Layout, imageSize: CGSize) -> CGPoint {
        if let position = caption.position {
            return CGPoint(x: position.x * imageSize.width, y: position.y * imageSize.height)
        }
        let margin = min(imageSize.width, imageSize.height) * 0.04 + (caption.outlined ? outlineWidth(layout) / 2 : 0)
        return PDFStamper.anchor(for: caption.placement, size: imageSize, item: layout.inkBounds.size, margin: margin)
    }

    /// The caption's ink rectangle in image pixels, ignoring rotation (for hit-testing and tests).
    static func frame(_ caption: ImageToolkit.Caption, imageSize: CGSize) -> CGRect {
        let layout = layout(caption, imageSize: imageSize)
        let center = center(caption, layout: layout, imageSize: imageSize)
        return CGRect(x: center.x - layout.inkBounds.width / 2, y: center.y - layout.inkBounds.height / 2,
                      width: layout.inkBounds.width, height: layout.inkBounds.height)
    }

    /// Draws the caption centered at `center` in a top-left-origin context.
    static func draw(_ caption: ImageToolkit.Caption, layout: Layout, at center: CGPoint, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        context.rotate(by: CGFloat(caption.rotation) * .pi / 180)
        context.translateBy(x: -layout.inkBounds.midX, y: -layout.inkBounds.midY)
        // One transparency layer, so a see-through caption doesn't show its outline under the fill.
        context.setAlpha(CGFloat(min(max(caption.opacity, 0), 1)))
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        if caption.outlined, !layout.outlines.isEmpty {
            context.addPath(layout.outlines)
            context.setLineJoin(.round)
            context.setLineCap(.round)
            context.setLineWidth(outlineWidth(layout))
            context.setStrokeColor(UIColor(hex: caption.outlineHex).cgColor)
            context.strokePath()
        }
        context.addPath(layout.outlines)
        context.setFillColor(UIColor(hex: caption.colorHex).cgColor)
        context.fillPath()
        if !layout.bitmapRuns.isEmpty {
            context.saveGState()
            context.translateBy(x: 0, y: layout.size.height)
            context.scaleBy(x: 1, y: -1)
            context.textMatrix = .identity
            for (run, origin) in layout.bitmapRuns {
                context.textPosition = origin
                CTRunDraw(run, context, CFRange())
            }
            context.restoreGState()
        }
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Draws a caption onto an image-sized, top-left-origin context, tiling it if asked.
    static func draw(_ caption: ImageToolkit.Caption, imageSize: CGSize, in context: CGContext) {
        guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let layout = layout(caption, imageSize: imageSize)
        if caption.placement == .tiled, caption.position == nil {
            let step = CGSize(width: max(layout.inkBounds.width * 1.4, 1), height: max(layout.inkBounds.height * 3, 1))
            var y = layout.inkBounds.height / 2
            while y < imageSize.height + step.height {
                var x = layout.inkBounds.width / 2
                while x < imageSize.width + step.width {
                    draw(caption, layout: layout, at: CGPoint(x: x, y: y), in: context)
                    x += step.width
                }
                y += step.height
            }
            return
        }
        draw(caption, layout: layout, at: center(caption, layout: layout, imageSize: imageSize), in: context)
    }

    /// The caption alone on a transparent background, cropped to its ink plus outline, for editors
    /// that move it over a preview. `scale` maps image pixels to the returned image's pixels.
    static func image(_ caption: ImageToolkit.Caption, imageSize: CGSize, scale: CGFloat) -> UIImage? {
        guard !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var upright = caption
        upright.rotation = 0
        let layout = layout(upright, imageSize: imageSize)
        let pad = outlineWidth(layout)
        let size = CGSize(width: (layout.inkBounds.width + pad * 2) * scale, height: (layout.inkBounds.height + pad * 2) * scale)
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            context.cgContext.scaleBy(x: scale, y: scale)
            draw(upright, layout: layout, at: CGPoint(x: layout.inkBounds.width / 2 + pad, y: layout.inkBounds.height / 2 + pad), in: context.cgContext)
        }
    }
}
