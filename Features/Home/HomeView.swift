import Combine
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Binding var path: [AppRoute]
    /// Opens the History tab from the Recent shelf.
    var onShowHistory: (() -> Void)? = nil
    /// Preview-only state injection. Production call sites use the default `nil` value.
    var previewImportProgress: RemoteDownloadProgress? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var viewModel = HomeViewModel()
    @State private var historyStore = ConversionHistoryStore.shared
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var selectedVideoItem: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var isLinkImportPresented = false
    @State private var linkURLText = ""
    @State private var pasteboardRefreshTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                featuredSources

                if isImporting {
                    importStatusCard
                        .transition(
                            accessibilityReduceMotion
                                ? .opacity
                                : .move(edge: .top).combined(with: .opacity)
                        )
                }

                moreSources

                if !recentEntries.isEmpty {
                    recentConversions
                }

                if horizontalSizeClass == .regular {
                    homeDropHint
                }

                homeFooter
            }
            .padding(.horizontal, contentMargin)
            .padding(.top, 6)
            .padding(.bottom, 28)
            // Full width, like Apple Music on iPad, so content lines up with the large title.
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(
                accessibilityReduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.85),
                value: isImporting
            )
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { AmbientBackground() }
        .navigationTitle("MB Converter")
        .navigationBarTitleDisplayMode(.large)
        .settingsToolbarButton()
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImporter(result)
        }
        .onChange(of: selectedImageItem) { _, item in
            guard let item else { return }
            Task {
                await importPhotoLibraryItem(item)
                selectedImageItem = nil
            }
        }
        .onChange(of: selectedVideoItem) { _, item in
            guard let item else { return }
            Task {
                await importPhotoLibraryItem(item)
                selectedVideoItem = nil
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
                viewModel.refreshPasteboard()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
            viewModel.refreshPasteboard()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.removedNotification)) { _ in
            viewModel.refreshPasteboard()
        }
        .onReceive(pasteboardRefreshTimer) { _ in
            guard scenePhase == .active else { return }
            viewModel.refreshPasteboardIfNeeded()
        }
        .onAppear {
            viewModel.refreshPasteboard()
            historyStore.refreshForCurrentSettings()
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            Haptics.impact(.medium)
            Task { await importFile(url) }
            return true
        }
        .alert("Import Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Please try again.")
        }
        .alert("Import from Link", isPresented: $isLinkImportPresented) {
            TextField("https://", text: $linkURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) {
                Haptics.impact(.light)
                linkURLText = ""
            }
            Button("Download") {
                Haptics.impact(.medium)
                let text = linkURLText
                linkURLText = ""
                Task { await importFromRemoteLink(text) }
            }
        } message: {
            Text("The file must be a supported format and 150 MB or smaller. Use a direct link to the file when possible.")
        }
    }

    // MARK: - Sources

    /// Photos and Videos lead, as large artwork tiles.
    private var featuredSources: some View {
        LazyVGrid(columns: tileColumns, spacing: 14) {
            PhotosPicker(
                selection: $selectedImageItem,
                matching: .images,
                preferredItemEncoding: .current
            ) {
                SourceHeroTile(
                    title: "Photos",
                    subtitle: "Choose an image",
                    systemImage: "photo.on.rectangle.angled",
                    palette: .sky
                )
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.impact(.light) })
            .accessibilityLabel("Import an image from Photos")

            PhotosPicker(
                selection: $selectedVideoItem,
                matching: .videos,
                preferredItemEncoding: .current
            ) {
                SourceHeroTile(
                    title: "Videos",
                    subtitle: "Choose a video",
                    systemImage: "video.fill",
                    palette: .deep
                )
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.impact(.light) })
            .accessibilityLabel("Import a video from Photos")
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(isImporting)
    }

    private var moreSources: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "More Sources")

            VStack(spacing: 0) {
                Button {
                    Haptics.impact(.light)
                    isFileImporterPresented = true
                } label: {
                    SourceRow(
                        title: "Files",
                        subtitle: "Browse your device or cloud",
                        systemImage: "folder.fill"
                    )
                }
                .disabled(isImporting)
                .accessibilityLabel("Import from Files")

                rowDivider

                Button {
                    Haptics.impact(.light)
                    linkURLText = ""
                    isLinkImportPresented = true
                } label: {
                    SourceRow(
                        title: "From Link",
                        subtitle: "Download a media file",
                        systemImage: "link"
                    )
                }
                .disabled(isImporting)
                .accessibilityLabel("Import file from web link")
                .accessibilityHint("Downloads a supported media file up to 150 megabytes.")

                rowDivider

                Button {
                    Haptics.impact(.light)
                    Task { await importPasteboard() }
                } label: {
                    SourceRow(
                        title: "Clipboard",
                        subtitle: pasteboardSubtitle,
                        systemImage: "doc.on.clipboard.fill",
                        thumbnail: viewModel.pasteboardPreviewThumbnail
                    )
                }
                .disabled(viewModel.pasteboardImportLabel == nil || isImporting)
                .accessibilityLabel(
                    viewModel.pasteboardImportLabel.map { "Paste \($0) from clipboard" } ?? "Paste from clipboard"
                )
            }
            .buttonStyle(RowButtonStyle())
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        }
    }

    private var rowDivider: some View {
        Divider()
            .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 62)
            .accessibilityHidden(true)
    }

    // MARK: - Recent

    private var recentEntries: [ConversionHistoryEntry] {
        Array(historyStore.entries.prefix(12))
    }

    /// The newest conversions, like Recently Played in Apple Music.
    private var recentConversions: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(
                title: "Recent",
                actionTitle: onShowHistory == nil ? nil : "See All",
                action: onShowHistory
            )

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(recentEntries) { entry in
                        Button {
                            Haptics.impact(.light)
                            path.append(.result(entry.input, entry.config, entry.result, fromHistory: true))
                        } label: {
                            RecentConversionCard(entry: entry)
                        }
                        .buttonStyle(PressableButtonStyle())
                        .disabled(isImporting)
                        .accessibilityHint("Opens the converted file")
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, contentMargin, for: .scrollContent)
            .padding(.horizontal, -contentMargin)
        }
    }

    // MARK: - Status and footer

    private var importStatusCard: some View {
        importStatusView
            .surfaceCard(padding: 18)
    }

    @ViewBuilder
    private var importStatusView: some View {
        if let progress = previewImportProgress ?? viewModel.remoteDownloadProgress {
            DownloadProgressPrompt(progress: progress)
        } else {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.tint)
                Text("Importing…")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var homeDropHint: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.tint)
                .accessibilityHidden(true)

            Text("Drag a File Here")
                .font(.headline)
                .foregroundStyle(Theme.text)

            Text("Drop a file from Files to import it.")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 132)
        .background(
            Theme.surface.opacity(0.6),
            in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                .strokeBorder(
                    Theme.textTertiary,
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 6])
                )
        }
        .accessibilityElement(children: .combine)
    }

    private var homeFooter: some View {
        Text("Marginally Better Converter · Version \(bundleVersion)")
            .font(.footnote)
            .foregroundStyle(Theme.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Marginally Better Converter, version \(bundleVersion)")
    }

    // MARK: - Layout

    private var contentMargin: CGFloat {
        horizontalSizeClass == .regular ? 20 : 16
    }

    private var tileColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }

    private var isImporting: Bool {
        viewModel.isImporting || previewImportProgress != nil
    }

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var pasteboardSubtitle: String {
        guard let label = viewModel.pasteboardImportLabel else {
            return "No supported media copied"
        }

        let format = viewModel.pasteboardImportFileExtension ?? label
        var details = [format]
        if let fileSizeBytes = viewModel.pasteboardFileSizeBytes {
            details.append(ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file).lowercased())
        }
        if let duration = viewModel.pasteboardDuration {
            details.append(MetadataFormatter.durationText(duration))
        }
        return details.joined(separator: " • ")
    }

    private struct DownloadProgressPrompt: View {
        let progress: RemoteDownloadProgress

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Downloading from Link", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.text)

                    Spacer()

                    if let fraction = progress.fractionCompleted {
                        Text(percentText(for: fraction))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.tint)
                            .monospacedDigit()
                    }
                }

                ProgressView(value: progress.displayFraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Theme.tint)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(
                        progress.fractionCompleted.map { percentText(for: $0) } ?? byteText
                    )

                Text(byteText)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private var byteText: String {
            let received = Self.byteFormatter.string(fromByteCount: progress.bytesReceived)
            if let totalBytes = progress.totalBytes {
                let total = Self.byteFormatter.string(fromByteCount: totalBytes)
                return "\(received) of \(total)"
            }
            return "\(received) downloaded"
        }

        private func percentText(for fraction: Double) -> String {
            "\(Int((fraction * 100).rounded()))%"
        }

        private static let byteFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.allowedUnits = [.useKB, .useMB, .useGB]
            formatter.countStyle = .file
            return formatter
        }()
    }

    // MARK: - Imports

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importFile(url) }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
            DiagnosticsLog.shared.record(error: error, context: "Open Files picker")
            Haptics.error()
        }
    }

    private func importPhotoLibraryItem(_ item: PhotosPickerItem) async {
        if let media = await viewModel.importFromPhotos(item) {
            path.append(.inputDetail(media))
        }
    }

    private func importFile(_ url: URL) async {
        if let media = await viewModel.importFromFiles(url) {
            path.append(.inputDetail(media))
        }
    }

    private func importPasteboard() async {
        if let media = await viewModel.importFromPasteboard() {
            path.append(.inputDetail(media))
        }
    }

    private func importFromRemoteLink(_ raw: String) async {
        if let media = await viewModel.importFromRemoteLink(raw) {
            path.append(.inputDetail(media))
        }
    }

    private static var allowedContentTypes: [UTType] {
        [
            .image,
            .movie,
            .audio,
            UTType(filenameExtension: "webm") ?? .data,
            UTType(filenameExtension: "mkv") ?? .data,
            UTType(filenameExtension: "flac") ?? .data,
            UTType(filenameExtension: "opus") ?? .data,
            UTType(filenameExtension: "ogg") ?? .data
        ]
    }
}

/// A large artwork tile in the icon's blue, like a featured card in Apple Music.
private struct SourceHeroTile: View {
    enum Palette {
        case sky
        case deep

        var colors: [Color] {
            switch self {
            case .sky: [Color(hex: 0x58ADE6), Color(hex: 0x1E6CA6), Color(hex: 0x134F7C)]
            case .deep: [Color(hex: 0x2C78B2), Color(hex: 0x0F4A75), Color(hex: 0x082E4A)]
            }
        }
    }

    let title: String
    let subtitle: String
    let systemImage: String
    let palette: Palette

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ScaledMetric(relativeTo: .title2) private var badgeSize: CGFloat = 46

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: systemImage)
                .font(.system(size: badgeSize * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: badgeSize, height: badgeSize)
                .glassSurface(in: Circle(), tint: .white.opacity(0.12))
                .accessibilityHidden(true)

            Spacer(minLength: dynamicTypeSize.isAccessibilitySize ? 14 : 28)

            Text(title)
                .font(.title3.bold())
                .foregroundStyle(.white)
            Text(subtitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.white.opacity(0.88))
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(18)
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? nil : (horizontalSizeClass == .regular ? 200 : 172),
            alignment: .leading
        )
        .background { artwork }
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .shadow(color: Theme.brandNavy.opacity(isEnabled ? 0.22 : 0), radius: 18, y: 10)
        .saturation(isEnabled ? 1 : 0)
        .opacity(isEnabled ? 1 : 0.55)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
    }

    private var artwork: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: palette.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

            Image(systemName: systemImage)
                .font(.system(size: 118, weight: .regular))
                .foregroundStyle(.white.opacity(0.09))
                .offset(x: 26, y: 22)
                .accessibilityHidden(true)

            LinearGradient(
                colors: [.black.opacity(0), .black.opacity(0.16)],
                startPoint: .center,
                endPoint: .bottom
            )
        }
    }
}

/// A row in the grouped source list, styled like Settings.
private struct SourceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var thumbnail: UIImage? = nil

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        IconTile(systemImage: systemImage, isEnabled: isEnabled)
                        Spacer()
                        disclosure
                    }
                    titleLabel
                    thumbnailView
                }
            } else {
                HStack(spacing: 14) {
                    IconTile(systemImage: systemImage, isEnabled: isEnabled)
                    titleLabel
                    Spacer(minLength: 8)
                    thumbnailView
                    disclosure
                }
            }
        }
        .multilineTextAlignment(.leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
                .foregroundStyle(isEnabled ? Theme.text : Theme.textMuted)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Theme.textTertiary)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 40, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}

/// A square thumbnail with a caption, like an album in a shelf.
private struct RecentConversionCard: View {
    let entry: ConversionHistoryEntry
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaPreview(
                url: entry.result.url,
                category: entry.result.outputFormat.category,
                compact: true,
                showsChrome: false,
                isInteractive: false
            )
            .frame(width: side, height: side)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.input.originalFilename)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("\(entry.result.outputFormat.displayName) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .frame(width: side, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

#Preview("Home · Compact · Light", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        HomeView(path: .constant([]))
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.light)
}

#Preview("Home · Regular · Dark", traits: .fixedLayout(width: 1_024, height: 768)) {
    NavigationStack {
        HomeView(path: .constant([]))
    }
    .environment(\.horizontalSizeClass, .regular)
    .preferredColorScheme(.dark)
}

#Preview("Home · Accessibility", traits: .fixedLayout(width: 375, height: 812)) {
    NavigationStack {
        HomeView(path: .constant([]))
    }
    .environment(\.dynamicTypeSize, .accessibility5)
    .preferredColorScheme(.light)
}

#Preview("Home · Import Progress", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        HomeView(
            path: .constant([]),
            previewImportProgress: RemoteDownloadProgress(
                bytesReceived: 78_600_000,
                totalBytes: 150_000_000
            )
        )
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.light)
}
