import SwiftUI

struct ProcessingView: View {
    let input: MediaFile
    let config: ConversionConfig
    @Binding var path: [AppRoute]

    @State private var viewModel = ProcessingViewModel()
    @State private var barsAreTall = false
    @State private var processingBeganAt = Date()

    private let minimumVisibleProcessingDuration: TimeInterval = 0.45

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            VStack(spacing: 28) {
                animatedBars

                VStack(spacing: 8) {
                    Text(viewModel.passLabel)
                        .font(.title2.bold())
                        .foregroundStyle(Theme.text)

                    if config.outputFormat != .webpImage,
                       let progressText = viewModel.displayProgressText {
                        Text(progressText)
                            .font(.system(size: 56, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.primary)
                    } else if config.outputFormat != .webpImage, viewModel.isRunning {
                        Text("Reading stream timing")
                            .font(.headline)
                            .foregroundStyle(Theme.primary)
                    }

                    Text("Elapsed \(MetadataFormatter.durationText(viewModel.elapsedSeconds))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }

                if viewModel.liveStatsPrimaryLine != nil || viewModel.liveStatsDetailLine != nil {
                    VStack(spacing: 4) {
                        if let primary = viewModel.liveStatsPrimaryLine {
                            Text(primary)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .monospacedDigit()
                        }
                        if let detail = viewModel.liveStatsDetailLine {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                                .multilineTextAlignment(.center)
                                .lineLimit(3)
                                .minimumScaleFactor(0.75)
                                .monospacedDigit()
                        }
                    }
                    .frame(maxWidth: 360)
                    .accessibilityElement(children: .combine)
                }

                Button(role: .cancel) {
                    Haptics.warning()
                    viewModel.cancel()
                    if !path.isEmpty {
                        path.removeLast()
                    }
                } label: {
                    Text("Cancel")
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .frame(maxWidth: 240, minHeight: 48)
                        .background(Theme.surface)
                        .clipShape(Capsule())
                        .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
                }
                .disabled(!viewModel.isRunning)
            }
            .padding(24)
        }
        .navigationBarBackButtonHidden()
        .task {
            processingBeganAt = Date()
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true)) {
                barsAreTall.toggle()
            }
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
        withAnimation {
            path.append(.result(input, config, result, fromHistory: false))
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

    private var animatedBars: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(0..<9, id: \.self) { index in
                Capsule()
                    .fill(Theme.primary)
                    .frame(width: 10, height: barsAreTall ? CGFloat(32 + index % 3 * 18) : CGFloat(68 - index % 3 * 14))
                    .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(Double(index) * 0.04), value: barsAreTall)
            }
        }
        .frame(height: 96)
        .accessibilityHidden(true)
    }

}

#Preview {
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
            path: .constant([])
        )
    }
}
