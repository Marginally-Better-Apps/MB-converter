import SwiftUI

@main
struct ConverterApp: App {

    init() {
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

struct ConverterRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var path: [AppRoute] = []
    @AppStorage("appColorMode") private var appColorModeRawValue = AppColorMode.system.rawValue

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView {
                    HomeView(path: $path, constrainedWidth: false)
                        .navigationTitle("Import")
                } detail: {
                    detailNavigation
                }
            } else {
                NavigationStack(path: $path) {
                    HomeView(path: $path)
                        .navigationDestination(for: AppRoute.self, destination: destination)
                }
            }
        }
        .preferredColorScheme(AppColorMode(rawValue: appColorModeRawValue)?.colorScheme)
    }

    private var detailNavigation: some View {
        NavigationStack(path: $path) {
            ContentUnavailableView(
                "Choose Media",
                systemImage: "square.and.arrow.down",
                description: Text("Import from Photos, Files, pasteboard, or drop a file to begin.")
            )
            .foregroundStyle(Theme.text)
            .background(Theme.background)
            .navigationDestination(for: AppRoute.self, destination: destination)
        }
    }

    @ViewBuilder
    private func destination(for route: AppRoute) -> some View {
        switch route {
        case .inputDetail(let media):
            InputDetailView(media: media, path: $path)
        case .processing(let media, let config):
            ProcessingView(input: media, config: config, path: $path)
        case .result(let media, let config, let result, let fromHistory):
            ResultView(
                input: media,
                config: config,
                result: result,
                fromHistory: fromHistory,
                path: $path
            )
        case .history:
            ConversionHistoryListView(path: $path)
        }
    }

}

#Preview { ConverterRootView() }
