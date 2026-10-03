import Combine
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel = HomeViewModel()
    @State private var selectedImageItem: PhotosPickerItem?
    @State private var selectedVideoItem: PhotosPickerItem?
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

            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        homeHeader
                            .frame(maxWidth: .infinity, alignment: .leading)

                        VStack(spacing: 14) {
                            primaryImportControls
                            secondaryImportControls
                            if let draft = ConversionDraftStore.shared.entries.first {
                                Button { path.append(.draft(draft)) } label: {
                                    HStack {
                                        Image(systemName: "square.and.pencil")
                                        Text("Resume \(draft.input.originalFilename)").lineLimit(1)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                    }.padding(16).converterGlass(cornerRadius: 18)
                                }.buttonStyle(.plain)
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
                        .padding(.top, 20)

                        if horizontalSizeClass == .regular {
                            Spacer(minLength: 28)
                            homeDropHint
                        }

                        Spacer(minLength: 24)

                        homeFooter
                            .padding(.bottom, 12)
                    }
                    .padding(.top, 20)
                    .frame(minHeight: geometry.size.height, alignment: .top)
                    .frame(maxWidth: constrainedWidth ? 560 : 600)
                    .padding(.horizontal, 24)
                    .frame(maxWidth: .infinity)
                }
                .scrollIndicators(.hidden)
                .scrollBounceBehavior(.basedOnSize)
            }
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
            allowsMultipleSelection: true
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
        .navigationDestination(isPresented: $isSettingsPresented) {
            settingsView
        }
    }

    // MARK: - Import controls

    private var primaryImportControls: some View {
        LazyVGrid(columns: importGridColumns, spacing: 16) {
            PhotosPicker(
                selection: $selectedImageItem,
                matching: .images,
                preferredItemEncoding: .current
            ) {
                HomeImportSourceCard(
                    title: "Photos",
                    subtitle: "Choose an image",
                    systemImage: "photo.on.rectangle.angled"
                )
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.impact(.light) })
            .accessibilityLabel("Import an image from Photos")

            PhotosPicker(
                selection: $selectedVideoItem,
                matching: .videos,
                preferredItemEncoding: .current
            ) {
                HomeImportSourceCard(
                    title: "Videos",
                    subtitle: "Choose a video",
                    systemImage: "video"
                )
            }
            .simultaneousGesture(TapGesture().onEnded { Haptics.impact(.light) })
            .accessibilityLabel("Import a video from Photos")
        }
        .buttonStyle(HomeImportCardButtonStyle())
        .disabled(isImporting)
    }

    private var secondaryImportControls: some View {
        VStack(spacing: 0) {
            Button {
                Haptics.impact(.light)
                isFileImporterPresented = true
            } label: {
                HomeImportSourceRow(
                    title: "Files",
                    subtitle: "",
                    systemImage: "folder"
                )
            }
            .disabled(isImporting)
            .accessibilityLabel("Import from Files")

            Rectangle()
                .fill(Theme.Home.separator)
                .frame(height: 0.5)
                .padding(.leading, 64)
                .padding(.trailing, 24)
                .accessibilityHidden(true)

            Button {
                Haptics.impact(.light)
                linkURLText = ""
                isLinkImportPresented = true
            } label: {
                HomeImportSourceRow(
                    title: "From Link",
                    subtitle: "",
                    systemImage: "link"
                )
            }
            .disabled(isImporting)
            .accessibilityLabel("Import file from web link")
            .accessibilityHint("Downloads a supported media file up to 150 megabytes.")

            Rectangle()
                .fill(Theme.Home.separator)
                .frame(height: 0.5)
                .padding(.leading, 64)
                .padding(.trailing, 24)
                .accessibilityHidden(true)

            Button {
                Haptics.impact(.light)
                Task { await importPasteboard() }
            } label: {
                HomeImportSourceRow(
                    title: "Clipboard",
                    subtitle: pasteboardSubtitle,
                    systemImage: "doc.on.clipboard",
                    thumbnail: viewModel.pasteboardPreviewThumbnail,
                    keepsRowContentsOnOneLine: true
                )
            }
            .disabled(viewModel.pasteboardImportLabel == nil || isImporting)
            .accessibilityLabel(
                viewModel.pasteboardImportLabel.map { "Paste \($0) from clipboard" } ?? "Paste from clipboard"
            )
        }
        .buttonStyle(HomeImportCardButtonStyle())
        .converterGlass(cornerRadius: 26)

    }

    private var homeBackground: some View {
        Theme.Home.background
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
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    homeTitle
                        .fixedSize()
                    Spacer(minLength: 8)
                    homeHeaderActions
                }

                VStack(alignment: .leading, spacing: 16) {
                    homeTitle
                    homeHeaderActions
                }
            }
        }
    }

    private var homeTitle: some View {
        Text("MB Converter")
            .font(.system(.largeTitle, design: .default, weight: .semibold))
            .tracking(-1.2)
            .foregroundStyle(Theme.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }

    private var homeIntroduction: some View {
        VStack(alignment: .center, spacing: 7) {
            if !dynamicTypeSize.isAccessibilitySize {
                Text("START A CONVERSION")
                    .font(.caption.weight(.bold))
                    .tracking(1.5)
                    .hidden()
                    .accessibilityHidden(true)
            }

            Text("Choose a source")
                .font(.system(.title2, design: .default, weight: .semibold))
                .foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var homeDropHint: some View {
        VStack(spacing: 7) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 25, weight: .light))
                .foregroundStyle(Theme.primary)
                .accessibilityHidden(true)

            Text("Drag a file here")
                .font(.headline)
                .foregroundStyle(Theme.text)

            Text("Drop a file from Files to import it.")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: 118)
        .padding(.vertical, 12)
        .background(
            Theme.Home.surface,
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(
                    Theme.Home.controlBorder,
                    style: StrokeStyle(lineWidth: 1.5, dash: [7, 7])
                )
        }
        .accessibilityElement(children: .combine)
    }

    private var homeFooter: some View {
        Text("Marginally Better Converter · Version \(bundleVersion)")
            .font(.caption2)
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityLabel("Marginally Better Converter, version \(bundleVersion)")
    }

    private var homeHeaderActions: some View {
        HStack(spacing: 0) {
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
        .font(.system(size: 18, weight: .medium))
        .foregroundStyle(Theme.primary)
        .padding(4)
        .background {
            Capsule()
                .fill(Theme.Home.surface)
        }
        .overlay {
            Capsule()
                .strokeBorder(Theme.Home.controlBorder, lineWidth: 1.5)
        }
        .shadow(
            color: colorScheme == .dark ? .black.opacity(0.18) : Theme.primary.opacity(0.09),
            radius: 16,
            x: 0,
            y: 5
        )
    }

    private var importGridColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ]
    }

    private var importStatusCard: some View {
        importStatusView
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Home.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.Home.controlBorder, lineWidth: 1.5)
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
            guard !urls.isEmpty else { return }
            if urls.count == 1 { Task { await importFile(urls[0]) } }
            else {
                Task {
                    var files: [MediaFile] = []
                    for url in urls { if let file = await viewModel.importFromFiles(url) { files.append(file) } }
                    if !files.isEmpty { path.append(.batch(files)) }
                }
            }
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

    private var settingsView: some View {
        Form {
            Section("Appearance") {
                if dynamicTypeSize.isAccessibilitySize {
                    PopoverDropdown(
                        title: themeSelection.title,
                        accessibilityLabel: "Appearance",
                        options: ThemeSelection.allCases,
                        optionTitle: { $0.title },
                        isSelected: { $0 == themeSelection },
                        onSelect: { themeSelection = $0 }
                    )
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

                Button("Clear Error Log", role: .destructive) {
                    Haptics.warning()
                    DiagnosticsLog.shared.clearErrors()
                    refreshDiagnosticsSummary()
                }
                .disabled(diagnosticsErrorCount == 0)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Errors are saved across launches and can be reviewed, copied, or exported.")
            }
            .listRowBackground(Theme.surface)

            Section("App") {
                NavigationLink {
                    OpenSourceLicensesView()
                } label: {
                    Text("Open Source Licenses")
                }
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
        .toolbar(.visible, for: .navigationBar)
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

    private static var allowedContentTypes: [UTType] { [.item] }
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
    @ScaledMetric(relativeTo: .title2) private var iconSize = 27.0

    private var resolvedIconSize: CGFloat {
        // Keep the icon compact when accessibility text needs more room.
        dynamicTypeSize.isAccessibilitySize ? 27 : iconSize
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        icon
                        cardCopy
                        Spacer(minLength: 0)
                    }

                    VStack(alignment: .leading, spacing: 16) {
                        icon
                        cardCopy
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    icon
                    Spacer(minLength: 18)
                    cardCopy
                }
                .frame(maxWidth: .infinity, minHeight: 112, alignment: .leading)
            }
        }
        .padding(20)
        .frame(
            maxWidth: .infinity,
            minHeight: dynamicTypeSize.isAccessibilitySize ? 100 : nil,
            alignment: .leading
        )
        .converterGlass(cornerRadius: 26)
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(size: resolvedIconSize, weight: .regular))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(isEnabled ? Theme.Home.iconForeground : Theme.textMuted)
            .frame(width: resolvedIconSize * 2.1, height: resolvedIconSize * 2.1)
            .background {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .fill(isEnabled ? Theme.primary : Theme.disabledFill)
                    .shadow(color: Theme.primary.opacity(isEnabled ? 0.1 : 0), radius: 10, y: 5)
            }
            .accessibilityHidden(true)
    }

    private var cardCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(.title3, design: .default, weight: .semibold))
                .foregroundStyle(isEnabled ? Theme.text : Theme.textMuted)

        }
        .fixedSize(horizontal: false, vertical: true)
        .multilineTextAlignment(.leading)
    }
}

private struct HomeImportSourceRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var badgeText: String? = nil
    var thumbnail: UIImage? = nil
    var keepsRowContentsOnOneLine = false

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        rowContents
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 24)
            .padding(.vertical, keepsRowContentsOnOneLine ? 10 : 15)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            .background(isEnabled ? Color.clear : Theme.disabledSurface)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var rowContents: some View {
        if keepsRowContentsOnOneLine {
            HStack(spacing: 16) {
                icon
                titleLabel.fixedSize(horizontal: true, vertical: true)
                Spacer(minLength: 8)
                formatBadge
                thumbnailView
                disclosure
            }
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    icon
                    titleLabel.fixedSize()
                    Spacer(minLength: 8)
                    formatBadge
                    thumbnailView
                    disclosure
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        icon
                        Spacer()
                        disclosure
                    }
                    titleLabel
                    formatBadge
                    thumbnailView
                }
            }
        }
    }

    private var icon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 21, weight: .regular))
            .foregroundStyle(isEnabled ? Theme.primary : Theme.textMuted)
            .frame(width: 24)
            .accessibilityHidden(true)
    }

    private var titleLabel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.body.weight(.semibold))
                .foregroundStyle(isEnabled ? Theme.text : Theme.textMuted)

            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var disclosure: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isEnabled ? Theme.primary : Theme.textMuted)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 56, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Theme.Home.controlBorder.opacity(0.55), lineWidth: 1)
                }
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var formatBadge: some View {
        if let badgeText {
            Text(badgeText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEnabled ? Theme.primary : Theme.textMuted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.secondaryFill, in: Capsule())
                .overlay {
                    Capsule().strokeBorder(Theme.primary.opacity(0.12), lineWidth: 0.5)
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
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

#Preview("Home · Accessibility", traits: .fixedLayout(width: 375, height: 812)) {
    NavigationStack {
        HomeView(path: .constant([]))
    }
    .environment(\.dynamicTypeSize, .accessibility5)
    .preferredColorScheme(.light)
}

#Preview("Home · Landscape", traits: .fixedLayout(width: 844, height: 390)) {
    NavigationStack {
        HomeView(path: .constant([]))
    }
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
