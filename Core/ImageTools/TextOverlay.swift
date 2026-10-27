import CoreGraphics
import Foundation

/// One text box placed on an image (a meme caption, a label, a watermark). Rendered by
/// `CaptionRenderer` both in the editor and in the output, so what you place is what you get.
struct TextOverlay: Hashable, Sendable, Identifiable {
    var id = UUID()
    var text: String
    /// Center as fractions of the image (top-left origin). nil = `anchor` (until the box is dragged).
    var center: CGPoint?
    var anchor: PDFStamper.Placement = .center
    /// Font size as a fraction of the image's short side.
    var relativeSize: Double = 0.1
    var rotation: Double = 0
    var font: CaptionRenderer.Font = .meme
    var colorHex: UInt32 = 0xFFFFFF
    var outlined = true
    var allCaps = false
    var opacity: Double = 1

    /// Which boxes a tool starts with and which style controls its editor shows.
    enum Preset: Hashable, Sendable {
        /// Top and bottom captions in the meme style; boxes can be added anywhere.
        case meme
        /// One label in the corner, with opacity; repeats on every image.
        case watermark
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var caption: ImageToolkit.Caption {
        ImageToolkit.Caption(
            text: allCaps ? text.uppercased() : text,
            placement: anchor,
            relativeSize: relativeSize,
            colorHex: colorHex,
            opacity: opacity,
            outlined: outlined,
            rotation: rotation,
            font: font,
            position: center
        )
    }

    static func defaults(for preset: Preset) -> [TextOverlay] {
        switch preset {
        case .meme:
            [TextOverlay(text: "", anchor: .top, allCaps: true), TextOverlay(text: "", anchor: .bottom, allCaps: true)]
        case .watermark:
            [TextOverlay(text: "", anchor: .bottomRight, relativeSize: 0.06, font: .bold, opacity: 0.85)]
        }
    }

    /// A new box added by the user: in the middle, styled like the last box so it matches.
    static func added(after existing: [TextOverlay], preset: Preset) -> TextOverlay {
        var box = existing.last ?? defaults(for: preset)[0]
        box.id = UUID()
        box.text = ""
        box.center = CGPoint(x: 0.5, y: 0.5)
        box.rotation = 0
        return box
    }
}

extension ToolEditorState {
    /// Text boxes for a text tool: the user's, or the preset's starting boxes.
    func texts(for preset: TextOverlay.Preset) -> [TextOverlay] {
        textOverlays ?? TextOverlay.defaults(for: preset)
    }
}
