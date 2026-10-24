import QuickLook
import QuickLookThumbnailing
import SwiftUI
import UIKit

// MARK: - Theme additions for the tools layer

extension Theme {
    /// Wells inside cards (search fields, thumbnails).
    static var surfaceSunken: Color { fieldFill }
    static var textFaint: Color { textTertiary }
    static var onPrimary: Color { .white }
    static var danger: Color { destructive }
    static var warning: Color { .orange }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    /// Category hues stay inside the icon's blue family so the palette stays calm.
    static func tint(for category: ToolCategory) -> Color {
        switch category {
        case .pdf: Color(hex: 0x1E6FB0)
        case .documents: Color(hex: 0x2F7FC1)
        case .spreadsheets: Color(hex: 0x1B7F96)
        case .images: Color(hex: 0x3E6CCB)
        case .video: Color(hex: 0x24589E)
        case .audio: Color(hex: 0x16809E)
        case .utilities: Color(hex: 0x4E6A86)
        }
    }

    static func gradient(for category: ToolCategory) -> LinearGradient {
        let base = tint(for: category)
        return LinearGradient(colors: [base.opacity(0.72), base], startPoint: .top, endPoint: .bottom)
    }
}

extension Theme.Radius {
    static let small: CGFloat = field
    static let medium: CGFloat = 16
    static let large: CGFloat = card
}

// MARK: - Surfaces

extension View {
    /// A solid grouped card, matching the rest of the app.
    func card(padding: CGFloat = Theme.Spacing.l, radius: CGFloat = Theme.Radius.card) -> some View {
        self
            .padding(padding)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// Standard page background used by tool screens.
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

/// A Settings-style tile tinted by tool category.
struct ToolGlyph: View {
    let symbol: String
    var category: ToolCategory?
    var size: CGFloat = 30

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.48, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                category.map { AnyShapeStyle(Theme.gradient(for: $0)) } ?? AnyShapeStyle(Theme.iconGradient),
                in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(Theme.onPrimary)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.tint.opacity(isEnabled ? 1 : 0.35), in: Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.tint)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(Theme.secondaryFill, in: Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
    }
}

/// Small rounded action used in rows of quick actions (Files, Photos, Paste…).
struct QuickActionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Theme.tint)
                .frame(height: 22)
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 64)
        .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
        .contentShape(Rectangle())
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Tool presentation

struct ToolRowLabel: View {
    let tool: ToolDefinition
    var showsChevron = true

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ToolGlyph(symbol: tool.symbol, category: tool.category, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.text)
                Text(tool.summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(tool.summary)
    }
}

struct ToolTile: View {
    let tool: ToolDefinition

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            ToolGlyph(symbol: tool.symbol, category: tool.category, size: 32)
            VStack(alignment: .leading, spacing: 3) {
                Text(tool.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(tool.summary)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 14, radius: Theme.Radius.large)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct CategoryRowLabel: View {
    let category: ToolCategory

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            ToolGlyph(symbol: category.symbol, category: category, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.text)
                Text(category.summary)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text("\(ToolCatalog.tools(in: category).count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.textFaint)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textFaint)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A format badge like "PDF" or "DOCX".
struct FormatBadge: View {
    let text: String
    var tint: Color = Theme.tint

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .tracking(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

// MARK: - Files

/// QuickLook-generated thumbnail with a symbol fallback.
struct FileThumbnail: View {
    let url: URL
    var size: CGSize = CGSize(width: 44, height: 44)
    var format: FileFormat?

    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.surfaceSunken)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .padding(2)
            } else {
                Image(systemName: (format ?? FileFormat(url: url))?.symbolName ?? "doc")
                    .font(.system(size: size.width * 0.38))
                    .foregroundStyle(Theme.textFaint)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.separator, lineWidth: 0.5)
        }
        .task(id: url) {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: displayScale, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).uiImage
        }
        .accessibilityHidden(true)
    }
}

struct QuickLookPreview: UIViewControllerRepresentable {
    let urls: [URL]
    var initialIndex = 0

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        controller.currentPreviewItemIndex = initialIndex
        return UINavigationController(rootViewController: controller)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(urls: urls) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let urls: [URL]
        private var items: [Int: QLPreviewItem] = [:]
        init(urls: [URL]) { self.urls = urls }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { urls.count }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            if let item = items[index] { return item }
            let item = QuickLookStandIn.item(for: urls[index])
            items[index] = item
            return item
        }
    }
}

/// A Quick Look item whose title stays the real file name even when a stand-in file is shown.
final class NamedPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        previewItemURL = url
        previewItemTitle = title
    }
}

/// Quick Look can't show OpenDocument, EPUB, Markdown or the rarer image formats on iOS.
/// For those, preview a faithful stand-in: the document rendered as a web page, or the image as PNG.
enum QuickLookStandIn {
    static let renderedFormats: Set<FileFormat> = [.odt, .ods, .epub, .markdown]

    static func item(for url: URL) -> QLPreviewItem {
        let title = url.lastPathComponent
        guard let format = FileFormat(url: url) else { return url as NSURL }
        let needsStandIn = renderedFormats.contains(format) || !QLPreviewController.canPreview(url as NSURL)
        guard needsStandIn, let standIn = try? standIn(for: url, format: format) else { return url as NSURL }
        return NamedPreviewItem(url: standIn, title: title)
    }

    private static func standIn(for url: URL, format: FileFormat) throws -> URL? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("previews", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = folder.appendingPathComponent(UUID().uuidString)
        switch format.family {
        case .image:
            return try Magick.pngProxy(for: url)
        case .spreadsheet:
            let document = try SpreadsheetConverter.read(url, format: format).asDocument()
            let output = base.appendingPathExtension("html")
            try HTMLWriter.data(document, options: .default).write(to: output)
            return output
        case .document, .presentation:
            let document = try DocumentConverter.read(url, format: format)
            let output = base.appendingPathExtension("html")
            try HTMLWriter.data(document, options: .default).write(to: output)
            return output
        default:
            return nil
        }
    }
}

struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// Presents the system "Save to Files" exporter for one or more files.
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    var onFinish: (Bool) -> Void = { _ in }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onFinish: (Bool) -> Void
        init(onFinish: @escaping (Bool) -> Void) { self.onFinish = onFinish }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onFinish(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onFinish(false) }
    }
}

struct IdentifiableURLs: Identifiable {
    let id = UUID()
    let urls: [URL]
    var index = 0
}

/// Footnote-style reassurance that processing never leaves the device.
struct PrivacyNote: View {
    var body: some View {
        Label {
            Text("Everything runs on your device. Files are never uploaded.")
        } icon: {
            Image(systemName: "lock.shield")
        }
        .font(.footnote)
        .foregroundStyle(Theme.textMuted)
        .frame(maxWidth: .infinity)
        .multilineTextAlignment(.center)
    }
}
