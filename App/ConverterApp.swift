import SwiftUI

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
    case processing(MediaFile, ConversionConfig)
    case result(MediaFile, ConversionConfig, ConversionResult, fromHistory: Bool)
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

/// Convert and History are tabs, like Apple Music's sections. On iPad the
/// tab bar can expand into a sidebar.
struct ConverterRootView: View {
    @State private var session: ProcessingViewModel

    init(session: ProcessingViewModel? = nil) {
        _session = State(initialValue: session ?? ProcessingViewModel())
    }

    @State private var convertPath: [AppRoute] = []
    @State private var historyPath: [AppRoute] = []
    @State private var selectedSection: RootSection = .convert
    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue

    var body: some View {
        sections
            .tint(Theme.tint)
            .background {
                AppAppearance(mode: AppColorMode(rawValue: appColorModeRawValue) ?? .system)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .onReceive(NotificationCenter.default.publisher(for: .conversionWarningOpened)) { notification in
                guard let id = notification.object as? UUID, id == session.attemptID,
                      let input = session.input, let config = session.config else { return }
                selectedSection = .convert
                // Usually the existing screen is still on the stack. A notification
                // can also restore it after a navigation/layout reconstruction.
                if !isConversionRunning {
                    if let result = session.result {
                        convertPath = [.inputDetail(input), .result(input, config, result, fromHistory: false)]
                    } else {
                        convertPath = [.inputDetail(input), .processing(input, config)]
                    }
                }
            }
    }

    @ViewBuilder
    private var sections: some View {
        if #available(iOS 18.0, *) {
            TabView(selection: sectionSelection) {
                Tab(RootSection.convert.title, systemImage: RootSection.convert.systemImage, value: RootSection.convert) {
                    convertStack
                }
                Tab(RootSection.history.title, systemImage: RootSection.history.systemImage, value: RootSection.history) {
                    historyStack
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .minimizesTabBarOnScroll()
        } else {
            TabView(selection: sectionSelection) {
                convertStack
                    .tabItem { Label(RootSection.convert.title, systemImage: RootSection.convert.systemImage) }
                    .tag(RootSection.convert)
                historyStack
                    .tabItem { Label(RootSection.history.title, systemImage: RootSection.history.systemImage) }
                    .tag(RootSection.history)
            }
        }
    }

    /// History stays out of reach while a conversion owns the Convert tab;
    /// finishing a saved result there returns to a fresh Convert screen.
    private var sectionSelection: Binding<RootSection> {
        Binding(
            get: { selectedSection },
            set: { section in
                guard section != selectedSection else { return }
                guard section != .history || !isConversionRunning else {
                    Haptics.warning()
                    return
                }
                if section == .history {
                    ConversionHistoryStore.shared.refreshForCurrentSettings()
                }
                selectedSection = section
            }
        )
    }

    private var convertStack: some View {
        NavigationStack(path: $convertPath) {
            HomeView(path: $convertPath, onShowHistory: {
                sectionSelection.wrappedValue = .history
            })
            .navigationDestination(for: AppRoute.self) { route in
                destination(for: route, path: $convertPath) {
                    showConvertRoot()
                }
            }
        }
    }

    private var historyStack: some View {
        NavigationStack(path: $historyPath) {
            ConversionHistoryListView(path: $historyPath)
                .navigationDestination(for: AppRoute.self) { route in
                    destination(for: route, path: $historyPath) {
                        showConvertRoot()
                    }
                }
        }
    }

    private var isConversionRunning: Bool {
        convertPath.contains { route in
            if case .processing = route { return true }
            return false
        }
    }


    private func showConvertRoot() {
        session.dismissAttempt()
        convertPath.removeAll()
        historyPath.removeAll()
        selectedSection = .convert
    }

    @ViewBuilder
    private func destination(
        for route: AppRoute,
        path: Binding<[AppRoute]>,
        onConvertAnother: @escaping () -> Void
    ) -> some View {
        Group {
            switch route {
            case .inputDetail(let media):
                InputDetailView(media: media, path: path)
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
            }
        }
        // Each step of a conversion is a focused task with its own bottom actions.
        .toolbar(.hidden, for: .tabBar)
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
