import SwiftUI
import UIKit

struct InputDetailView: View {
    @Binding var path: [AppRoute]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel: InputDetailViewModel
    @State private var outputConfigViewModel: OutputConfigViewModel
    @State private var isShowingCropEditor = false
    @State private var isShowingAudioEditor = false
    @State private var isDiscardConfirmationPresented = false
    @State private var trimmedMediaURL: URL?
    @State private var selectedEditor: Editor?
    @State private var cachedRun: CachedRun?
    @State private var previewWidth: CGFloat = 0

    private enum Editor: String, Identifiable {
        case advancedOutput
        case metadata

        var id: String { rawValue }
    }

    private struct CachedRun {
        let inputURL: URL
        let config: ConversionConfig
        let result: ConversionResult
    }

    init(media: MediaFile, path: Binding<[AppRoute]>) {
        self._path = path
        self._viewModel = State(initialValue: InputDetailViewModel(media: media))
        let outputConfigViewModel = OutputConfigViewModel(input: media)
        outputConfigViewModel.removeAllMetadata = UserDefaults.standard.bool(
            forKey: InputMetadataEditor.removeAllMetadataDefaultsKey
        )
        self._outputConfigViewModel = State(initialValue: outputConfigViewModel)
    }

    var body: some View {
        @Bindable var outputConfigViewModel = outputConfigViewModel

        ScrollView {
            Group {
                if usesSideBySideLayout {
                    HStack(alignment: .top, spacing: 24) {
                        mediaCard(viewModel: outputConfigViewModel)
                            .frame(minWidth: 300, maxWidth: 460)
                        settingsColumn(viewModel: outputConfigViewModel)
                    }
                } else {
                    VStack(spacing: 26) {
                        mediaCard(viewModel: outputConfigViewModel)
                        settingsColumn(viewModel: outputConfigViewModel)
                    }
                }
            }
            .frame(maxWidth: 980)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissKeyboard()
            }
        )
        .scrollDismissesKeyboard(.interactively)
        .scrollBounceBehavior(.basedOnSize)
        .background(Theme.background.ignoresSafeArea())
        .floatingBottomBar {
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
        .task(id: outputConfigViewModel.livePhotoMovieURL) {
            await loadLivePhotoMovie()
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
            cachedRun = CachedRun(inputURL: media.url, config: config, result: result)
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
                    showsVideoSpeedControls: outputConfigViewModel.selectedFormat.category == .video,
                    audioEdits: $outputConfigViewModel.audioEdits,
                    videoSpeed: $outputConfigViewModel.videoSpeed,
                    livePhoto: livePhotoEditing(viewModel: outputConfigViewModel),
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
                    },
                    onSelectKeyPhoto: { time in
                        try await selectLivePhotoKeyPhoto(at: time)
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
            for url in outputConfigViewModel.livePhotoOwnedFileURLs {
                try? FileManager.default.removeItem(at: url)
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

    /// The media on a solid card, with glass controls floating over it.
    private func mediaCard(viewModel: OutputConfigViewModel) -> some View {
        VStack(spacing: 0) {
            mediaPreview(viewModel: viewModel)
                .padding(12)

            Divider()
                .padding(.horizontal, 16)

            InfoStrip(rows: MetadataFormatter.summaryRows(
                for: viewModel.input,
                durationBeforeTrim: viewModel.durationBeforeTrim
            ))
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? 16 : 4)
            .padding(.vertical, 14)

            if let summary = editSummary(viewModel: viewModel) {
                Label {
                    Text(summary)
                } icon: {
                    Image(systemName: "pencil.and.outline")
                        .foregroundStyle(Theme.tint)
                }
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.bottom, 14)
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func mediaPreview(viewModel: OutputConfigViewModel) -> some View {
        MediaPreview(
            url: viewModel.input.url,
            category: viewModel.isAudioOutput ? .audio : viewModel.input.category,
            compact: true,
            showsChrome: false,
            showsMediaBorder: false,
            sourceDimensions: viewModel.input.dimensions,
            displayCropRect: viewModel.cropRectForDisplay,
            mediaRotation: viewModel.mediaRotation,
            isMirrored: viewModel.isMirrored,
            isInteractive: !viewModel.shouldShowAudioEditor,
            preferredHeight: previewHeight(viewModel: viewModel)
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { previewWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in previewWidth = width }
            }
        }
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
                    editMediaButton(viewModel: viewModel).padding(10)
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

                    ZStack {
                        if viewModel.isLivePhoto {
                            livePhotoBadge
                                .padding(10)
                                .frame(width: width, height: height, alignment: .topLeading)
                        }
                        editMediaButton(viewModel: viewModel)
                            .padding(10)
                            .frame(width: width, height: height, alignment: .topTrailing)
                    }
                    .position(x: bounds.midX, y: bounds.midY)
                }
            }
        }
    }

    /// Fits the media's shape so wide videos don't sit in a tall letterbox.
    private func previewHeight(viewModel: OutputConfigViewModel) -> CGFloat {
        let maximum: CGFloat = usesSideBySideLayout ? 380 : 320
        guard !viewModel.isAudioOutput, viewModel.input.category != .audio,
              let dimensions = viewModel.input.dimensions, previewWidth > 0 else {
            return viewModel.isAudioOutput || viewModel.input.category == .audio ? 200 : 260
        }
        let displayed = viewModel.mediaRotation.applied(to: dimensions)
        guard displayed.width > 0, displayed.height > 0 else { return 260 }
        let fitted = (previewWidth - 4) * displayed.height / displayed.width + 4
        return min(maximum, max(180, fitted.rounded()))
    }

    private func editSummary(viewModel: OutputConfigViewModel) -> String? {
        if viewModel.isAudioOutput, !viewModel.audioEdits.isIdentity,
           let duration = viewModel.audioOutputDuration {
            return "Edited audio · \(VideoTrimTimeline.timestamp(duration)) · \(Int((viewModel.audioEdits.volume * 100).rounded()))% · \(String(format: "%.2f×", viewModel.audioEdits.speed)) · \(viewModel.audioEdits.channels.label)"
        } else if viewModel.input.category == .video,
                  viewModel.selectedFormat.category == .video {
            return videoEditSummary(viewModel: viewModel)
        } else if viewModel.input.category == .image,
                  let keyPhotoTime = viewModel.livePhotoKeyPhotoTime {
            return "Key photo from Live Photo · \(VideoTrimTimeline.timestamp(keyPhotoTime))"
        }
        return nil
    }

    private func videoEditSummary(viewModel: OutputConfigViewModel) -> String? {
        let editsAudio = viewModel.input.audioCodec != nil && !viewModel.audioEdits.videoTrackIsIdentity
        let audio = "\(Int((viewModel.audioEdits.volume * 100).rounded()))% · \(viewModel.audioEdits.channels.label)"
        guard viewModel.effectiveVideoSpeed != 1, let duration = viewModel.videoOutputDuration else {
            return editsAudio ? "Edited video audio · \(audio)" : nil
        }
        let speed = "Edited video · \(String(format: "%.2f×", viewModel.effectiveVideoSpeed)) · \(VideoTrimTimeline.timestamp(duration))"
        return editsAudio ? "\(speed) · audio \(audio)" : speed
    }

    /// Matches the Live Photo marker in Photos: a small static tag, not glass
    /// like the Edit button, so it doesn't read as tappable.
    private var livePhotoBadge: some View {
        Label("LIVE", systemImage: "livephoto")
            .labelStyle(LivePhotoTagLabelStyle())
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .fixedSize()
            .accessibilityLabel("Live Photo")
            .accessibilityHint("Choose a video format to export the motion, or edit to pick the key photo.")
    }

    @ViewBuilder
    private func editMediaButton(viewModel: OutputConfigViewModel) -> some View {
        if viewModel.shouldShowCrop || viewModel.shouldShowAudioEditor {
            Button {
                Haptics.impact(.light)
                if viewModel.shouldShowAudioEditor { isShowingAudioEditor = true }
                else { isShowingCropEditor = true }
            } label: {
                Label("Edit", systemImage: viewModel.shouldShowAudioEditor ? "waveform" : "crop.rotate")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassSurface(in: Capsule(), interactive: true)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel(viewModel.shouldShowAudioEditor ? "Edit audio" : (viewModel.input.category == .video ? "Edit video" : "Edit image"))
        }
    }

    private var usesSideBySideLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private func settingsColumn(viewModel: OutputConfigViewModel) -> some View {
        VStack(alignment: .leading, spacing: 26) {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Output")
                essentialOutputSection(viewModel: viewModel)
            }

            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: "Options")
                editorLinks(viewModel: viewModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func essentialOutputSection(viewModel: OutputConfigViewModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Format")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        FormatPicker(
                            formats: viewModel.formats,
                            inputCategory: viewModel.input.category,
                            isLivePhoto: viewModel.isLivePhoto,
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
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 12)
                        FormatPicker(
                            formats: viewModel.formats,
                            inputCategory: viewModel.input.category,
                            isLivePhoto: viewModel.isLivePhoto,
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
                Divider()
                PNGDimensionsSlider(viewModel: viewModel)
            } else if viewModel.shouldShowTargetSize {
                Divider()
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
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quality")
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text("\(Int((viewModel.webpQuality * 100).rounded()))%")
                        .font(.title2.weight(.bold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.tint)
                        .accessibilityHidden(true)
                    Slider(
                        value: Binding(
                            get: { viewModel.webpQuality },
                            set: { viewModel.webpQuality = $0 }
                        ),
                        in: 0...1,
                        step: 0.01
                    )
                    .tint(Theme.tint)
                    .accessibilityLabel("Quality")
                    .accessibilityValue("\(Int((viewModel.webpQuality * 100).rounded())) percent")
                    Text("Faster single-pass encoding; the final file size is estimated.")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            } else if let note = viewModel.losslessNote {
                Divider()
                Label {
                    Text(note)
                } icon: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(Theme.tint)
                }
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
            }
        }
        .surfaceCard(padding: 18)
    }

    @ViewBuilder
    private func editorLinks(viewModel: OutputConfigViewModel) -> some View {
        VStack(spacing: 0) {
            if hasAdvancedOutputOptions(viewModel) {
                Button {
                    Haptics.impact(.light)
                    selectedEditor = .advancedOutput
                } label: {
                    editorLinkLabel(
                        title: "Advanced Output",
                        systemImage: "slider.horizontal.3",
                        detail: advancedOutputSummary(viewModel)
                    )
                }

                Divider()
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 16 : 62)
            }

            Button {
                Haptics.impact(.light)
                selectedEditor = .metadata
            } label: {
                editorLinkLabel(
                    title: "Metadata",
                    systemImage: "info.circle.fill",
                    detail: metadataSummary(viewModel)
                )
            }
        }
        .buttonStyle(RowButtonStyle())
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
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
        HStack(spacing: 14) {
            IconTile(systemImage: systemImage)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
            }
            .multilineTextAlignment(.leading)

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 62)
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
            PrimaryActionLabel(title: "Convert", systemImage: "arrow.triangle.2.circlepath")
        }
        .glassButtonStyle(prominent: true)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Theme.tint)
        .disabled(!viewModel.canConvert)
        .accessibilityHint(viewModel.canConvert
            ? "Starts the conversion using the selected settings."
            : "Change an output setting to convert this file.")
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func handleConvertTap(viewModel: OutputConfigViewModel) {
        guard viewModel.canConvert else { return }
        let config = viewModel.makeConfig()
        if let cachedRun,
           cachedRun.inputURL == viewModel.input.url,
           cachedRun.config == config,
           FileManager.default.fileExists(atPath: cachedRun.result.url.path) {
            path.append(.result(viewModel.input, config, cachedRun.result, fromHistory: false))
        } else {
            path.append(.processing(viewModel.input, config))
        }
    }

    private func livePhotoEditing(viewModel: OutputConfigViewModel) -> LivePhotoEditing? {
        guard viewModel.input.category == .image, viewModel.livePhotoMovie != nil,
              let movieURL = viewModel.livePhotoMovieURL,
              let original = viewModel.livePhotoOriginalStill else { return nil }
        guard let stillDimensions = original.dimensions,
              let movieDimensions = viewModel.livePhotoMovie?.dimensions else { return nil }
        return LivePhotoEditing(
            movieURL: movieURL,
            originalStillURL: original.url,
            stillDimensions: stillDimensions,
            movieDimensions: movieDimensions,
            originalKeyPhotoTime: viewModel.livePhotoOriginalKeyPhotoTime,
            keyPhotoTime: viewModel.livePhotoKeyPhotoTime
        )
    }

    /// The movie is inspected after import; video formats appear when it is readable.
    private func loadLivePhotoMovie() async {
        let viewModel = outputConfigViewModel
        guard let movieURL = viewModel.livePhotoMovieURL, viewModel.livePhotoMovie == nil else { return }
        do {
            let movie = try await MediaInspector.inspect(url: movieURL)
            let keyPhotoTime = await LivePhotoKeyPhoto.originalTime(in: movieURL)
            try Task.checkCancellation()
            viewModel.attachLivePhotoMovie(movie, originalKeyPhotoTime: keyPhotoTime)
        } catch {
            guard !Task.isCancelled else { return }
            DiagnosticsLog.shared.record(error: error, context: "Inspect Live Photo movie",
                                         metadata: ["Filename": viewModel.input.originalFilename])
        }
    }

    private func selectLivePhotoKeyPhoto(at time: Double?) async throws {
        let viewModel = outputConfigViewModel
        guard let movieURL = viewModel.livePhotoMovieURL,
              let original = viewModel.livePhotoOriginalStill else { return }
        var rendered: MediaFile?
        if let time {
            let still = try await LivePhotoKeyPhoto.render(movieURL: movieURL, at: time, metadataFrom: original.url)
            guard !Task.isCancelled else {
                try? FileManager.default.removeItem(at: still.url)
                throw CancellationError()
            }
            rendered = still
        }
        invalidateCachedRun()
        viewModel.useLivePhotoKeyPhoto(rendered, at: time)
    }

    private func invalidateCachedRun() {
        if let cachedRun {
            try? FileManager.default.removeItem(at: cachedRun.result.url)
        }
        self.cachedRun = nil
    }

    private func requestDiscardConfirmation() {
        guard isRootSectionActive, selectedEditor == nil, !isDiscardConfirmationPresented else { return }
        Haptics.impact(.light)
        isDiscardConfirmationPresented = true
    }

    private func discardConversion() {
        Haptics.warning()
        invalidateCachedRun()
        try? FileManager.default.removeItem(at: viewModel.media.url)
        for url in outputConfigViewModel.livePhotoOwnedFileURLs {
            try? FileManager.default.removeItem(at: url)
        }
        if let trimmedMediaURL {
            try? FileManager.default.removeItem(at: trimmedMediaURL)
            self.trimmedMediaURL = nil
        }
        if !path.isEmpty {
            path.removeLast()
        }
    }

    private static func isInputDetailRoute(for media: MediaFile) -> (AppRoute) -> Bool {
        { route in
            if case .inputDetail(let routeMedia) = route {
                return routeMedia.id == media.id
            }
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

/// Tight icon spacing for the Live Photo tag.
private struct LivePhotoTagLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) {
            configuration.icon
            configuration.title
        }
    }
}
