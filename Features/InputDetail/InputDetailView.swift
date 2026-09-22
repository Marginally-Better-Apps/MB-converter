import SwiftUI
import UIKit

struct InputDetailView: View {
    @Binding var path: [AppRoute]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel: InputDetailViewModel
    @State private var outputConfigViewModel: OutputConfigViewModel
    @State private var isScrollInteracting = false
    @State private var isShowingCropEditor = false
    @State private var isDiscardConfirmationPresented = false
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
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 28) {
                    previewAndMetadataCard(viewModel: outputConfigViewModel)

                    essentialOutputSection(viewModel: outputConfigViewModel)

                    editorLinks(viewModel: outputConfigViewModel)
                }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 32)
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
        .safeAreaInset(edge: .bottom) {
            convertActionBar(viewModel: outputConfigViewModel)
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
        .onChange(of: outputConfigViewModel.cacheInvalidationConfig) { oldConfig, newConfig in
            guard let oldConfig, let newConfig else { return }
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
                    cropRegion: $outputConfigViewModel.cropRegion,
                    mediaRotation: $outputConfigViewModel.mediaRotation
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
        .navigationTitle(isRootSectionActive ? "Convert" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            if isRootSectionActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.impact(.light)
                        isDiscardConfirmationPresented = true
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel("Back to main page")
                }
            }
        }
        .background(
            ConvertInteractivePopGestureDisabler()
                .frame(width: 0, height: 0)
        )
        .alert("Discard this conversion?", isPresented: $isDiscardConfirmationPresented) {
            Button("Keep Editing", role: .cancel) {
                Haptics.impact(.light)
            }
            Button("Discard", role: .destructive) {
                discardConversion()
            }
        } message: {
            Text("Your current settings and any cached result for this conversion will be discarded.")
        }
    }

    @ViewBuilder
    private func previewAndMetadataCard(viewModel: OutputConfigViewModel) -> some View {
        Group {
            if usesSideBySidePreviewLayout {
                HStack(alignment: .top, spacing: 24) {
                    previewColumn(viewModel: viewModel)
                    metadataSummaryColumn
                }
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    previewColumn(viewModel: viewModel)
                    Divider()
                        .overlay(Theme.separator)
                    metadataSummaryColumn
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func previewColumn(viewModel: OutputConfigViewModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            MediaPreview(
                url: viewModel.input.url,
                category: viewModel.input.category,
                compact: true,
                showsChrome: false,
                showsMediaBorder: true,
                sourceDimensions: viewModel.input.dimensions,
                displayCropRect: viewModel.cropRectForDisplay,
                mediaRotation: viewModel.mediaRotation
            )
            .frame(maxWidth: .infinity)

            if viewModel.shouldShowCrop {
                Button {
                    Haptics.impact(.light)
                    isShowingCropEditor = true
                } label: {
                    Label("Edit Media", systemImage: "crop.rotate")
                        .font(.subheadline.weight(.semibold))
                }
                .appleGlassButton()
                .buttonBorderShape(.capsule)
                .tint(Theme.tint)
                .frame(maxWidth: .infinity, alignment: .center)
                .accessibilityLabel(viewModel.input.category == .video ? "Edit video" : "Edit image")
            }
        }
        .frame(
            minWidth: usesSideBySidePreviewLayout ? 240 : nil,
            idealWidth: usesSideBySidePreviewLayout ? 300 : nil,
            maxWidth: usesSideBySidePreviewLayout ? 360 : .infinity,
            alignment: .topLeading
        )
    }

    private var usesSideBySidePreviewLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var metadataSummaryColumn: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 140), alignment: .leading)],
            alignment: .leading,
            spacing: 14
        ) {
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

    private func essentialOutputSection(viewModel: OutputConfigViewModel) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Output")
                .font(.headline)
                .foregroundStyle(Theme.text)

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Format")
                            .foregroundStyle(Theme.text)
                        FormatPicker(
                            formats: viewModel.formats,
                            inputCategory: viewModel.input.category,
                            isInteractionDisabled: isScrollInteracting,
                            selection: Binding(
                                get: { viewModel.selectedFormat },
                                set: { viewModel.selectedFormat = $0 }
                            )
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    HStack(alignment: .center, spacing: 16) {
                        Text("Format")
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 12)
                        FormatPicker(
                            formats: viewModel.formats,
                            inputCategory: viewModel.input.category,
                            isInteractionDisabled: isScrollInteracting,
                            selection: Binding(
                                get: { viewModel.selectedFormat },
                                set: { viewModel.selectedFormat = $0 }
                            )
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            if viewModel.shouldShowTargetSize {
                Divider()
                VStack(alignment: .leading, spacing: 12) {
                    Text(viewModel.targetControlTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    TargetSizeSlider(
                        sourceSizeBytes: viewModel.targetSizeSliderReferenceBytes,
                        minimumSizeBytes: viewModel.targetMinimumSizeBytes,
                        valueLabel: viewModel.targetControlValueLabel,
                        minimumLabel: viewModel.targetControlMinimumLabel,
                        estimatedLabel: viewModel.shouldShowTargetSizeEstimate ? viewModel.estimatedLabel : nil,
                        showsRemuxBadge: viewModel.shouldShowRemuxBadgeOnTargetSize,
                        accessibilityLabel: viewModel.targetControlAccessibilityLabel,
                        targetFraction: Binding(
                            get: { viewModel.targetFraction },
                            set: { viewModel.targetFraction = $0 }
                        )
                    )
                }
            } else if viewModel.shouldShowWebPQuality {
                Divider()
                    .overlay(Theme.separator)
                VStack(alignment: .leading, spacing: 10) {
                    LabeledContent("Quality", value: "\(Int((viewModel.webpQuality * 100).rounded()))%")
                        .font(.subheadline.weight(.semibold))
                    Slider(
                        value: Binding(
                            get: { viewModel.webpQuality },
                            set: { viewModel.webpQuality = $0 }
                        ),
                        in: 0...1,
                        step: 0.01
                    )
                        .tint(Theme.tint)
                    Text("Faster single-pass encoding; the final file size is estimated.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            } else if let note = viewModel.losslessNote {
                Divider()
                    .overlay(Theme.separator)
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func editorLinks(viewModel: OutputConfigViewModel) -> some View {
        VStack(spacing: 0) {
            if hasAdvancedOutputOptions(viewModel) {
                NavigationLink {
                    OutputConfigForm(
                        viewModel: viewModel,
                        isMenuInteractionDisabled: false,
                        showsPrimaryControls: false,
                        showsConvertButton: false,
                        onConvert: {}
                    )
                    .navigationTitle(isRootSectionActive ? "Advanced Output" : "")
                    .navigationBarTitleDisplayMode(.inline)
                } label: {
                    editorLinkLabel(
                        title: "Advanced Output",
                        systemImage: "slider.horizontal.3",
                        detail: advancedOutputSummary(viewModel)
                    )
                }

                Divider().padding(.leading, 54)
            }

            NavigationLink {
                InputMetadataEditor(
                    viewModel: viewModel,
                    isMenuInteractionDisabled: false
                )
            } label: {
                editorLinkLabel(
                    title: "Metadata",
                    systemImage: "info.circle",
                    detail: metadataSummary(viewModel)
                )
            }
        }
        .buttonStyle(.plain)
        .padding(6)
        .appleGlass(cornerRadius: 22)
    }

    private func editorLinkLabel(title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
        }
        .frame(minHeight: 52)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func hasAdvancedOutputOptions(_ viewModel: OutputConfigViewModel) -> Bool {
        viewModel.shouldShowResolution
            || viewModel.shouldShowFPS
            || viewModel.shouldShowVideoOutputAudio
            || viewModel.shouldShowSinglePassVideoTargetToggle
    }

    private func advancedOutputSummary(_ viewModel: OutputConfigViewModel) -> String {
        var values: [String] = []
        if viewModel.shouldShowResolution {
            values.append(
                viewModel.resolutionOptions.first(where: { $0.id == viewModel.selectedResolutionID })?.label
                    ?? "Original resolution"
            )
        }
        if viewModel.shouldShowFPS {
            values.append(
                viewModel.fpsOptions.first(where: { $0.value == viewModel.selectedFPS })?.label
                    ?? "Original FPS"
            )
        }
        if viewModel.shouldShowVideoOutputAudio {
            values.append(viewModel.videoAudioQualitySelectionLabel)
        }
        if viewModel.shouldShowSinglePassVideoTargetToggle {
            values.append(viewModel.usesSinglePassVideoTargetEncode ? "Fast encode" : "Two-pass target")
        }
        return values.isEmpty ? "Additional encoding controls" : values.joined(separator: " · ")
    }

    private func metadataSummary(_ viewModel: OutputConfigViewModel) -> String {
        if viewModel.removeAllMetadata {
            return "All metadata will be removed"
        }
        if viewModel.isLoadingDiscoveredMetadata {
            return "Reading metadata…"
        }
        let included = viewModel.metadataFieldRows.filter { !$0.isRemoved }.count
        return "\(included) of \(viewModel.metadataFieldRows.count) fields included"
    }

    private func convertActionBar(viewModel: OutputConfigViewModel) -> some View {
        Button {
            Haptics.impact(.medium)
            handleConvertTap(viewModel: viewModel)
        } label: {
            Label("Convert", systemImage: "arrow.triangle.2.circlepath")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .appleGlassButton(prominent: true)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .disabled(viewModel.isLoadingDiscoveredMetadata)
        .accessibilityHint("Starts the conversion using the selected settings.")
    }

    private func handleConvertTap(viewModel: OutputConfigViewModel) {
        guard !viewModel.isLoadingDiscoveredMetadata else { return }
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

    private func discardConversion() {
        Haptics.warning()
        invalidateCachedRun()
        try? FileManager.default.removeItem(at: viewModel.media.url)
        if !path.isEmpty {
            path.removeLast()
        }
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

private struct ConvertInteractivePopGestureDisabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ConvertInteractivePopGestureViewController {
        ConvertInteractivePopGestureViewController()
    }

    func updateUIViewController(
        _ uiViewController: ConvertInteractivePopGestureViewController,
        context: Context
    ) {}
}

private final class ConvertInteractivePopGestureViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // The guarded Convert screen itself cannot be swiped away, but native
        // edge-swipe navigation remains available in editors pushed above it.
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
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
