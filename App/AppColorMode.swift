import SwiftUI

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
