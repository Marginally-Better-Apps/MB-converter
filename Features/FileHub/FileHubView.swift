import PDFKit
import SwiftUI

/// Landing screen for a document opened from Home: preview, one-tap conversions and relevant tools.
struct FileHubView: View {
    let file: ToolInputFile
    @Binding var path: [AppRoute]

    @State private var detail: String?
    @State private var preview: IdentifiableURLs?

    private var targets: [FileFormat] { ConversionTargets.targets(for: file.format) }

    private var tools: [ToolDefinition] {
        ToolCatalog.tools(accepting: file.format).filter { !$0.id.rawValue.hasPrefix("convert.") }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                fileCard
                if !targets.isEmpty { convertSection }
                if !tools.isEmpty { toolsSection }
                PrivacyNote()
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .screenBackground()
        .navigationTitle(file.format.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task { detail = await FileRow.details(for: file) }
        .sheet(item: $preview) { item in
            QuickLookSheet(urls: item.urls)
        }
    }

    private var fileCard: some View {
        Button {
            preview = IdentifiableURLs(urls: [file.url])
        } label: {
            HStack(spacing: Theme.Spacing.l) {
                FileThumbnail(url: file.url, size: CGSize(width: 72, height: 92), format: file.format)
                VStack(alignment: .leading, spacing: 6) {
                    Text(file.displayName)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        FormatBadge(text: file.format.badge)
                        Text(detail ?? file.byteCount.formattedBytes)
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Label("Preview", systemImage: "eye")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.tint)
                }
                Spacer(minLength: 0)
            }
            .card()
        }
        .buttonStyle(PressableStyle())
    }

    private var convertSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("Convert to")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Theme.Spacing.s)], spacing: Theme.Spacing.s) {
                ForEach(targets) { target in
                    Button {
                        Haptics.impact(.light)
                        open(target)
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: target.symbolName)
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.tint)
                            Text(target.badge)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                            Text(target.displayName.uppercased() == target.badge ? " " : target.displayName)
                                .font(.caption2)
                                .foregroundStyle(Theme.textMuted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 84)
                        .card(padding: 8, radius: Theme.Radius.medium)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Convert to \(target.displayName)")
                }
            }
        }
    }

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("Tools for this file")
            VStack(spacing: 0) {
                ForEach(Array(tools.enumerated()), id: \.element.id) { index, tool in
                    NavigationLink(value: AppRoute.tool(tool.id, inputs: [file])) {
                        ToolRowLabel(tool: tool)
                            .padding(.horizontal, Theme.Spacing.l)
                            .padding(.vertical, 11)
                    }
                    .buttonStyle(PressableStyle())
                    if index < tools.count - 1 {
                        Divider().overlay(Theme.separator).padding(.leading, 62)
                    }
                }
            }
            .card(padding: 0)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(Theme.textMuted)
            .padding(.leading, Theme.Spacing.xs)
    }

    private func open(_ target: FileFormat) {
        if file.format.family == .image, file.format != .svg, let format = ImageToolkit.OutputFormat(fileFormat: target) {
            path.append(.tool("image.convert", inputs: [file], preset: ["saveAs": format.rawValue]))
            return
        }
        if let preset = ToolCatalog.conversionTool(from: file.format, to: target) {
            path.append(.tool(preset.id, inputs: [file]))
        } else if file.format == .pdf, [.jpeg, .png, .tiff].contains(target) {
            let format = target == .jpeg ? "jpeg" : target.rawValue
            path.append(.tool("pdf.toimages", inputs: [file], preset: ["format": format]))
        } else {
            path.append(.tool("convert.any", inputs: [file], preset: ["target": target.rawValue]))
        }
    }
}
