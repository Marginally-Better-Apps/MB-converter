import SwiftUI
import UIKit

/// App color tokens. System semantic colors give every screen the native
/// iOS look; the blue from the app icon carries interaction and ambience.
enum Theme {

    // MARK: - Brand

    /// The app-wide interaction tint, taken from the middle of the icon's
    /// sky-to-navy gradient and saturated so it reads as a system accent.
    /// Light: 5.7:1 on white. Dark: 4.9:1 on grouped surfaces, 3.5:1 under white labels.
    static let tint = dynamic(light: 0x0E6BA8, dark: 0x2B8FD6)

    /// Kept for older call sites; equal to `tint`.
    static var primary: Color { tint }

    /// The app icon's gradient stops.
    static let brandSky = Color(hex: 0xA3DDFF)
    static let brandMid = Color(hex: 0x4F8CB5)
    static let brandNavy = Color(hex: 0x003A5C)

    /// The app icon's diagonal gradient, used for hero artwork.
    static var brandGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x7CC4F2), Color(hex: 0x2F78AE), Color(hex: 0x0B3F63)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// Settings-style icon tiles: a vertical sheen over the tint.
    static var iconGradient: LinearGradient {
        LinearGradient(
            colors: [Color(hex: 0x4BA6E6), Color(hex: 0x0E6BA8)],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Semantic roles

    static let text = Color(uiColor: .label)
    static let textMuted = Color(uiColor: .secondaryLabel)
    static let textTertiary = Color(uiColor: .tertiaryLabel)

    /// Canvas behind grouped content.
    static let background = Color(uiColor: .systemGroupedBackground)
    /// Cards and list rows that sit on `background`.
    static let surface = Color(uiColor: .secondarySystemGroupedBackground)
    /// Wells inside a card, such as text fields.
    static let fieldFill = Color(uiColor: .tertiarySystemFill)

    static var groupedBackground: Color { background }
    static var groupedSurface: Color { surface }

    /// Soft tint wash for selection backgrounds and quiet actions.
    static var secondaryFill: Color { tint.opacity(0.14) }
    /// Brief highlight for newly added content.
    static let secondary = dynamic(light: 0xD5EBFA, dark: 0x103A58)

    static let separator = Color(uiColor: .separator)
    /// Kept for older call sites; equal to `separator`.
    static var accent: Color { separator }

    static let disabledFill = Color(uiColor: .quaternarySystemFill)
    static let disabledSurface = Color(uiColor: .tertiarySystemGroupedBackground)

    static var destructive: Color { .red }
    static var success: Color { .green }

    // MARK: - Shape

    enum Radius {
        /// Grouped cards, matching iOS 26 inset lists.
        static let card: CGFloat = 26
        /// Large hero tiles.
        static let tile: CGFloat = 28
        /// Media inside a card.
        static let media: CGFloat = 18
        /// Fields and small wells.
        static let field: CGFloat = 12
    }

    // MARK: - Construction

    private static func dynamic(light: Int, dark: Int) -> Color {
        Color(UIColor { trait in
            UIColor(hex: trait.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension Color {
    init(hex: Int) {
        self.init(uiColor: UIColor(hex: hex))
    }
}

private extension UIColor {
    convenience init(hex: Int) {
        self.init(
            red: CGFloat((hex >> 16) & 0xff) / 255.0,
            green: CGFloat((hex >> 8) & 0xff) / 255.0,
            blue: CGFloat(hex & 0xff) / 255.0,
            alpha: 1
        )
    }
}

/// System grouped canvas with a soft wash of the icon's blue at the top,
/// like the ambient color behind Apple Music and TV headers.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(
                colors: [leadingGlow, leadingGlow.opacity(0)],
                center: UnitPoint(x: 0.1, y: -0.08),
                startRadius: 0,
                endRadius: 460
            )
            RadialGradient(
                colors: [trailingGlow, trailingGlow.opacity(0)],
                center: UnitPoint(x: 1.0, y: -0.02),
                startRadius: 0,
                endRadius: 380
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var leadingGlow: Color {
        colorScheme == .dark ? Color(hex: 0x0D4E7D).opacity(0.75) : Theme.brandSky.opacity(0.62)
    }

    private var trailingGlow: Color {
        colorScheme == .dark ? Color(hex: 0x1F6FA6).opacity(0.38) : Color(hex: 0x6FB5E6).opacity(0.28)
    }
}
