import SwiftUI
import UIKit

@main
struct ConverterApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var conversionSession = ProcessingViewModel()


    init() {
        ConversionNotifications.shared.install()
        DiagnosticsLog.shared.beginSession()
        FFmpegRuntimeInfo.logSummary()
        TempStorage.cleanAll()
        ImportStorage.cleanAll()
        ConversionHistoryStore.cleanSessionHistory()
    }

    var body: some Scene {
        WindowGroup {
            ConverterRootView(session: conversionSession)
        }
        .onChange(of: scenePhase) { _, phase in
            conversionSession.setBackgrounded(phase == .background)
        }
    }
}

enum AppRoute: Hashable {
    case inputDetail(MediaFile)
    case draft(ConversionDraft)
    case batch([MediaFile])
    case processing(MediaFile, ConversionConfig)
    case result(MediaFile, ConversionConfig, ConversionResult, fromHistory: Bool)
    case history
}

enum RootSection: String, CaseIterable, Identifiable, Hashable {
    case convert
    case history

    var id: Self { self }

    var title: String {
        switch self {
        case .convert: "Convert"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .convert: "arrow.triangle.2.circlepath"
        case .history: "clock.arrow.circlepath"
        }
    }
}

private struct RootSectionActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    var isRootSectionActive: Bool {
        get { self[RootSectionActiveKey.self] }
        set { self[RootSectionActiveKey.self] = newValue }
    }
}

struct ConverterRootView: View {
    @State private var session: ProcessingViewModel

    init(session: ProcessingViewModel? = nil) {
        _session = State(initialValue: session ?? ProcessingViewModel())
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var importError: String?
    @State private var convertPath: [AppRoute] = []
    @State private var historyPath: [AppRoute] = []
    @State private var selectedSection: RootSection? = .convert
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                splitNavigation
            } else {
                // A compact layout has no sidebar to reveal when Done pops to root.
                adaptiveDetail
            }
        }
        .tint(Theme.tint)
        .preferredColorScheme(AppColorMode(rawValue: appColorModeRawValue)?.colorScheme)
        .onAppear {
            adaptNavigation(to: horizontalSizeClass)
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            adaptNavigation(to: newValue)
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            Task {
                do {
                    guard !session.isRunning else { throw ConversionError.invalidInput("Finish the current conversion before opening another file") }
                    let service = ImportService()
                    let owned = try await service.importFromFiles(at: url)
                    let input = try await service.validatedMediaFile(at: owned).withOriginalFilename(url.lastPathComponent)
                    selectedSection = .convert
                    convertPath.append(.inputDetail(input))
                } catch { importError = error.localizedDescription }
            }
        }
        .alert("Couldn't open file", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) { importError = nil }
        } message: { Text(importError ?? "") }
        #if DEBUG
        .task { await seedUIFixturesIfRequested() }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: .conversionWarningOpened)) { notification in
            guard let id = notification.object as? UUID, id == session.attemptID,
                  let input = session.input, let config = session.config else { return }
            selectedSection = .convert
            preferredCompactColumn = .detail
            // Usually the existing screen is still on the stack. A notification
            // can also restore it after a navigation/layout reconstruction.
            if !convertPath.contains(where: { if case .processing = $0 { return true }; return false }) {
                if let result = session.result {
                    convertPath = [.inputDetail(input), .result(input, config, result, fromHistory: false)]
                } else {
                    convertPath = [.inputDetail(input), .processing(input, config)]
                }
            }
        }
    }

    private var splitNavigation: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            List(RootSection.allCases, selection: $selectedSection) { section in
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: section.systemImage)
                            Text(section.title)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Label(section.title, systemImage: section.systemImage)
                            .lineLimit(1)
                    }
                }
                .tag(section)
                .disabled(section == .history && isConversionRunning)
            }
            .navigationTitle("MB Converter")
            .navigationSplitViewColumnWidth(
                min: dynamicTypeSize.isAccessibilitySize ? 260 : 200,
                ideal: dynamicTypeSize.isAccessibilitySize ? 300 : 240,
                max: dynamicTypeSize.isAccessibilitySize ? 360 : 300
            )
            .tint(Theme.tint)
            .scrollContentBackground(.hidden)
            .background(Theme.groupedBackground)
        } detail: {
            adaptiveDetail
        }
    }

    private var isConversionRunning: Bool {
        convertPath.contains { route in
            if case .processing = route { return true }
            return false
        }
    }

    private var adaptiveDetail: some View {
        ZStack {
            NavigationStack(path: $convertPath) {
                HomeView(
                    path: $convertPath,
                    constrainedWidth: horizontalSizeClass != .regular,
                    showsHistoryToolbar: horizontalSizeClass != .regular,
                    showsContentTitle: true
                )
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route, path: $convertPath) {
                        showConvertRoot()
                    }
                }
            }
            .environment(\.isRootSectionActive, selectedSection != .history)
            .opacity(selectedSection == .history ? 0 : 1)
            .allowsHitTesting(selectedSection != .history)
            .accessibilityHidden(selectedSection == .history)
            .zIndex(selectedSection == .history ? 0 : 1)

            // Compact layouts push History onto convertPath. Keeping a second,
            // invisible stack here lets it compete for the same navigation bar.
            if horizontalSizeClass == .regular {
                NavigationStack(path: $historyPath) {
                    ConversionHistoryListView(path: $historyPath)
                        .navigationDestination(for: AppRoute.self) { route in
                            destination(for: route, path: $historyPath) {
                                showConvertRoot()
                            }
                        }
                }
                .environment(\.isRootSectionActive, selectedSection == .history)
                .opacity(selectedSection == .history ? 1 : 0)
                .allowsHitTesting(selectedSection == .history)
                .accessibilityHidden(selectedSection != .history)
                .zIndex(selectedSection == .history ? 1 : 0)
            }
        }
        .navigationBarBackButtonHidden(horizontalSizeClass != .regular)
    }

    private func adaptNavigation(to sizeClass: UserInterfaceSizeClass?) {
        preferredCompactColumn = .detail

        if sizeClass == .regular {
            if let historyIndex = convertPath.firstIndex(where: Self.isHistoryRoute) {
                historyPath = Array(convertPath.dropFirst(historyIndex + 1))
                convertPath.removeSubrange(historyIndex...)
                selectedSection = .history
            }
            columnVisibility = .all
        } else {
            if selectedSection == .history {
                let nestedHistoryPath = historyPath
                historyPath.removeAll()
                convertPath.append(.history)
                convertPath.append(contentsOf: nestedHistoryPath)
                selectedSection = .convert
            }
            columnVisibility = .detailOnly
        }
    }

    private func showConvertRoot() {
        session.dismissAttempt()
        convertPath.removeAll()
        historyPath.removeAll()
        selectedSection = .convert
        preferredCompactColumn = .detail
    }

    private static func isHistoryRoute(_ route: AppRoute) -> Bool {
        if case .history = route { return true }
        return false
    }

    @ViewBuilder
    private func destination(
        for route: AppRoute,
        path: Binding<[AppRoute]>,
        onConvertAnother: @escaping () -> Void
    ) -> some View {
        switch route {
        case .inputDetail(let media):
            InputDetailView(media: media, path: path)
        case .draft(let draft):
            InputDetailView(media: draft.input, path: path, restoredConfig: draft.config)
        case .batch(let files):
            BatchConversionView(inputs: files)
        case .processing(let media, let config):
            ProcessingView(input: media, config: config, path: path, session: session)
        case .result(let media, let config, let result, let fromHistory):
            ResultView(
                input: media,
                config: config,
                result: result,
                fromHistory: fromHistory,
                path: path,
                onConvertAnother: onConvertAnother
            )
        case .history:
            ConversionHistoryListView(path: path)
        }
    }
}

#Preview("App · Compact · Light", traits: .fixedLayout(width: 390, height: 844)) {
    ConverterRootView()
        .environment(\.horizontalSizeClass, .compact)
        .preferredColorScheme(.light)
}

#Preview("App · Regular · Dark", traits: .fixedLayout(width: 1_024, height: 768)) {
    ConverterRootView()
        .environment(\.horizontalSizeClass, .regular)
        .preferredColorScheme(.dark)
}

#if DEBUG
private extension ConverterRootView {
    func seedUIFixturesIfRequested() async {
        guard ProcessInfo.processInfo.arguments.contains(where: { $0 == "uitest-fixtures" || $0 == "-uitest-fixtures" }) || UserDefaults.standard.bool(forKey: "uitest-fixtures"), !UserDefaults.standard.bool(forKey: "UIFixturesSeeded") else { return }
        do {
            let source = ImportStorage.directory.appendingPathComponent("Sample.txt")
            try Data("A document that stays on your iPhone.\n\nConvert to Word, select pages, or make a smaller PDF.\n\nAll processing runs on this device.".utf8).write(to: source)
            let text = try await MediaInspector.inspect(url: source)
            let result = try await DocumentConverter().convert(input: text, config: .init(outputFormat: .pdf), progress: { _ in }, encodingStats: nil)
            let pdf = try await MediaInspector.inspect(url: result.url).withOriginalFilename("Sample.pdf")
            try await ConversionDraftStore.shared.save(input: pdf, config: .init(outputFormat: .pdf))
            let imageURL = ImportStorage.directory.appendingPathComponent("Sample.png")
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 640, height: 480))
            let image = renderer.image { context in
                UIColor.systemTeal.setFill(); context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
                UIColor.systemBlue.setFill(); context.cgContext.fillEllipse(in: CGRect(x: 220, y: 140, width: 200, height: 200))
            }
            try image.pngData()!.write(to: imageURL)
            let photo = try await MediaInspector.inspect(url: imageURL)
            try await ConversionDraftStore.shared.save(input: photo, config: .init(outputFormat: .jpg))
            UserDefaults.standard.set(true, forKey: "UIFixturesSeeded")
            if ProcessInfo.processInfo.arguments.contains(where: { $0 == "uitest-batch" || $0 == "-uitest-batch" }) || UserDefaults.standard.bool(forKey: "uitest-batch") {
                let secondPDF = try await MediaInspector.inspect(url: result.url).withOriginalFilename("Another.pdf")
                convertPath.append(.batch([pdf, secondPDF]))
            }
        } catch { importError = error.localizedDescription }
    }
}
#endif
