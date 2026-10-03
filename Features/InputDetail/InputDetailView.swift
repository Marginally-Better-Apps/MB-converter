import SwiftUI
import UIKit

struct InputDetailView: View {
    @Binding var path: [AppRoute]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel: InputDetailViewModel
    @State private var outputConfigViewModel: OutputConfigViewModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var draftError: String?
    @State private var completedConfig: ConversionConfig?
    @State private var isLeaving = false
    @State private var isShowingCropEditor = false
    @State private var isShowingAudioEditor = false
    @State private var isDiscardConfirmationPresented = false
    @State private var trimmedMediaURL: URL?
    @State private var selectedEditor: Editor?
    @State private var cachedRun: CachedRun?

    private enum Editor: String, Identifiable {
        case advancedOutput
        case metadata

        var id: String { rawValue }
    }

    private struct CachedRun {
        let config: ConversionConfig
        let result: ConversionResult
    }

    init(media: MediaFile, path: Binding<[AppRoute]>, restoredConfig: ConversionConfig? = nil) {
        self._path = path
        self._viewModel = State(initialValue: InputDetailViewModel(media: media))
        let model = OutputConfigViewModel(input: media)
        if let restoredConfig { model.restore(restoredConfig) }
        self._outputConfigViewModel = State(initialValue: model)
    }

    var body: some View {
        @Bindable var outputConfigViewModel = outputConfigViewModel

        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 16) {
                    previewAndMetadataCard(viewModel: outputConfigViewModel)

                    essentialOutputSection(viewModel: outputConfigViewModel)

                    if outputConfigViewModel.input.category == .document {
                        DocumentOptionsView(viewModel: outputConfigViewModel)
                    }
                    if outputConfigViewModel.input.category == .image, outputConfigViewModel.selectedFormat.category == .image {
                        ImageEnhancementOptions(viewModel: outputConfigViewModel)
                    }
                    if [.docx, .odt].contains(outputConfigViewModel.selectedFormat) || (["docx", "odt"].contains(outputConfigViewModel.input.containerFormat) && outputConfigViewModel.selectedFormat == .pdf) {
                        Text("Editable text. Images and layout aren’t preserved.").font(.caption).foregroundStyle(Theme.textMuted)
                    }
                    editorLinks(viewModel: outputConfigViewModel)
                }
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
            .simultaneousGesture(
                TapGesture().onEnded {
                    dismissKeyboard()
                }
            )
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            convertActionBar(viewModel: outputConfigViewModel)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { gesture in
                    // Reserve back navigation for a deliberate swipe from the
                    // left edge so scrolling and output sliders keep working.
                    guard gesture.startLocation.x <= 24,
                          gesture.translation.width >= 80,
                          gesture.translation.width > abs(gesture.translation.height) * 1.5 else { return }
                    requestDiscardConfirmation()
                }
        )
        .task(id: outputConfigViewModel.input.url) {
            await outputConfigViewModel.loadDiscoveredMetadataIfNeeded()
        }
        .task(id: outputConfigViewModel.pngBaselineRequest) {
            await outputConfigViewModel.preparePNGBaseline()
        }
        .onChange(of: path) { _, newPath in
            guard let last = newPath.last else { return }
            guard case .result(let media, let config, let result, let fromHistory) = last,
                  !fromHistory,
                  media.id == viewModel.media.id else { return }

            // Keep only the newest run output for this input flow.
            if let previous = cachedRun, previous.result.url != result.url {
                try? FileManager.default.removeItem(at: previous.result.url)
            }
            cachedRun = CachedRun(config: config, result: result)
            completedConfig = config
        }
        .onChange(of: outputConfigViewModel.cacheInvalidationConfig) { oldConfig, newConfig in
            guard let oldConfig, let newConfig else { return }
            guard oldConfig != newConfig else { return }
            invalidateCachedRun()
        }
        .task(id: outputConfigViewModel.cacheInvalidationConfig) {
            guard outputConfigViewModel.hasCompletedMetadataDiscovery else { return }
            do { try await Task.sleep(for: .milliseconds(250)); try await checkpointDraft() }
            catch is CancellationError { }
            catch { draftError = error.localizedDescription }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { try? await checkpointDraft() } }
        }
        .alert("Couldn't save draft", isPresented: Binding(get: { draftError != nil }, set: { if !$0 { draftError = nil } })) {
            Button("OK", role: .cancel) { draftError = nil }
        } message: { Text(draftError ?? "") }
        .onChange(of: isShowingCropEditor) { _, isOpen in
            if !isOpen {
                outputConfigViewModel.refreshAfterCropChange()
            }
        }
        .sheet(isPresented: $isShowingCropEditor) {
            if let dimensions = outputConfigViewModel.input.dimensions {
                CropEditorView(
                    url: outputConfigViewModel.input.url,
                    category: outputConfigViewModel.input.category,
                    sourceDimensions: dimensions,
                    cropRegion: $outputConfigViewModel.cropRegion,
                    mediaRotation: $outputConfigViewModel.mediaRotation,
                    isMirrored: $outputConfigViewModel.isMirrored,
                    showsVideoAudioControls: outputConfigViewModel.selectedFormat.category == .video
                        && outputConfigViewModel.input.audioCodec != nil,
                    audioEdits: $outputConfigViewModel.audioEdits,
                    onTrimVideo: { [outputConfigViewModel] sourceURL, range in
                        let ownedURL = try await outputConfigViewModel.trimVideo(sourceURL: sourceURL) {
                            try await VideoTrimmer.trimmedMedia(sourceURL: sourceURL, range: range)
                        }
                        let previousTrimmedURL = trimmedMediaURL
                        invalidateCachedRun()
                        trimmedMediaURL = ownedURL
                        if let previousTrimmedURL {
                            try? FileManager.default.removeItem(at: previousTrimmedURL)
                        }
                    }
                )
                .presentationDetents([.large])
            }
        }
        .sheet(isPresented: $isShowingAudioEditor) {
            if let duration = outputConfigViewModel.input.duration, duration.isFinite, duration > 0 {
                AudioEditorView(url: outputConfigViewModel.input.url,
                                filename: outputConfigViewModel.input.originalFilename, duration: duration,
                                settings: $outputConfigViewModel.audioEdits)
                    .presentationDetents([.large])
            }
        }
        .onDisappear {
            // If this convert screen is no longer in the stack, the user left this run
            // (for example, back to Home). Drop the cached output.
            guard !path.contains(where: Self.isInputDetailRoute(for: viewModel.media)) else { return }
            invalidateCachedRun()
            if let trimmedMediaURL {
                try? FileManager.default.removeItem(at: trimmedMediaURL)
                self.trimmedMediaURL = nil
            }
        }
        .navigationTitle(isRootSectionActive ? viewModel.media.originalFilename : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if isRootSectionActive && selectedEditor == nil {
                ToolbarItem(placement: .principal) {
                    Text(viewModel.media.originalFilename)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .accessibilityAddTraits(.isHeader)
                }

                ToolbarItem(placement: .topBarLeading) {
                    Button(action: requestDiscardConfirmation) {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Theme.tint)
                    }
                    .accessibilityLabel("Back to main page")
                }
            }
        }
        .background(
            ConvertBackNavigationGuard(isActive: selectedEditor == nil)
                .frame(width: 0, height: 0)
        )
        .navigationDestination(item: $selectedEditor) { editor in
            editorDestination(editor)
                .tint(Theme.tint)
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
                VStack(alignment: .leading, spacing: 8) {
                    previewColumn(viewModel: viewModel)
                    VStack(alignment: .leading, spacing: 8) {
                        Divider()
                            .overlay(Theme.separator)
                        metadataSummaryColumn
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 16)
        .background(Theme.groupedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func previewColumn(viewModel: OutputConfigViewModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            MediaPreview(
                url: viewModel.input.url,
                category: viewModel.isAudioOutput ? .audio : viewModel.input.category,
                compact: true,
                showsChrome: false,
                showsMediaBorder: true,
                sourceDimensions: viewModel.input.dimensions,
                displayCropRect: viewModel.cropRectForDisplay,
                mediaRotation: viewModel.mediaRotation,
                isMirrored: viewModel.isMirrored,
                isInteractive: !viewModel.shouldShowAudioEditor,
                preferredHeight: 280
            )
            .frame(
                minWidth: usesSideBySidePreviewLayout ? 280 : nil,
                idealWidth: usesSideBySidePreviewLayout ? 360 : nil,
                maxWidth: usesSideBySidePreviewLayout ? 420 : .infinity,
                alignment: .topLeading
            )
            .overlay {
                if viewModel.shouldShowAudioEditor {
                    Button {
                        isShowingAudioEditor = true
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Preview and edit audio")
                    .overlay(alignment: .topTrailing) {
                        editMediaButton(viewModel: viewModel).padding(8)
                    }
                } else if viewModel.shouldShowCrop, let dimensions = viewModel.input.dimensions {
                    GeometryReader { proxy in
                        let displayedSize = viewModel.mediaRotation.applied(to: dimensions)
                        let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: 2, dy: 2)
                        let scale = min(
                            bounds.width / max(displayedSize.width, 1),
                            bounds.height / max(displayedSize.height, 1)
                        )
                        let width = displayedSize.width * scale
                        let height = displayedSize.height * scale

                        editMediaButton(viewModel: viewModel)
                            .padding(8)
                            .frame(width: width, height: height, alignment: .topTrailing)
                            .position(x: bounds.midX, y: bounds.midY)
                    }
                }
            }
            if viewModel.isAudioOutput, !viewModel.audioEdits.isIdentity,
               let duration = viewModel.audioOutputDuration {
                Text("Edited audio · \(VideoTrimTimeline.timestamp(duration)) · \(Int((viewModel.audioEdits.volume * 100).rounded()))% · \(String(format: "%.2f×", viewModel.audioEdits.speed)) · \(viewModel.audioEdits.channels.label)")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            } else if viewModel.input.category == .video,
                      viewModel.input.audioCodec != nil,
                      viewModel.selectedFormat.category == .video,
                      !viewModel.audioEdits.videoTrackIsIdentity {
                Text("Edited video audio · \(Int((viewModel.audioEdits.volume * 100).rounded()))% · \(viewModel.audioEdits.channels.label)")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    @ViewBuilder
    private func editMediaButton(viewModel: OutputConfigViewModel) -> some View {
        if viewModel.shouldShowCrop || viewModel.shouldShowAudioEditor {
            Button("Edit") {
                Haptics.impact(.light)
                if viewModel.shouldShowAudioEditor { isShowingAudioEditor = true }
                else { isShowingCropEditor = true }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.bordered)
            .buttonBorderShape(.roundedRectangle(radius: 10))
            .tint(Theme.tint)
            .fixedSize()
            .background(Theme.groupedSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Theme.tint, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 6, x: 0, y: 3)
            .accessibilityLabel(viewModel.shouldShowAudioEditor ? "Edit audio" : (viewModel.input.category == .video ? "Edit video" : "Edit image"))
        }
    }

    private var usesSideBySidePreviewLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private var metadataSummaryColumn: some View {
        LazyVGrid(
            columns: Array(
                repeating: GridItem(.flexible(), spacing: 12, alignment: .leading),
                count: 3
            ),
            alignment: .leading,
            spacing: 14
        ) {
            ForEach(MetadataFormatter.summaryRows(
                for: outputConfigViewModel.input,
                durationBeforeTrim: outputConfigViewModel.durationBeforeTrim
            )) { row in
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
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Format")
                            .foregroundStyle(Theme.text)
                        FormatPicker(
                            formats: viewModel.formats,
                            inputCategory: viewModel.input.category,
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
                            selection: Binding(
                                get: { viewModel.selectedFormat },
                                set: { viewModel.selectedFormat = $0 }
                            )
                        )
                        .fixedSize(horizontal: true, vertical: false)
                    }
                }
            }

            if viewModel.shouldShowPNGDimensions {
                Divider().overlay(Theme.separator)
                PNGDimensionsSlider(viewModel: viewModel)
            } else if viewModel.shouldShowTargetSize {
                Divider()
                    .overlay(Theme.separator)
                VStack(alignment: .leading, spacing: 12) {
                    TargetSizeHeader(
                        title: viewModel.targetControlTitle,
                        suggestedMegabytes: viewModel.suggestedTargetSizesMB,
                        targetSizeBytes: viewModel.targetSizeBytes,
                        onSelect: viewModel.applyTargetSizeSuggestion
                    )
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
                }
            } else if let note = viewModel.losslessNote {
                Divider()
                    .overlay(Theme.separator)
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.groupedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func editorLinks(viewModel: OutputConfigViewModel) -> some View {
        VStack(spacing: 0) {
            if hasAdvancedOutputOptions(viewModel) {
                Button {
                    selectedEditor = .advancedOutput
                } label: {
                    editorLinkLabel(
                        title: "Advanced Output",
                        systemImage: "slider.horizontal.3",
                        detail: advancedOutputSummary(viewModel)
                    )
                }

                Divider()
                    .padding(.leading, 56)
                    .overlay(Theme.separator)
            }

            if [.image, .video, .audio, .animatedImage].contains(viewModel.input.category) {
                Button {
                    selectedEditor = .metadata
                } label: {
                    editorLinkLabel(
                        title: "Metadata",
                        systemImage: "info.circle",
                        detail: metadataSummary(viewModel)
                    )
                }
            }
        }
        .buttonStyle(.plain)
        .background(Theme.groupedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func editorDestination(_ editor: Editor) -> some View {
        switch editor {
        case .advancedOutput:
            OutputConfigForm(
                viewModel: outputConfigViewModel,
                isMenuInteractionDisabled: false,
                showsPrimaryControls: false,
                showsConvertButton: false,
                onConvert: {}
            )
            .navigationTitle(isRootSectionActive ? "Advanced Output" : "")
            .navigationBarTitleDisplayMode(.inline)
            .modifier(ConversionEditorNavigation(backTitle: "Convert") {
                selectedEditor = nil
            })
        case .metadata:
            InputMetadataEditor(
                viewModel: outputConfigViewModel,
                isMenuInteractionDisabled: false,
                onBack: { selectedEditor = nil }
            )
        }
    }

    private func editorLinkLabel(title: String, systemImage: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.tint)
                .frame(width: 32, height: 32)
                .background(Theme.secondaryFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

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
            values.append(viewModel.usesTwoPassVideoEncoding ? "Two-pass target" : "Single-pass target")
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
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .tint(Theme.tint)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .converterGlass(cornerRadius: 22)
        .disabled(!viewModel.canConvert || isLeaving)
        .accessibilityHint(viewModel.canConvert
            ? "Starts the conversion using the selected settings."
            : "Change an output setting to convert this file.")
    }

    private func handleConvertTap(viewModel: OutputConfigViewModel) {
        guard viewModel.canConvert else { return }
        let config = viewModel.makeConfig()
        if let cachedRun,
           cachedRun.config == config,
           FileManager.default.fileExists(atPath: cachedRun.result.url.path) {
            path.append(.result(viewModel.input, config, cachedRun.result, fromHistory: false))
        } else {
            isLeaving = true
            Task {
                defer { isLeaving = false }
                do {
                    try await ConversionDraftStore.shared.save(input: viewModel.input, config: config)
                    path.append(.processing(viewModel.input, config))
                } catch { draftError = error.localizedDescription }
            }
        }
    }

    private func invalidateCachedRun() {
        if let cachedRun {
            try? FileManager.default.removeItem(at: cachedRun.result.url)
        }
        self.cachedRun = nil
    }

    private func checkpointDraft() async throws {
        let config = outputConfigViewModel.makeConfig()
        guard config != completedConfig else { return }
        try await ConversionDraftStore.shared.save(input: outputConfigViewModel.input, config: config)
    }

    private func requestDiscardConfirmation() {
        guard isRootSectionActive, selectedEditor == nil, !isLeaving else { return }
        isLeaving = true
        Task {
            defer { isLeaving = false }
            await outputConfigViewModel.loadDiscoveredMetadataIfNeeded()
            do {
                try await checkpointDraft()
                Haptics.impact(.light)
                if !path.isEmpty { path.removeLast() }
            } catch { draftError = error.localizedDescription }
        }
    }

    private func discardConversion() { requestDiscardConfirmation() }

    private static func isInputDetailRoute(for media: MediaFile) -> (AppRoute) -> Bool {
        { route in
            if case .inputDetail(let routeMedia) = route { return routeMedia.id == media.id }
            if case .draft(let draft) = route { return draft.input.id == media.id }
            return false
        }
    }
}

/// Editor back actions only clear their own presentation binding, preserving
/// the Convert route and its shared output settings for export.
struct ConversionEditorNavigation: ViewModifier {
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    var isActive = true
    let backTitle: String
    let onBack: () -> Void

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden()
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onEnded { gesture in
                        // Only the left edge navigates back; horizontal sliders
                        // and vertical scrolling remain available elsewhere.
                        guard isRootSectionActive, isActive,
                              gesture.startLocation.x <= 24,
                              gesture.translation.width >= 80,
                              gesture.translation.width > abs(gesture.translation.height) * 1.5 else { return }
                        goBack()
                    }
            )
            .toolbar {
                if isRootSectionActive && isActive {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: goBack) {
                            Image(systemName: "chevron.left")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Theme.tint)
                        }
                        .accessibilityLabel("Back to \(backTitle)")
                    }
                }
            }
            .background(
                ConvertBackNavigationGuard(isActive: isActive)
                    .frame(width: 0, height: 0)
            )
    }

    private func goBack() {
        Haptics.impact(.light)
        onBack()
    }
}

struct ConvertBackNavigationGuard: UIViewControllerRepresentable {
    var isActive = true

    func makeUIViewController(context: Context) -> ConvertBackNavigationViewController {
        ConvertBackNavigationViewController()
    }

    func updateUIViewController(
        _ uiViewController: ConvertBackNavigationViewController,
        context: Context
    ) {
        uiViewController.isActive = isActive
        uiViewController.updateBackNavigation()
    }
}

final class ConvertBackNavigationViewController: UIViewController {
    var isActive = true

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateBackNavigation()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateBackNavigation()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateBackNavigation()
    }

    func updateBackNavigation() {
        guard isActive, let navigationController else { return }
        var owner = parent
        while let current = owner, current.parent !== navigationController {
            owner = current.parent
        }
        guard let owner, navigationController.topViewController === owner else { return }

        // Also hide UIKit's automatic arrow on the hosting controller. It can
        // reappear alongside the SwiftUI button and pop the outer Convert route.
        if !owner.navigationItem.hidesBackButton {
            owner.navigationItem.setHidesBackButton(true, animated: false)
        }
        // Editor swipes run the same state change as the custom Back button.
        navigationController.interactivePopGestureRecognizer?.isEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Let the next screen choose its own back-swipe behavior.
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
