import SwiftUI

struct ProcessingView: View {
    let input: MediaFile
    let config: ConversionConfig
    @Binding var path: [AppRoute]
    private let startsConversionAutomatically: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel = ProcessingViewModel()
    @State private var processingBeganAt = Date()

    private let minimumVisibleProcessingDuration: TimeInterval = 0.45

    init(
        input: MediaFile,
        config: ConversionConfig,
        path: Binding<[AppRoute]>,
        previewViewModel: ProcessingViewModel? = nil
    ) {
        self.input = input
        self.config = config
        self._path = path
        self._viewModel = State(initialValue: previewViewModel ?? ProcessingViewModel())
        self.startsConversionAutomatically = previewViewModel == nil
    }

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground).ignoresSafeArea()

            ScrollView {
                VStack(spacing: 30) {
                    statusHeader
                    progressCard
                    activityCard
                }
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 36)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom) {
            cancelAction
        }
        .navigationTitle(isRootSectionActive ? "Converting" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .task {
            guard startsConversionAutomatically else { return }
            processingBeganAt = Date()
            viewModel.start(input: input, config: config) { result in
                Task {
                    await showResult(result)
                }
            }
        }
        .alert("Conversion Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("Back to Settings") {
                Haptics.impact(.light)
                viewModel.errorMessage = nil
                if !path.isEmpty {
                    path.removeLast()
                }
            }
            Button("Retry") {
                Haptics.impact(.medium)
                viewModel.errorMessage = nil
                viewModel.retry(input: input, config: config) { result in
                    Task {
                        await showResult(result)
                    }
                }
            }
        } message: {
            Text(viewModel.errorMessage ?? "Please try again.")
        }
    }

    private var statusHeader: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 30, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .rotationEffect(.degrees(viewModel.isRunning && !reduceMotion ? 360 : 0))
                .animation(
                    viewModel.isRunning && !reduceMotion
                        ? .linear(duration: 1.8).repeatForever(autoreverses: false)
                        : .default,
                    value: viewModel.isRunning
                )
                .accessibilityHidden(true)

            VStack(spacing: 5) {
                Text(viewModel.passLabel)
                    .font(.title2.bold())
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)

                Text("\(input.originalFilename) · \(config.outputFormat.displayName)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overall Progress")
                    .font(.headline)
                    .foregroundStyle(Theme.text)

                Spacer()

                if let progressText = viewModel.overallProgressText {
                    Text(progressText)
                        .font(.headline.monospacedDigit())
                        .foregroundStyle(Theme.tint)
                }
            }

            if viewModel.progressIsDeterminate {
                ProgressView(value: viewModel.overallProgress, total: 1)
                    .progressViewStyle(.linear)
                    .tint(Theme.tint)
                    .accessibilityLabel("Conversion progress")
                    .accessibilityValue(viewModel.overallProgressText ?? "0 percent")
            } else {
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(Theme.tint)

                    Text("Estimating time remaining…")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Conversion in progress. Estimating time remaining.")
            }
        }
        .padding(.horizontal, 6)
    }

    private var activityCard: some View {
        VStack(spacing: 0) {
            activityRow(
                title: "Elapsed",
                systemImage: "clock",
                value: viewModel.elapsedText
            )

            Divider()
                .overlay(Theme.separator)
                .padding(.leading, 32)

            activityRow(
                title: "Encoder",
                systemImage: "speedometer",
                value: viewModel.encoderActivityText,
                alignsValueLeading: true
            )

            Divider()
                .overlay(Theme.separator)
                .padding(.leading, 32)

            activityRow(
                title: "Output",
                systemImage: "doc",
                value: viewModel.encoderOutputText
            )
        }
        .padding(.horizontal, 16)
        .appleGlass(cornerRadius: 22)
    }

    private func activityRow(
        title: String,
        systemImage: String,
        value: String,
        alignsValueLeading: Bool = false
    ) -> some View {
        LabeledContent {
            Text(value)
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(alignsValueLeading ? .leading : .trailing)
                .fixedSize(horizontal: alignsValueLeading, vertical: false)
                .frame(
                    maxWidth: alignsValueLeading ? .infinity : nil,
                    alignment: .trailing
                )
        } label: {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text)
        }
        .padding(.vertical, 14)
        .accessibilityElement(children: .combine)
    }

    private var cancelAction: some View {
        Button("Cancel Conversion", role: .cancel) {
            Haptics.warning()
            viewModel.cancel()
            if !path.isEmpty {
                path.removeLast()
            }
        }
        .appleGlassButton()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .disabled(!viewModel.isRunning)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @MainActor
    private func showResult(_ result: ConversionResult) async {
        let elapsed = Date().timeIntervalSince(processingBeganAt)
        let remaining = minimumVisibleProcessingDuration - elapsed
        if remaining > 0 {
            try? await Task.sleep(for: .seconds(remaining))
        }

        guard let last = path.last, case .processing = last else { return }
        Haptics.success()

        // A push (append) is what gets the system navigation transition. Replacing the last
        // route in place usually does not. Push Result on top, then drop Processing underneath
        // in a follow-up update so the stack is […, inputDetail, result] (not […, result] in place).
        if reduceMotion {
            path.append(.result(input, config, result, fromHistory: false))
        } else {
            withAnimation {
                path.append(.result(input, config, result, fromHistory: false))
            }
        }
        ConversionHistoryStore.shared.record(input: input, config: config, result: result)

        await Task.yield()

        guard path.count >= 2 else { return }
        guard case .processing = path[path.count - 2] else { return }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        _ = withTransaction(transaction) {
            path.remove(at: path.count - 2)
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
