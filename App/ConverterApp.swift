import SwiftUI

@main
struct ConverterApp: App {

    init() {
        DiagnosticsLog.shared.beginSession()
        FFmpegRuntimeInfo.logSummary()
        TempStorage.cleanAll()
        ImportStorage.cleanAll()
        ConversionHistoryStore.cleanSessionHistory()
    }

    var body: some Scene {
        WindowGroup {
            ConverterRootView()
        }
    }
}

enum AppRoute: Hashable {
    case inputDetail(MediaFile)
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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var convertPath: [AppRoute] = []
    @State private var historyPath: [AppRoute] = []
    @State private var selectedSection: RootSection? = .convert
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .detail
    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue

    var body: some View {
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
        .tint(Theme.tint)
        .preferredColorScheme(AppColorMode(rawValue: appColorModeRawValue)?.colorScheme)
        .onAppear {
            adaptNavigation(to: horizontalSizeClass)
        }
        .onChange(of: horizontalSizeClass) { _, newValue in
            adaptNavigation(to: newValue)
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

            NavigationStack(path: $historyPath) {
                ConversionHistoryListView(path: $historyPath, showsContentTitle: true)
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
        case .processing(let media, let config):
            ProcessingView(input: media, config: config, path: path)
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
