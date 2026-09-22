import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Binding var path: [AppRoute]
    var constrainedWidth = true
    var showsHistoryToolbar = true
    var showsContentTitle = false
    var previewImportProgress: RemoteDownloadProgress? = nil

    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
            Color(uiColor: .systemBackground).ignoresSafeArea()

            Circle()
                .fill(Color.accentColor.opacity(0.09))
                .frame(width: 520, height: 520)
                .blur(radius: 110)
                .offset(x: 170, y: -290)
                .accessibilityHidden(true)

            ScrollView {
                VStack(spacing: 34) {
                    Spacer(minLength: 44)
                    hero
                    importControls

                    if isImporting {
                        importStatusView
                            .padding(18)
                            .appleGlass(cornerRadius: 22)
                            .transition(.scale(scale: 0.96).combined(with: .opacity))
                    }

                    if !dynamicTypeSize.isAccessibilitySize {
                        Label("You can also drop a file anywhere", systemImage: "arrow.down.doc")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 44)
                }
                .frame(maxWidth: constrainedWidth ? 560 : 680)
                .frame(maxWidth: .infinity, minHeight: 620)
                .padding(.horizontal, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle(showsContentTitle ? "Converter" : "")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if showsHistoryToolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.impact(.light)
                        ConversionHistoryStore.shared.refreshForCurrentSettings()
                        path.append(.history)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .accessibilityLabel("Conversion history")
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Haptics.impact(.light)
                    isSettingsPresented = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .accessibilityLabel("Open settings")
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
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.refreshPasteboard() }
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
        .onAppear { viewModel.refreshPasteboard() }
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
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "Please try again.")
        }
        .alert("Import from link", isPresented: $isLinkImportPresented) {
            TextField("https://example.com/file", text: $linkURLText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            Button("Cancel", role: .cancel) { linkURLText = "" }
            Button("Download") {
                let text = linkURLText
                linkURLText = ""
                Task { await importFromRemoteLink(text) }
            }
        } message: {
            Text("Enter a direct link to a supported file up to 150 MB.")
        }
        .sheet(isPresented: $isSettingsPresented) {
            settingsView
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .animation(.snappy(duration: 0.35), value: isImporting)
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 42, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .rotationEffect(.degrees(isImporting ? 180 : 0))
                .animation(isImporting ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: isImporting)
                .accessibilityHidden(true)

            Text("Choose media")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .multilineTextAlignment(.center)

            Text("Photos, video, and audio stay on this device.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var importControls: some View {
        VStack(spacing: 18) {
            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .any(of: [.images, .videos]),
                preferredItemEncoding: .current
            ) {
                Label("Choose from Photos", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .padding(.horizontal, 10)
            }
            .appleGlassButton(prominent: true)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(isImporting)
            .accessibilityLabel("Import from Photos")

            AppleGlassControlGroup(spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) { secondaryImportControls }
                    VStack(spacing: 10) { secondaryImportControls }
                }
            }
        }
    }

    @ViewBuilder
    private var secondaryImportControls: some View {
        importButton("Files", systemImage: "folder") {
            isFileImporterPresented = true
        }

        importButton("Link", systemImage: "link") {
            linkURLText = ""
            isLinkImportPresented = true
        }

        Button {
            Haptics.impact(.light)
            Task { await importPasteboard() }
        } label: {
            Label("Clipboard", systemImage: "doc.on.clipboard")
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .appleGlassButton()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(viewModel.pasteboardImportLabel == nil || isImporting)
        .accessibilityLabel(
            viewModel.pasteboardImportLabel.map { "Paste \($0) from clipboard" } ?? "Paste from clipboard"
        )
    }

    private func importButton(
        _ title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .appleGlassButton()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(isImporting)
    }

    @ViewBuilder
    private var importStatusView: some View {
        if let progress = previewImportProgress ?? viewModel.remoteDownloadProgress {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Downloading", systemImage: "arrow.down.circle.fill")
                        .font(.headline)
                    Spacer()
                    if let fraction = progress.fractionCompleted {
                        Text("\(Int((fraction * 100).rounded()))%")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                }
                ProgressView(value: progress.displayFraction)
                Text(downloadByteText(progress))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            HStack(spacing: 12) {
                ProgressView()
                Text("Importing…")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isImporting: Bool {
        viewModel.isImporting || previewImportProgress != nil
    }

    private func downloadByteText(_ progress: RemoteDownloadProgress) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        let received = formatter.string(fromByteCount: progress.bytesReceived)
        guard let total = progress.totalBytes else { return "\(received) downloaded" }
        return "\(received) of \(formatter.string(fromByteCount: total))"
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
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))

                Section("History") {
                    Toggle("Save conversion history", isOn: conversionHistoryEnabledBinding)
                }
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))

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
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))

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
                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
            }
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .tint(.accentColor)
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
