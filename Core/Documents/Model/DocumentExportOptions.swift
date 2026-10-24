import CoreGraphics
import Foundation

/// User-facing layout and typography choices applied when writing documents.
struct DocumentExportOptions: Hashable, Sendable {
    var pageSize: PageSize = .a4
    var orientation: PageOrientation = .portrait
    var margins: PageMargins = .normal
    var fontFamily: FontChoice = .serif
    /// Body text size in points.
    var fontSize: Double = 11
    var lineSpacing: Double = 1.25
    var includeImages = true
    var pageNumbers = false
    /// Overrides document metadata when set.
    var title: String?
    var author: String?

    static let `default` = DocumentExportOptions()

    var pageRect: CGRect {
        let size = pageSize.points
        let oriented = orientation == .landscape
            ? CGSize(width: max(size.width, size.height), height: min(size.width, size.height))
            : CGSize(width: min(size.width, size.height), height: max(size.width, size.height))
        return CGRect(origin: .zero, size: oriented)
    }

    var marginPoints: CGFloat { margins.points }
}

enum PageSize: String, CaseIterable, Identifiable, Hashable, Sendable {
    case a4, letter, legal, a5, a3

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4: "A4"
        case .letter: "US Letter"
        case .legal: "US Legal"
        case .a5: "A5"
        case .a3: "A3"
        }
    }

    var points: CGSize {
        switch self {
        case .a4: CGSize(width: 595.28, height: 841.89)
        case .letter: CGSize(width: 612, height: 792)
        case .legal: CGSize(width: 612, height: 1008)
        case .a5: CGSize(width: 419.53, height: 595.28)
        case .a3: CGSize(width: 841.89, height: 1190.55)
        }
    }

    /// Default for the user's region: Letter in North America, A4 elsewhere.
    static var regionalDefault: PageSize {
        let region = Locale.current.region?.identifier ?? ""
        return ["US", "CA", "MX", "PH", "CL", "CO", "VE"].contains(region) ? .letter : .a4
    }
}

enum PageOrientation: String, CaseIterable, Identifiable, Hashable, Sendable {
    case portrait, landscape
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum PageMargins: String, CaseIterable, Identifiable, Hashable, Sendable {
    case none, narrow, normal, wide

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .none: 0
        case .narrow: 36
        case .normal: 72
        case .wide: 108
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable, Hashable, Sendable {
    case serif, sans, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans Serif"
        case .mono: "Monospace"
        }
    }

    /// CSS font stack for HTML/PDF/EPUB output.
    var cssStack: String {
        switch self {
        case .serif: "'Iowan Old Style', 'Times New Roman', Georgia, serif"
        case .sans: "-apple-system, 'Helvetica Neue', Helvetica, Arial, sans-serif"
        case .mono: "Menlo, 'SF Mono', Courier, monospace"
        }
    }

    /// Font name written into DOCX/ODT/RTF where the consumer picks its own fallback.
    var officeFontName: String {
        switch self {
        case .serif: "Times New Roman"
        case .sans: "Helvetica"
        case .mono: "Courier New"
        }
    }
}
