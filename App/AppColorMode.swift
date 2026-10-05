import SwiftUI
import UIKit

enum AppColorMode: String {
    case system
    case light
    case dark

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }

    init(colorScheme: ColorScheme?) {
        switch colorScheme {
        case .light:
            self = .light
        case .dark:
            self = .dark
        default:
            self = .system
        }
    }
}

/// Apply appearance to the window so presented sheets also return to the system
/// style immediately. Clearing a sheet's SwiftUI color-scheme preference can
/// otherwise leave its hosting controller using the previous explicit style.
struct AppAppearance: UIViewRepresentable {
    let mode: AppColorMode

    func makeUIView(context: Context) -> AppearanceView {
        AppearanceView()
    }

    func updateUIView(_ view: AppearanceView, context: Context) {
        switch mode {
        case .system: view.style = .unspecified
        case .light: view.style = .light
        case .dark: view.style = .dark
        }
    }

    final class AppearanceView: UIView {
        var style: UIUserInterfaceStyle = .unspecified {
            didSet { applyAppearance() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyAppearance()
        }

        private func applyAppearance() {
            guard let window, window.overrideUserInterfaceStyle != style else { return }
            window.overrideUserInterfaceStyle = style
        }
    }
}
