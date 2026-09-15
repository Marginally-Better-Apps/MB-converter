import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Binding var path: [AppRoute]
    var constrainedWidth = true
    var showsHistoryToolbar = true
    var showsContentTitle = false
    /// Preview-only state injection. Production call sites use the default `nil` value.
    var previewImportProgress: RemoteDownloadProgress? = nil

    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel = HomeViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var isFileImporterPresented = false
    @State private var isLinkImportPresented = false
    @State private var linkURLText = ""
    @State private var isSettingsPresented = false
    @State private var themeSelection: ThemeSelection = .system
    @State private var isConfirmDisableSavedHistoryPresented = false
    @State private var diagnosticsErrorCount = 0
    @State private var latestDiagnosticsErrorDate: Date?
    @State private var pasteboardRefreshTimer = Timer.publish(every: 0.6, on: .main, in: .common).autoconnect()
    @AppStorage(ConversionHistoryUserDefaults.isEnabledKey) private var conversionHistoryEnabled = false

    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var viewModel = viewModel

        ZStack {
            homeBackground

            ZStack(alignment: .topLeading) {
                homeHeader

                VStack(alignment: .leading, spacing: 24) {
                    LazyVGrid(columns: importGridColumns, spacing: 14) {
                        PhotosPicker(
                            selection: $selectedPhotoItem,
                            matching: .any(of: [.images, .videos]),
                            preferredItemEncoding: .current
                        ) {
                            importSourceCard(
                                "Photos",
                                subtitle: "Choose a photo or video",
                                systemImage: "photo.on.rectangle.angled"
                            )
                        }
                        .buttonStyle(HomeImportCardButtonStyle())
                        .simultaneousGesture(TapGesture().onEnded { Haptics.impact(.light) })
                        .disabled(isImporting)
                        .accessibilityLabel("Import from Photos")

                        Button {
                            Haptics.impact(.light)
                            isFileImporterPresented = true
                        } label: {
                            importSourceCard(
                                "Files",
                                subtitle: "Browse device or cloud storage",
                                systemImage: "folder"
                            )
                        }
                        .buttonStyle(HomeImportCardButtonStyle())
                        .disabled(isImporting)
                        .accessibilityLabel("Import from Files")

                        Button {
                            Haptics.impact(.light)
                            linkURLText = ""
                            isLinkImportPresented = true
                        } label: {
                            importSourceCard(
                                "From Link",
                                subtitle: "Download a file up to 150 MB",
                                systemImage: "link"
                            )
                        }
                        .buttonStyle(HomeImportCardButtonStyle())
                        .disabled(isImporting)
                        .accessibilityLabel("Import file from web link")
                        .accessibilityHint("Downloads a supported media file up to 150 megabytes.")

                        Button {
                            Haptics.impact(.light)
                            Task { await importPasteboard() }
                        } label: {
                            importSourceCard(
                                "Clipboard",
                                subtitle: clipboardSubtitle,
                                systemImage: "doc.on.clipboard"
                            )
                        }
                        .buttonStyle(HomeImportCardButtonStyle())
                        .disabled(viewModel.pasteboardImportLabel == nil || isImporting)
                        .accessibilityLabel(
                            viewModel.pasteboardImportLabel.map { "Paste \($0) from clipboard" } ?? "Paste from clipboard"
                            )
                    }

                    if isImporting {
                        importStatusCard
                            .transition(
                                accessibilityReduceMotion
                                    ? .opacity
                                    : .move(edge: .bottom).combined(with: .opacity)
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
            .frame(
                maxWidth: constrainedWidth ? 640 : 760,
                maxHeight: .infinity,
                alignment: .topLeading
            )
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(
                accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2),
                value: isImporting
            )
        }
        .navigationTitle("")
        .toolbar(.hidden, for: .navigationBar)
        .tint(Theme.primary)
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
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Import controls

    private var homeBackground: some View {
        ZStack {
            Theme.background

            LinearGradient(
                colors: [
                    Theme.secondary.opacity(colorScheme == .dark ? 0.16 : 0.2),
                    Theme.background.opacity(0.45),
                    Theme.background
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    Theme.primary.opacity(colorScheme == .dark ? 0.1 : 0.055),
                    .clear
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 360
            )
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var homeHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 12) {
                homeTitle
                homeHeaderActions
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                homeTitle
                Spacer(minLength: 8)
                homeHeaderActions
            }
        }
    }

    private var homeTitle: some View {
        Text("MB Converter")
            .font(.largeTitle.bold())
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .accessibilityAddTraits(.isHeader)
    }

    private var homeHeaderActions: some View {
        HStack(spacing: 2) {
            if showsHistoryToolbar {
                Button {
                    Haptics.impact(.light)
                    ConversionHistoryStore.shared.refreshForCurrentSettings()
                    path.append(.history)
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Conversion history")
            }

            Button {
                Haptics.impact(.light)
                isSettingsPresented = true
            } label: {
                Image(systemName: "gearshape")
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open settings")
        }
        .font(.title3.weight(.semibold))
        .foregroundStyle(Theme.primary)
        .padding(4)
        .background(
            Theme.surface.opacity(colorScheme == .dark ? 0.72 : 0.82),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(Theme.primary.opacity(colorScheme == .dark ? 0.22 : 0.1), lineWidth: 1)
        }
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0 : 0.055),
            radius: 10,
            x: 0,
            y: 5
        )
    }

    private var importGridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }

    private var clipboardSubtitle: String {
        if let type = viewModel.pasteboardImportLabel {
            return "Paste \(type) from the clipboard"
        }
        return "No supported media is available"
    }

    private func importSourceCard(
        _ title: String,
        subtitle: String,
        systemImage: String
    ) -> some View {
        HomeImportSourceCard(
            title: title,
            subtitle: subtitle,
            systemImage: systemImage
        )
    }

    private var importStatusCard: some View {
        importStatusView
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Theme.separator, lineWidth: 1)
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0 : 0.07),
                radius: 12,
                x: 0,
                y: 6
            )
    }

    @ViewBuilder
    private var importStatusView: some View {
        if let progress = previewImportProgress ?? viewModel.remoteDownloadProgress {
            DownloadProgressPrompt(progress: progress)
        } else {
            HStack(spacing: 12) {
                ProgressView()
                    .tint(Theme.primary)
                Text("Importing…")
                    .foregroundStyle(Theme.text)
            }
            .padding(.vertical, 6)
        }
    }

    private var isImporting: Bool {
        viewModel.isImporting || previewImportProgress != nil
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
            .padding(.vertical, 6)
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
                    if dynamicTypeSize.isAccessibilitySize {
                        Picker("Appearance", selection: $themeSelection) {
                            ForEach(ThemeSelection.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                    } else {
                        Picker("Appearance", selection: $themeSelection) {
                            ForEach(ThemeSelection.allCases) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .listRowBackground(Theme.surface)

                Section("History") {
                    Toggle("Save conversion history", isOn: conversionHistoryEnabledBinding)
                }
                .listRowBackground(Theme.surface)

                Section {
                    NavigationLink {
                        DiagnosticsLogView()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: diagnosticsErrorCount == 0
                                  ? "checkmark.circle"
                                  : "exclamationmark.triangle.fill")
                                .foregroundStyle(diagnosticsErrorCount == 0 ? Theme.primary : Theme.destructive)
                                .frame(width: 28)

                            VStack(alignment: .leading, spacing: 3) {
                                Text("Error Log")
                                    .foregroundStyle(Theme.text)
                                Text(diagnosticsSummary)
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textMuted)
                            }

                            Spacer(minLength: 8)
                            if diagnosticsErrorCount > 0 {
                                Text(String(diagnosticsErrorCount))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Theme.destructive, in: Capsule())
                            }
                        }
                        .padding(.vertical, 3)
                    }
                    .accessibilityHint("Opens recorded errors with conversion context and technical details.")
                } header: {
                    Text("Diagnostics")
                } footer: {
                    Text("Errors are saved across launches and can be reviewed, copied, or exported.")
                }
                .listRowBackground(Theme.surface)

                Section("App") {
                    LabeledContent("Name") {
                        Text("Marginally Better Converter")
                            .foregroundStyle(Theme.textMuted)
                    }
                    LabeledContent("Version") {
                        Text(bundleVersion)
                            .foregroundStyle(Theme.textMuted)
                    }
                    LabeledContent("Build") {
                        Text(bundleBuild)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Button {
                        Haptics.impact(.light)
                        if let url = URL(string: "https://github.com/Marginally-Better-Apps/MB-converter") {
                            openURL(url)
                        }
                    } label: {
                        Label("View on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .tint(Theme.primary)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.impact(.light)
                        isSettingsPresented = false
                    }
                    .fontWeight(.semibold)
                }
            }
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
                refreshDiagnosticsSummary()
            }
            .onChange(of: themeSelection) { _, selection in
                let newValue = selection.rawValue
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
        ThemeSelection(rawValue: appColorModeRawValue) ?? .system
    }

    private var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    private var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
    }

    private var diagnosticsSummary: String {
        guard diagnosticsErrorCount > 0 else { return "No errors recorded" }
        guard let latestDiagnosticsErrorDate else {
            return "\(diagnosticsErrorCount) recorded"
        }
        return "Latest \(latestDiagnosticsErrorDate.formatted(date: .abbreviated, time: .shortened))"
    }

    private func refreshDiagnosticsSummary() {
        let errors = DiagnosticsLog.shared.entries().filter { $0.level == .error }
        diagnosticsErrorCount = errors.count
        latestDiagnosticsErrorDate = errors.first?.timestamp
    }

    private var conversionHistoryEnabledBinding: Binding<Bool> {
        Binding(
            get: { conversionHistoryEnabled },
            set: { newValue in
                if conversionHistoryEnabled, !newValue {
                    isConfirmDisableSavedHistoryPresented = true
                    return
                }
                if !conversionHistoryEnabled, newValue,
                   !ConversionHistoryStore.shared.persistSessionHistory() {
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
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

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
}

private struct HomeImportSourceCard: View {
    let title: String
    let subtitle: String
    let systemImage: String

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 16) {
                    iconWell
                    cardCopy
                    Spacer(minLength: 0)
                }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Spacer(minLength: 0)
                    iconWell
                    cardCopy
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(18)
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 116 : 180,
            alignment: .topLeading
        )
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(isEnabled ? Theme.surface : Theme.disabledSurface)
                .overlay {
                    if isEnabled {
                        LinearGradient(
                            colors: [
                                Theme.secondary.opacity(0.16),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    isEnabled
                        ? Theme.primary.opacity(colorScheme == .dark ? 0.48 : 0.3)
                        : Theme.textMuted.opacity(colorScheme == .dark ? 0.24 : 0.34),
                    lineWidth: isEnabled ? 1.5 : 1
                )
        }
        .shadow(
            color: Color.black.opacity(
                isEnabled ? (colorScheme == .dark ? 0.24 : 0.12) : 0
            ),
            radius: 14,
            x: 0,
            y: 7
        )
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var iconWell: some View {
        Image(systemName: systemImage)
            .font(.system(size: 21, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isEnabled ? Theme.primary : Theme.textMuted.opacity(0.62))
            .frame(width: 48, height: 48)
            .background(
                isEnabled ? Theme.secondaryFill : Theme.background.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
    }

    private var cardCopy: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.headline)
                .foregroundStyle(isEnabled ? Theme.text : Theme.textMuted.opacity(0.72))

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted.opacity(isEnabled ? 1 : 0.62))
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
    }
}

private struct HomeImportCardButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !accessibilityReduceMotion ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(
                accessibilityReduceMotion ? nil : .easeOut(duration: 0.14),
                value: configuration.isPressed
            )
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
        HomeView(
            path: .constant([]),
            constrainedWidth: false,
            showsHistoryToolbar: false,
            showsContentTitle: true
        )
    }
    .environment(\.horizontalSizeClass, .regular)
    .preferredColorScheme(.dark)
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
