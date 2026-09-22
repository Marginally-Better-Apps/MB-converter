import SwiftUI
import UIKit

/// A compatibility bridge for older call sites. Every value maps directly to
/// an Apple semantic color so the system owns contrast and appearance.
enum Theme {
    static let text = Color.primary
    static let textMuted = Color.secondary
    static let background = Color(uiColor: .systemBackground)
    static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let groupedSurface = Color(uiColor: .secondarySystemGroupedBackground)
    static let disabledSurface = Color(uiColor: .tertiarySystemFill)
    static let primary = Color.accentColor
    static let secondary = Color(uiColor: .systemFill)
    static let accent = Color(uiColor: .separator)
    static let tint = Color.accentColor
    static let secondaryFill = Color(uiColor: .secondarySystemFill)
    static let separator = Color(uiColor: .separator)
    static let disabledFill = Color(uiColor: .tertiarySystemFill)
    static let destructive = Color.red
}

extension View {
    /// Uses native Liquid Glass on iOS 26 and a system material on earlier releases.
    @ViewBuilder
    func appleGlass(cornerRadius: CGFloat = 24, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if interactive {
                self.glassEffect(.regular.interactive(), in: .rect(cornerRadius: cornerRadius))
            } else {
                self.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            }
        } else {
            self
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 0.5)
                }
        }
    }

    @ViewBuilder
    func appleGlassButton(prominent: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            if prominent {
                self.buttonStyle(.glassProminent)
            } else {
                self.buttonStyle(.glass)
            }
        } else if prominent {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct AppleGlassControlGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    init(spacing: CGFloat = 10, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}
