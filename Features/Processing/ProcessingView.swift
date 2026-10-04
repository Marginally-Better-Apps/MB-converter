import SwiftUI

struct ProcessingView: View {
    let input: MediaFile
    let config: ConversionConfig
    @Binding var path: [AppRoute]
    private let startsConversionAutomatically: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ProcessingViewModel
    @State private var processingBeganAt = Date()

    private let minimumVisibleProcessingDuration: TimeInterval = 0.45

    init(
        input: MediaFile,
        config: ConversionConfig,
        path: Binding<[AppRoute]>,
        session: ProcessingViewModel? = nil,
        previewViewModel: ProcessingViewModel? = nil
    ) {
        self.input = input
        self.config = config
        self._path = path
        self._viewModel = State(initialValue: previewViewModel ?? session ?? ProcessingViewModel())
        self.startsConversionAutomatically = previewViewModel == nil
    }

    var body: some View {
        // Scrolls only when the content is taller than the screen.
        ViewThatFits(in: .vertical) {
            content
                .frame(maxHeight: .infinity, alignment: .top)
            ScrollView {
                content
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background { AmbientBackground() }
        .floatingBottomBar {
            cancelAction
        }
        .navigationTitle(isRootSectionActive ? "Converting" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .task {
            guard startsConversionAutomatically else { return }
            processingBeganAt = Date()
            viewModel.start(input: input, config: config)
        }
        .task(id: scenePhase == .active ? viewModel.result?.id : nil) {
            guard scenePhase == .active, let result = viewModel.result else { return }
            await showResult(result)
        }
        .alert(viewModel.isInterrupted ? "Conversion interrupted" : "Conversion Failed", isPresented: Binding(
            get: { scenePhase == .active && viewModel.errorMessage != nil },
            set: { if !$0 && scenePhase == .active { viewModel.errorMessage = nil } }
        )) {
            Button("Back to Settings") {
                Haptics.impact(.light)
                viewModel.dismissAttempt()
                if !path.isEmpty {
                    path.removeLast()
                }
            }
            Button("Retry") {
                Haptics.impact(.medium)
                viewModel.errorMessage = nil
                processingBeganAt = Date()
                viewModel.retry(input: input, config: config)
            }
        } message: {
            Text(viewModel.errorMessage ?? "Please try again.")
        }
    }

    private var content: some View {
        VStack(spacing: 28) {
            progressHero
            activityCard
            Text(viewModel.backgroundMode.description)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    /// A large ring like an Apple Watch activity ring, with the status beneath.
    private var progressHero: some View {
        VStack(spacing: 22) {
            ZStack {
                ProgressRing(progress: viewModel.progressIsDeterminate ? viewModel.overallProgress : nil)
                    .frame(width: 196, height: 196)

                VStack(spacing: 2) {
                    if viewModel.progressIsDeterminate, let progressText = viewModel.overallProgressText {
                        Text(progressText)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Theme.text)
                            .contentTransition(.numericText())
                    } else if !viewModel.progressIsDeterminate {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 34, weight: .semibold))
                            .foregroundStyle(Theme.tint)
                    }
                    Text(viewModel.elapsedText)
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.textMuted)
                }
                .accessibilityHidden(true)
            }
            .padding(.top, 8)
            .accessibilityElement()
            .accessibilityLabel(viewModel.progressIsDeterminate ? "Conversion progress" : "Conversion in progress. Estimating time remaining.")
            .accessibilityValue(viewModel.progressIsDeterminate ? (viewModel.overallProgressText ?? "0 percent") : "")

            VStack(spacing: 6) {
                Text(viewModel.passLabel)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)

                HStack(spacing: 6) {
                    Text(input.originalFilename)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    Text(config.outputFormat.displayName)
                        .fontWeight(.semibold)
                        .foregroundStyle(Theme.tint)
                        .fixedSize()
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(input.originalFilename) to \(config.outputFormat.displayName)")

                if !viewModel.progressIsDeterminate {
                    Text("Estimating time remaining…")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var activityCard: some View {
        VStack(spacing: 0) {
            activityRow(
                title: "Running on",
                systemImage: "cpu",
                value: viewModel.processingBackend
            )

            Divider()
                .padding(.leading, 62)

            activityRow(
                title: "Elapsed",
                systemImage: "clock",
                value: viewModel.elapsedText
            )

            Divider()
                .padding(.leading, 62)

            activityRow(
                title: "Encoder",
                systemImage: "speedometer",
                value: viewModel.encoderActivityText,
                alignsValueLeading: true
            )

            Divider()
                .padding(.leading, 62)

            activityRow(
                title: "Output",
                systemImage: "doc",
                value: viewModel.encoderOutputText
            )
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
    }

    private func activityRow(
        title: String,
        systemImage: String,
        value: String,
        alignsValueLeading: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            IconTile(systemImage: systemImage)

            ViewThatFits(in: .horizontal) {
                // Centered so a title sits mid-row beside a two-line value.
                HStack(alignment: .center, spacing: 12) {
                    titleText(title)
                    Spacer(minLength: 8)
                    valueText(value, alignsLeading: alignsValueLeading)
                }
                VStack(alignment: .leading, spacing: 3) {
                    titleText(title)
                    valueText(value, alignsLeading: true)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func titleText(_ title: String) -> some View {
        Text(title)
            .font(.body)
            .foregroundStyle(Theme.text)
            .fixedSize()
    }

    private func valueText(_ value: String, alignsLeading: Bool) -> some View {
        Text(value)
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(Theme.textMuted)
            .multilineTextAlignment(alignsLeading ? .leading : .trailing)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cancelAction: some View {
        Button(role: .cancel) {
            Haptics.warning()
            viewModel.dismissAttempt()
            if !path.isEmpty {
                path.removeLast()
            }
        } label: {
            Text("Cancel Conversion")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 30)
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Theme.tint)
        .disabled(!viewModel.isRunning)
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    @MainActor
    private func showResult(_ result: ConversionResult) async {
        let elapsed = Date().timeIntervalSince(processingBeganAt)
        let remaining = minimumVisibleProcessingDuration - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }

        guard !Task.isCancelled, scenePhase == .active,
              viewModel.input == input, viewModel.config == config,
              viewModel.result?.id == result.id,
              let last = path.last, case .processing(let currentInput, let currentConfig) = last,
              currentInput == input, currentConfig == config else { return }
        Haptics.success()

        // Replace Processing in one update. Pushing Result and then removing
        // Processing during that push can leave stale navigation snapshots.
        if reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                path[path.count - 1] = .result(input, config, result, fromHistory: false)
            }
        } else {
            withAnimation {
                path[path.count - 1] = .result(input, config, result, fromHistory: false)
            }
        }
    }

}

#Preview("Processing · Compact · Dark", traits: .fixedLayout(width: 390, height: 844)) {
    let previewViewModel: ProcessingViewModel = {
        let model = ProcessingViewModel()
        model.progress = 0.64
        model.elapsedSeconds = 18
        model.passLabel = "Encoding video…"
        model.showTwoPassProgress = true
        model.progressIsDeterminate = true
        model.isRunning = true
        model.processingBackend = "VideoToolbox · H.264 hardware\nDecode: CPU · Filters: CPU"
        model.liveStats = FFmpegEncodingDisplayStats(
            frame: 197,
            fps: 14.9,
            encodedSize: "7077936B",
            time: "00:00:10.43",
            timeMilliseconds: 10_430,
            throughputBitrate: "5.4Mbits/s",
            speed: "0.24x"
        )
        return model
    }()

    NavigationStack {
        ProcessingView(
            input: MediaFile(
                url: URL(fileURLWithPath: "/tmp/video.mp4"),
                originalFilename: "video.mp4",
                category: .video,
                sizeOnDisk: 50_000_000,
                duration: 30,
                containerFormat: "mp4"
            ),
            config: ConversionConfig(outputFormat: .mp4_h264),
            path: .constant([]),
            previewViewModel: previewViewModel
        )
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.dark)
}
