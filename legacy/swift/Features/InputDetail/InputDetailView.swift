import SwiftUI
import UIKit

struct InputDetailView: View {
    @Binding var path: [AppRoute]
    @State private var viewModel: InputDetailViewModel
    @State private var outputConfigViewModel: OutputConfigViewModel
    @State private var isScrollInteracting = false
    @State private var isShowingCropEditor = false
    @State private var cachedRun: CachedRun?

    private struct CachedRun {
        let config: ConversionConfig
        let result: ConversionResult
    }

    init(media: MediaFile, path: Binding<[AppRoute]>) {
        self._path = path
        self._viewModel = State(initialValue: InputDetailViewModel(media: media))
        self._outputConfigViewModel = State(initialValue: OutputConfigViewModel(input: media))
    }

    var body: some View {
        @Bindable var outputConfigViewModel = outputConfigViewModel

        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    previewAndMetadataCard(viewModel: outputConfigViewModel)

                    InputMetadataEditor(
                        viewModel: outputConfigViewModel,
                        isMenuInteractionDisabled: isScrollInteracting
                    )

                    OutputConfigForm(
                        viewModel: outputConfigViewModel,
                        isMenuInteractionDisabled: isScrollInteracting
                    ) { handleConvertTap(viewModel: outputConfigViewModel) }
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 20)
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { _ in
                        if !isScrollInteracting {
                            isScrollInteracting = true
                        }
                    }
                    .onEnded { _ in
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                            isScrollInteracting = false
                        }
                    }
            )
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .task {
            await outputConfigViewModel.loadDiscoveredMetadataIfNeeded()
        }
        .onChange(of: path) { _, newPath in
            guard let last = newPath.last else { return }
            guard case .result(let media, let config, let result, let fromHistory) = last,
                  !fromHistory,
                  media == viewModel.media else { return }

            // Keep only the newest run output for this input flow.
            if let previous = cachedRun, previous.result.url != result.url {
                try? FileManager.default.removeItem(at: previous.result.url)
            }
            cachedRun = CachedRun(config: config, result: result)
        }
        .onChange(of: outputConfigViewModel.makeConfig()) { oldConfig, newConfig in
            guard oldConfig != newConfig else { return }
            invalidateCachedRun()
        }
        .onChange(of: isShowingCropEditor) { _, isOpen in
            if !isOpen {
                outputConfigViewModel.refreshAfterCropChange()
            }
        }
        .sheet(isPresented: $isShowingCropEditor) {
            if let dimensions = viewModel.media.dimensions {
                CropEditorView(
                    url: viewModel.media.url,
                    category: viewModel.media.category,
                    sourceDimensions: dimensions,
                    cropRegion: $outputConfigViewModel.cropRegion
                )
                .presentationDetents([.large])
            }
        }
        .onDisappear {
            // If this convert screen is no longer in the stack, the user left this run
            // (for example, back to Home). Drop the cached output.
            guard !path.contains(where: Self.isInputDetailRoute(for: viewModel.media)) else { return }
            invalidateCachedRun()
        }
        .navigationTitle("Convert")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func previewAndMetadataCard(viewModel: OutputConfigViewModel) -> some View {
        HStack(alignment: .top, spacing: 20) {
            previewColumn(viewModel: viewModel)
            metadataSummaryColumn
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func previewColumn(viewModel: OutputConfigViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaPreview(
                url: viewModel.input.url,
                category: viewModel.input.category,
                compact: true,
                showsChrome: false,
                sourceDimensions: viewModel.input.dimensions,
                displayCropRect: viewModel.cropRectForDisplay
            )
            .frame(maxWidth: .infinity)

            if viewModel.shouldShowCrop {
                Button {
                    Haptics.impact(.light)
                    isShowingCropEditor = true
                } label: {
                    Text("Crop")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.background)
                        .frame(width: 104, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Theme.primary)
                        )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 2)
                .accessibilityLabel("Edit crop")
            }
        }
        .frame(minWidth: 200, idealWidth: 260, maxWidth: 320, alignment: .topLeading)
    }

    private var metadataSummaryColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(MetadataFormatter.summaryRows(for: viewModel.media)) { row in
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                    Text(row.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func handleConvertTap(viewModel: OutputConfigViewModel) {
        let config = viewModel.makeConfig()
        if let cachedRun,
           cachedRun.config == config,
           FileManager.default.fileExists(atPath: cachedRun.result.url.path) {
            path.append(.result(viewModel.input, config, cachedRun.result, fromHistory: false))
        } else {
            path.append(.processing(viewModel.input, config))
        }
    }

    private func invalidateCachedRun() {
        if let cachedRun {
            try? FileManager.default.removeItem(at: cachedRun.result.url)
        }
        self.cachedRun = nil
    }

    private static func isInputDetailRoute(for media: MediaFile) -> (AppRoute) -> Bool {
        { route in
            if case .inputDetail(let routeMedia) = route {
                return routeMedia == media
            }
            return false
        }
    }
}

private func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

#Preview {
    NavigationStack {
        InputDetailView(
            media: MediaFile(
                url: URL(fileURLWithPath: "/tmp/example.jpg"),
                originalFilename: "example.jpg",
                category: .image,
                sizeOnDisk: 1_200_000,
                dimensions: CGSize(width: 1920, height: 1080),
                containerFormat: "jpg"
            ),
            path: .constant([])
        )
    }
}
