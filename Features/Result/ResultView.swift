import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ResultView: View {
    @Binding var path: [AppRoute]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var viewModel: ResultViewModel
    @State private var isRenamePromptPresented = false
    @State private var renameDraft = ""
    @State private var shareItem: ShareSheetItem?
    @State private var isFinishing = false
    @State private var hasAppeared = false
    @State private var previewWidth: CGFloat = 0
    private let fromHistory: Bool
    private let onConvertAnother: (() -> Void)?

    init(
        input: MediaFile,
        config: ConversionConfig,
        result: ConversionResult,
        fromHistory: Bool,
        path: Binding<[AppRoute]>,
        onConvertAnother: (() -> Void)? = nil
    ) {
        self._path = path
        self.fromHistory = fromHistory
        self.onConvertAnother = onConvertAnother
        self._viewModel = State(initialValue: ResultViewModel(input: input, config: config, result: result))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                successHeader

                if usesWideOutputLayout {
                    HStack(alignment: .top, spacing: 24) {
                        previewCard
                            .frame(minWidth: 300, maxWidth: 440)
                        VStack(spacing: 24) {
                            sizeCard
                            fileCard
                        }
                    }
                } else {
                    previewCard
                    sizeCard
                    fileCard
                }
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background { AmbientBackground() }
        .overlay {
            if viewModel.isCopyingToPasteboard {
                ZStack {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()

                    VStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.large)
                            .tint(Theme.tint)
                        Text("Copying…")
                            .font(.headline)
                            .foregroundStyle(Theme.text)
                    }
                    .frame(width: 150, height: 130)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Copying converted file")
                }
                .transition(.opacity)
            }
        }
        .floatingBottomBar {
            actionBar
        }
        .onDisappear {
            guard isFinishing else { return }
            // Keep the preview's files available while Done animates this
            // screen away. Ordinary back navigation keeps the cached result.
            TempStorage.cleanAll()
            ImportStorage.cleanAll()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(action: goBack) {
                    Image(systemName: "chevron.left")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Theme.tint)
                }
                .disabled(isFinishing || viewModel.isCopyingToPasteboard)
                .accessibilityLabel(fromHistory ? "Back to History" : "Back to conversion settings")
            }

            ToolbarItem(placement: .confirmationAction) {
                Button(action: finish) {
                    Text("Done")
                        .fontWeight(.semibold)
                }
                .disabled(isFinishing || viewModel.isCopyingToPasteboard)
                .accessibilityLabel("Done")
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 20)
                .onEnded { gesture in
                    guard gesture.startLocation.x <= 24,
                          gesture.translation.width >= 80,
                          gesture.translation.width > abs(gesture.translation.height) * 1.5 else { return }
                    // The settings screen owns its back navigation too. Avoid
                    // starting a UIKit interactive pop that it would interrupt.
                    goBack()
                }
        )
#if canImport(UIKit)
        .background(ConvertBackNavigationGuard(isActive: true).frame(width: 0, height: 0))
#endif
        .alert("Action Failed", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
                viewModel.errorMessage = nil
            }
        } message: {
            Text(viewModel.errorMessage ?? "Please try again.")
        }
        .alert("Copied to Clipboard", isPresented: $viewModel.didCopyToPasteboard) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
            }
        } message: {
            Text("File copied to clipboard.")
        }
        .alert("Rename File", isPresented: $isRenamePromptPresented) {
            TextField("Filename", text: $renameDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {
                Haptics.impact(.light)
            }
            Button("Apply") {
                Haptics.impact(.light)
                viewModel.applyFilenameEdit(renameDraft)
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
    }

    private var successHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56, weight: .semibold))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, fromHistory ? Theme.tint : Theme.success)
                .symbolEffect(.bounce, value: hasAppeared)
                .accessibilityHidden(true)

            Text(fromHistory ? "Saved Conversion" : "Conversion Complete")
                .font(.title2.bold())
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .onAppear { hasAppeared = true }
        .accessibilityElement(children: .combine)
    }

    private var previewCard: some View {
        MediaPreview(
            url: viewModel.result.url,
            category: viewModel.result.outputFormat.category,
            compact: true,
            showsChrome: false,
            preferredHeight: previewHeight
        )
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.media, style: .continuous))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { previewWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { _, width in previewWidth = width }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .accessibilityLabel("Preview converted file")
    }

    /// Before and after, with the change as a colored badge.
    private var sizeCard: some View {
        let comparison = viewModel.sizeComparison

        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                CardHeader(title: "File Size")
                Spacer(minLength: 8)
                changeBadge(comparison)
            }

            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        sizeColumn("Before", value: comparison.before)
                        sizeColumn("After", value: comparison.after)
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        sizeColumn("Before", value: comparison.before)
                        Image(systemName: "arrow.right")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Theme.textTertiary)
                            .accessibilityHidden(true)
                        sizeColumn("After", value: comparison.after, alignment: .trailing)
                    }
                }
            }
        }
        .surfaceCard(padding: 18)
        .accessibilityElement(children: .combine)
    }

    private func changeBadge(_ comparison: ResultSizeComparison) -> some View {
        let color = changeColor(comparison.direction)
        return HStack(spacing: 4) {
            switch comparison.direction {
            case .smaller:
                Image(systemName: "arrow.down")
            case .larger:
                Image(systemName: "arrow.up")
            case .unchanged, .unavailable:
                EmptyView()
            }
            Text(comparison.change)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(color.opacity(0.14), in: Capsule())
    }

    private func sizeColumn(_ title: String, value: String, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.title2.weight(.bold))
                .monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: Alignment(horizontal: alignment, vertical: .center))
    }

    private func changeColor(_ direction: ResultSizeComparison.Direction) -> Color {
        switch direction {
        case .smaller: Theme.success
        case .larger: .orange
        case .unchanged, .unavailable: Theme.textMuted
        }
    }

    private var fileCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    CardHeader(title: "Output")
                    Text(viewModel.exportFilename)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 8)

                Button {
                    Haptics.impact(.light)
                    renameDraft = viewModel.editableBaseName
                    isRenamePromptPresented = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .foregroundStyle(Theme.tint)
                        .background(Theme.secondaryFill, in: Capsule())
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .fixedSize()
                .accessibilityLabel("Rename output file")
            }
            .padding(.bottom, 10)

            outputDetails
        }
        .surfaceCard(padding: 18)
    }

    private var outputDetails: some View {
        let rows = MetadataFormatter.summaryRows(for: viewModel.result)

        return VStack(spacing: 0) {
            ForEach(rows) { row in
                Divider()
                LabeledContent(row.label) {
                    Text(row.value)
                        .font(.body.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.trailing)
                }
                .font(.body)
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 11)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var actionBar: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    shareResult()
                } label: {
                    PrimaryActionLabel(title: "Share", systemImage: "square.and.arrow.up")
                }
                .glassButtonStyle(prominent: true)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Theme.tint)
                .accessibilityLabel("Share converted file")

                if viewModel.canCopyToPasteboard {
                    copyAction
                }
            }
        }
        .disabled(isFinishing || viewModel.isCopyingToPasteboard)
        .frame(maxWidth: 560)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var copyAction: some View {
        Button {
            Haptics.impact(.light)
            Task {
                await viewModel.copyToPasteboard()
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .font(.headline)
                .labelStyle(copyLabelStyle)
                .frame(minWidth: 30, minHeight: 30)
        }
        .glassButtonStyle()
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Theme.tint)
        .accessibilityLabel("Copy file to clipboard")
        .disabled(viewModel.isCopyingToPasteboard)
    }

    private var copyLabelStyle: AnyLabelStyle {
        dynamicTypeSize.isAccessibilitySize ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon)
    }

    /// Fits the output's shape so wide media doesn't sit in a tall letterbox.
    private var previewHeight: CGFloat {
        let maximum: CGFloat = usesWideOutputLayout ? 380 : 320
        guard viewModel.result.outputFormat.category != .audio else { return 200 }
        guard let dimensions = viewModel.result.dimensions,
              dimensions.width > 0, dimensions.height > 0, previewWidth > 0 else { return 260 }
        let fitted = (previewWidth - 4) * dimensions.height / dimensions.width + 4
        return min(maximum, max(180, fitted.rounded()))
    }

    private var usesWideOutputLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
    }

    private func goBack() {
        guard !isFinishing, !viewModel.isCopyingToPasteboard,
              let last = path.last,
              case .result(_, _, let result, _) = last,
              result.id == viewModel.result.id else { return }
        Haptics.impact(.light)
        withAnimation {
            _ = path.removeLast()
        }
    }

    private func finish() {
        guard !isFinishing else { return }
        isFinishing = true
        Haptics.impact(.medium)
        withAnimation {
            if let onConvertAnother {
                onConvertAnother()
            } else {
                path.removeAll()
            }
        }
    }

    private func shareResult() {
        Haptics.impact(.light)
        do {
            let url = try viewModel.prepareShareFileURL()
            shareItem = ShareSheetItem(url: url)
        } catch {
            viewModel.errorMessage = "Couldn't prepare the file for sharing."
            DiagnosticsLog.shared.record(
                error: error,
                context: "Stage converted file for sharing",
                metadata: [
                    "Export filename": viewModel.exportFilename,
                    "Output format": viewModel.result.outputFormat.displayName,
                    "Output bytes": String(viewModel.result.sizeOnDisk)
                ]
            )
            Haptics.error()
        }
    }

}

/// Type-erases the copy button's label style so it can adapt to Dynamic Type.
private struct AnyLabelStyle: LabelStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: LabelStyle>(_ style: S) {
        makeBodyClosure = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}

private struct ShareSheetItem: Identifiable {
    let id = UUID()
    let url: URL
}

#if canImport(UIKit)
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#Preview("Result · Compact · Light", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        ResultView(
            input: MediaFile(
                url: URL(fileURLWithPath: "/tmp/input.mp4"),
                originalFilename: "input.mp4",
                category: .video,
                sizeOnDisk: 5_400_000,
                containerFormat: "mp4"
            ),
            config: ConversionConfig(outputFormat: .mp4_h264),
            result: ConversionResult(
                url: URL(fileURLWithPath: "/tmp/output.mp4"),
                outputFormat: .mp4_h264,
                sizeOnDisk: 1_800_000
            ),
            fromHistory: false,
            path: .constant([])
        )
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.light)
}

#Preview("Result · Regular · Dark", traits: .fixedLayout(width: 1_024, height: 768)) {
    NavigationStack {
        ResultView(
            input: MediaFile(
                url: URL(fileURLWithPath: "/tmp/input.mp4"),
                originalFilename: "input.mp4",
                category: .video,
                sizeOnDisk: 5_400_000,
                dimensions: CGSize(width: 1_920, height: 1_080),
                duration: 42,
                fps: 30,
                bitrate: 8_000_000,
                audioBitrate: 192_000,
                videoCodec: "h264",
                audioCodec: "aac",
                containerFormat: "mp4"
            ),
            config: ConversionConfig(outputFormat: .mp4_h264),
            result: ConversionResult(
                url: URL(fileURLWithPath: "/tmp/output.mp4"),
                outputFormat: .mp4_h264,
                sizeOnDisk: 1_800_000,
                dimensions: CGSize(width: 1_280, height: 720),
                duration: 42,
                fps: 30,
                bitrate: 2_500_000,
                audioBitrate: 128_000,
                videoCodec: "h264",
                audioCodec: "aac"
            ),
            fromHistory: false,
            path: .constant([])
        )
    }
    .environment(\.horizontalSizeClass, .regular)
    .preferredColorScheme(.dark)
}

#Preview("Result · Long Filename", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        ResultView(
            input: MediaFile(
                url: URL(fileURLWithPath: "/tmp/input.mp4"),
                originalFilename: "Family Vacation — Lake Michigan Sunset — Final Edited Version With Captions.mp4",
                category: .video,
                sizeOnDisk: 92_400_000,
                dimensions: CGSize(width: 3_840, height: 2_160),
                duration: 184,
                fps: 60,
                bitrate: 18_000_000,
                audioBitrate: 256_000,
                videoCodec: "hevc",
                audioCodec: "aac",
                containerFormat: "mp4"
            ),
            config: ConversionConfig(outputFormat: .mp4_h264),
            result: ConversionResult(
                url: URL(fileURLWithPath: "/tmp/long-output.mp4"),
                outputFormat: .mp4_h264,
                sizeOnDisk: 24_800_000,
                dimensions: CGSize(width: 1_920, height: 1_080),
                duration: 184,
                fps: 30,
                bitrate: 5_000_000,
                audioBitrate: 128_000,
                videoCodec: "h264",
                audioCodec: "aac"
            ),
            fromHistory: false,
            path: .constant([])
        )
    }
    .environment(\.horizontalSizeClass, .compact)
    .environment(\.dynamicTypeSize, .accessibility2)
    .preferredColorScheme(.light)
}
