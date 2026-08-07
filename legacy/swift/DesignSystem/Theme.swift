import SwiftUI
import UIKit

/// App color tokens. Resolves automatically on light/dark trait changes.
/// Inline hex values — no Asset Catalog setup needed.
enum Theme {

    // Light hex            // Dark hex
    static let text       = dynamic(light: 0x050b0f, dark: 0xf0f6fa)
    static let background = dynamic(light: 0xeff6fb, dark: 0x0B1622)
    static let primary    = dynamic(light: 0x003a5c, dark: 0xa3ddff)
    static let secondary  = dynamic(light: 0x7fc7f0, dark: 0x0f5680)
    /// In dark mode this is INTENTIONALLY darker than background — use for
    /// dividers, card borders, disabled states. For actionable accents in dark
    /// mode, use `Theme.primary`.
    static let accent     = dynamic(light: 0x3cb2f6, dark: 0x081d2a)

    // MARK: - Surface helpers

    /// Slightly elevated surface for cards, derived from background.
    static var surface: Color {
        dynamic(light: 0xffffff, dark: 0x152233)
    }

    /// Subtle text for secondary labels.
    static var textMuted: Color {
        dynamic(light: 0x4a5660, dark: 0x9aa9b8)
    }

    // MARK: - Construction

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(UIColor { trait in
            let hex = trait.userInterfaceStyle == .dark ? dark : light
            return UIColor.fromHex(hex)
        })
    }
}

private extension UIColor {
    static func fromHex(_ hex: Int) -> UIColor {
        UIColor(
            red:   CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >>  8) & 0xff) / 255.0,
            blue:  CGFloat( hex        & 0xff) / 255.0,
            alpha: 1
        )
    }
}
