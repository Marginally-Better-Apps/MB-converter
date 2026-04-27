import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Binding var path: [AppRoute]
    var constrainedWidth = true

    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = HomeViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var isLinkImportPresented = false
    @State private var linkURLText = ""
    @State private var isSettingsPresented = false
    @State private var themeSelection: ThemeSelection = .light
    @State private var isConfirmDisableSavedHistoryPresented = false
    @State private var pasteboardRefreshTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()
    @AppStorage(ConversionHistoryUserDefaults.isEnabledKey) private var conversionHistoryEnabled = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack(alignment: .top) {
            Theme.background.ignoresSafeArea()

            homeAtmosphere
                .allowsHitTesting(false)

            VStack(spacing: 16) {
                header

                capabilityStrip

                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 14) {
                        LazyVGrid(columns: gridColumns, spacing: 14) {
                            PhotosPicker(
                                selection: $selectedPhotoItem,
                                matching: .any(of: [.images, .videos]),
                                preferredItemEncoding: .current
                            ) {
                                importButtonLabel("Photo Album", systemImage: "photo.on.rectangle", style: .tonal)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { Haptics.impact(.light) })
                            .disabled(viewModel.isImporting)
                            .accessibilityLabel("Import from Photos")

                            Button {
                                Haptics.impact(.light)
                                isFileImporterPresented = true
                            } label: {
                                importButtonLabel("Files", systemImage: "folder", style: .tonal)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isImporting)
                            .accessibilityLabel("Import from Files")
                        }

                        HStack(spacing: 14) {
                            Button {
                                Haptics.impact(.light)
                                linkURLText = ""
                                isLinkImportPresented = true
                            } label: {
                                importButtonLabel("From link", systemImage: "link", style: .tonal)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isImporting)
                            .accessibilityLabel("Import file from web link")
                            .accessibilityHint("Downloads a supported media file up to 150 megabytes.")

                            Button {
                                Haptics.impact(.light)
                                Task { await importPasteboard() }
                            } label: {
                                importButtonLabel(
                                    viewModel.pasteboardImportLabel.map { "Paste\n(\($0))" } ?? "Paste from clipboard",
                                    systemImage: "doc.on.clipboard",
                                    style: .tonal
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.pasteboardImportLabel == nil || viewModel.isImporting)
                            .opacity(viewModel.pasteboardImportLabel == nil ? 0.45 : 1)
                            .accessibilityLabel(
                                viewModel.pasteboardImportLabel.map { "Paste \($0) from clipboard" } ?? "Paste from clipboard"
                            )
                        }
                    }
                    .padding(.top, 10)
                }

                if viewModel.isImporting {
                    importStatusView
                }
            }
            .frame(maxWidth: constrainedWidth ? 480 : .infinity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)
        }
        .navigationTitle("MB Converter")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    Haptics.impact(.light)
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Open settings")
            }
            ToolbarItem(placement: .principal) {
                Text("MB Converter")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Theme.text)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.impact(.light)
                    ConversionHistoryStore.shared.refreshForCurrentSettings()
                    path.append(.history)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.headline.weight(.semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Conversion history")
            }
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: Self.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImporter(result)
        }
        .onChange(of: selectedPhotoItem) { _, item in
            guard let item else { return }
            Task {
                await importPhoto(item)
                selectedPhotoItem = nil
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
        .alert("Import from link", isPresented: $isLinkImportPresented) {
            TextField("", text: $linkURLText)
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
        .sheet(isPresented: $isSettingsPresented) {
            settingsView
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Atmosphere

    private var homeAtmosphere: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Theme.secondary.opacity(colorScheme == .dark ? 0.14 : 0.22),
                    Theme.background
                ],
                startPoint: .topLeading,
                endPoint: .center
            )
            .ignoresSafeArea()

            Circle()
                .fill(Theme.primary.opacity(colorScheme == .dark ? 0.1 : 0.06))
                .frame(width: 320, height: 320)
                .offset(x: 140, y: -120)
                .blur(radius: 28)

            Circle()
                .fill(Theme.secondary.opacity(0.35))
                .frame(width: 220, height: 220)
                .offset(x: -130, y: 220)
                .blur(radius: 20)

            RoundedRectangle(cornerRadius: 100, style: .continuous)
                .fill(Theme.accent.opacity(colorScheme == .dark ? 0.35 : 0.12))
                .frame(width: 180, height: 90)
                .rotationEffect(.degrees(-12))
                .offset(x: 80, y: 400)
                .blur(radius: 16)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Theme.secondary.opacity(0.45), Theme.primary.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .overlay {
                        Circle()
                            .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                    }

                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(Theme.primary)
            }

            VStack(spacing: 10) {
                Text("Convert & Compress")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)

                Text("Photos, video, audio, and clipboard — all in one flow.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
            }

            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [Theme.accent.opacity(0), Theme.primary, Theme.accent.opacity(0)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
                .frame(maxWidth: 200)
                .clipShape(Capsule())
        }
    }

    private var capabilityStrip: some View {
        CapabilityTicker(items: HomeCapability.items)
            .frame(height: 40)
    }

    // MARK: - Import controls

    @ViewBuilder
    private var importStatusView: some View {
        if let progress = viewModel.remoteDownloadProgress {
            DownloadProgressPrompt(progress: progress)
        } else {
            ProgressView("Importing...")
                .tint(Theme.primary)
                .foregroundStyle(Theme.text)
        }
    }

    private enum ImportButtonStyle {
        case filled, outlined, tonal
    }

    private var gridColumns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }

    @ViewBuilder
    private func importButtonLabel(
        _ title: String,
        systemImage: String,
        style: ImportButtonStyle
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title2)
            Text(title)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: style == .tonal ? 88 : 120)
        .padding(12)
        .modifier(ImportButtonChrome(style: style, colorScheme: colorScheme))
    }

    private struct ImportButtonChrome: ViewModifier {
        let style: ImportButtonStyle
        let colorScheme: ColorScheme

        func body(content: Content) -> some View {
            switch style {
            case .filled:
                content
                    .foregroundStyle(Theme.background)
                    .background(Theme.primary)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            case .outlined:
                content
                    .foregroundStyle(Theme.primary)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.accent, lineWidth: colorScheme == .dark ? 1 : 1.5)
                    }
            case .tonal:
                content
                    .foregroundStyle(Theme.primary)
                    .background(
                        LinearGradient(
                            colors: [
                                Theme.secondary.opacity(0.35),
                                Theme.secondary.opacity(0.2)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Theme.accent.opacity(0.3), lineWidth: 1)
                    }
            }
        }
    }

    private struct DownloadProgressPrompt: View {
        let progress: RemoteDownloadProgress

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Label("Downloading from link", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Theme.text)

                    Spacer()

                    if let fraction = progress.fractionCompleted {
                        Text(percentText(for: fraction))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.primary)
                            .monospacedDigit()
                    }
                }

                ProgressView(value: progress.displayFraction, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Theme.primary)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(
                        progress.fractionCompleted.map { percentText(for: $0) } ?? byteText
                    )

                Text(byteText)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
                    .monospacedDigit()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Theme.accent.opacity(0.35), lineWidth: 1)
            }
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

    private func handleFileImporter(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            Task { await importFile(url) }
        case .failure(let error):
            viewModel.errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    private func importPhoto(_ item: PhotosPickerItem) async {
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

    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $themeSelection) {
                        ForEach(ThemeSelection.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("History") {
                    Toggle("Save conversion history", isOn: conversionHistoryEnabledBinding)
                }

                Section("App") {
                    HStack {
                        Text("Name")
                        Spacer()
                        Text("Marginally Better Converter")
                            .foregroundStyle(Theme.textMuted)
                    }
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0")
                            .foregroundStyle(Theme.textMuted)
                    }
                    Button {
                        Haptics.impact(.light)
                        if let url = URL(string: "https://github.com/Marginally-Better-Apps/MB-converter") {
                            openURL(url)
                        }
                    } label: {
                        Label("GitHub", systemImage: "link.circle.fill")
                            .font(.body.weight(.semibold))
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .preferredColorScheme(themeSelection.colorScheme)
            .alert("Switch to session-only history?", isPresented: $isConfirmDisableSavedHistoryPresented) {
                Button("Cancel", role: .cancel) {}
                Button("Switch", role: .destructive) {
                    Haptics.warning()
                    ConversionHistoryStore.shared.clearPersistedHistory()
                    conversionHistoryEnabled = false
                    ConversionHistoryStore.shared.refreshForCurrentSettings()
                }
            } message: {
                Text(
                    "Turning off saved history removes every saved conversion from this device at once. "
                    + "Afterward, History only keeps items from this session until you quit and reopen the app."
                )
            }
            .onAppear {
                themeSelection = resolvedThemeSelection
            }
            .onChange(of: themeSelection) { _, selection in
                let newValue = AppColorMode(colorScheme: selection.colorScheme).rawValue
                if appColorModeRawValue != newValue {
                    Haptics.selection()
                    appColorModeRawValue = newValue
                }
            }
            .onChange(of: appColorModeRawValue) { _, _ in
                themeSelection = resolvedThemeSelection
            }
        }
    }

    private var resolvedThemeSelection: ThemeSelection {
        switch AppColorMode(rawValue: appColorModeRawValue) {
        case .light?:
            .light
        case .dark?:
            .dark
        default:
            colorScheme == .dark ? .dark : .light
        }
    }

    private var conversionHistoryEnabledBinding: Binding<Bool> {
        Binding(
            get: { conversionHistoryEnabled },
            set: { newValue in
                if conversionHistoryEnabled, !newValue {
                    isConfirmDisableSavedHistoryPresented = true
                    return
                }
                conversionHistoryEnabled = newValue
                ConversionHistoryStore.shared.refreshForCurrentSettings()
            }
        )
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

private enum ThemeSelection: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

// MARK: - Capability ticker

private struct HomeCapability: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String

    static let items: [HomeCapability] = [
        // Keep this list aligned with import support in FormatMatrix.detectCategory/categoryByExtension.
        .init(title: "JPEG", symbol: "photo"),
        .init(title: "PNG", symbol: "photo.fill"),
        .init(title: "HEIC", symbol: "camera.aperture"),
        .init(title: "WEBP", symbol: "wand.and.stars"),
        .init(title: "AVIF", symbol: "wand.and.rays"),
        .init(title: "TIFF", symbol: "doc.richtext"),
        .init(title: "GIF", symbol: "photo.on.rectangle.angled"),
        .init(title: "MP4", symbol: "film"),
        .init(title: "MOV", symbol: "video"),
        .init(title: "WEBM", symbol: "play.rectangle"),
        .init(title: "MKV", symbol: "play.tv"),
        .init(title: "TS", symbol: "tv"),
        .init(title: "MTS", symbol: "tv.inset.filled"),
        .init(title: "M2TS", symbol: "tv.music.note"),
        .init(title: "3GP", symbol: "rectangle.compress.vertical"),
        .init(title: "HEVC", symbol: "film.stack"),
        .init(title: "MP3", symbol: "music.note"),
        .init(title: "M4A", symbol: "waveform"),
        .init(title: "WAV", symbol: "hifispeaker"),
        .init(title: "AAC", symbol: "dot.radiowaves.left.and.right"),
        .init(title: "FLAC", symbol: "music.quarternote.3"),
        .init(title: "OGG", symbol: "circle.grid.2x2"),
        .init(title: "OPUS", symbol: "waveform.path"),
        .init(title: "ALAC", symbol: "music.mic")
    ]
}

private struct CapabilityTicker: View {
    let items: [HomeCapability]

    @Environment(\.colorScheme) private var colorScheme
    @State private var rowWidth: CGFloat = 1

    private let spacing: CGFloat = 10
    private let speed: CGFloat = 24 // points per second

    var body: some View {
        GeometryReader { proxy in
            let cycleWidth = max(rowWidth + spacing, 1)

            TimelineView(.animation(minimumInterval: 1 / 30)) { timeline in
                let elapsed = timeline.date.timeIntervalSinceReferenceDate
                let offset = CGFloat(elapsed) * speed
                let normalizedOffset = offset.truncatingRemainder(dividingBy: cycleWidth)

                HStack(spacing: spacing) {
                    chipRow
                    chipRow
                }
                .offset(x: -normalizedOffset)
                .frame(width: proxy.size.width + cycleWidth, alignment: .leading)
                .clipped()
            }
        }
    }

    private var chipRow: some View {
        HStack(spacing: spacing) {
            ForEach(items) { item in
                Label(item.title, systemImage: item.symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(Theme.surface.opacity(colorScheme == .dark ? 0.9 : 0.72))
                    .clipShape(Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Theme.accent.opacity(colorScheme == .dark ? 0.55 : 0.22), lineWidth: 1)
                    }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: CapabilityRowWidthPreferenceKey.self, value: proxy.size.width)
            }
        }
        .onPreferenceChange(CapabilityRowWidthPreferenceKey.self) { width in
            guard width > 0 else { return }
            rowWidth = width
        }
    }
}

private struct CapabilityRowWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 1

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

#Preview {
    NavigationStack {
        HomeView(path: .constant([]))
    }
}
