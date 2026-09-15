import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ResultView: View {
    @Binding var path: [AppRoute]
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var viewModel: ResultViewModel
    @State private var isRenamePromptPresented = false
    @State private var renameDraft = ""
    @State private var shareItem: ShareSheetItem?
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
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 18) {
                    successHeader
                    outputCard
                    comparisonCard
                }
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.vertical, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            if viewModel.isCopyingToPasteboard {
                ZStack {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()

                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(Theme.tint)
                        Text("Copying...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(Theme.groupedSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Copying converted file")
                }
                .transition(.opacity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            actionBar
        }
        .navigationTitle(isRootSectionActive ? "Result" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden()
        .toolbar {
            if isRootSectionActive {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        Haptics.impact(.light)
                        goBackToSettings()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.headline.weight(.semibold))
                    }
                    .accessibilityLabel(fromHistory ? "Back to history" : "Back to settings")
                }
            }
        }
#if canImport(UIKit)
        .background(ResultInteractivePopGestureEnabler().frame(width: 0, height: 0))
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
        .alert("Copied to clipboard", isPresented: $viewModel.didCopyToPasteboard) {
            Button("OK", role: .cancel) {
                Haptics.impact(.light)
            }
        } message: {
            Text("File copied to clipboard.")
        }
        .alert("Rename file", isPresented: $isRenamePromptPresented) {
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
                .font(.system(size: 54, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)

            Text(fromHistory ? "Saved Conversion" : "Conversion Complete")
                .font(.title2.bold())
                .foregroundStyle(Theme.text)

            Text(fromHistory ? "This converted file is ready to share again." : "Your converted file is ready to share.")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
        }
        .accessibilityElement(children: .combine)
    }

    private var outputCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Label("Output", systemImage: "doc.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.text)

                Spacer()

                Button {
                    Haptics.impact(.light)
                    renameDraft = viewModel.editableBaseName
                    isRenamePromptPresented = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 10))
                .controlSize(.small)
                .tint(Theme.tint)
                .accessibilityLabel("Rename output file")
            }

            Text(viewModel.exportFilename)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(2)
                .truncationMode(.middle)

            Divider()
                .overlay(Theme.separator)

            responsiveOutputContent
        }
        .padding(20)
        .background(Theme.groupedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var responsiveOutputContent: some View {
        let layout = usesWideOutputLayout
            ? AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            : AnyLayout(VStackLayout(alignment: .leading, spacing: 18))

        return layout {
            MediaPreview(
                url: viewModel.result.url,
                category: viewModel.result.outputFormat.category,
                compact: true,
                showsChrome: false
            )
            .frame(
                minWidth: usesWideOutputLayout ? 280 : 0,
                maxWidth: usesWideOutputLayout ? 360 : .infinity
            )
            .accessibilityLabel("Preview converted file")

            outputDetails
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var outputDetails: some View {
        let rows = MetadataFormatter.summaryRows(for: viewModel.result)

        return VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                LabeledContent(row.label) {
                    Text(row.value)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.text)
                        .multilineTextAlignment(.trailing)
                }
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .padding(.vertical, 10)
                .accessibilityElement(children: .combine)

                if index < rows.count - 1 {
                    Divider()
                        .overlay(Theme.separator)
                }
            }
        }
    }

    private var comparisonCard: some View {
        let comparison = viewModel.sizeComparison

        return VStack(alignment: .leading, spacing: 16) {
            Label("File Size", systemImage: "chart.bar.fill")
                .font(.headline)
                .foregroundStyle(Theme.text)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    comparisonMetric(title: "Before", value: comparison.before)
                    comparisonDivider
                    comparisonMetric(title: "After", value: comparison.after)
                    comparisonDivider
                    comparisonMetric(title: "Change", value: comparison.change, emphasized: true)
                }

                VStack(spacing: 0) {
                    comparisonRow(title: "Before", value: comparison.before)
                    Divider().overlay(Theme.separator)
                    comparisonRow(title: "After", value: comparison.after)
                    Divider().overlay(Theme.separator)
                    comparisonRow(title: "Change", value: comparison.change, emphasized: true)
                }
            }
        }
        .padding(20)
        .background(Theme.groupedSurface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private func comparisonMetric(title: String, value: String, emphasized: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.subheadline.weight(emphasized ? .semibold : .medium))
                .foregroundStyle(emphasized ? Theme.tint : Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(minWidth: 92, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var comparisonDivider: some View {
        Divider()
            .overlay(Theme.separator)
            .frame(minHeight: 44)
    }

    private func comparisonRow(title: String, value: String, emphasized: Bool = false) -> some View {
        LabeledContent(title) {
            Text(value)
                .font(.subheadline.weight(emphasized ? .semibold : .medium))
                .foregroundStyle(emphasized ? Theme.tint : Theme.text)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.textMuted)
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var actionBar: some View {
        VStack(spacing: 10) {
            Button {
                shareResult()
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.headline)
                    .foregroundStyle(Theme.background)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .tint(Theme.tint)
            .accessibilityLabel("Share converted file")

            secondaryActions
        }
        .disabled(viewModel.isCopyingToPasteboard)
        .frame(maxWidth: 900)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .top) {
            Divider()
                .overlay(Theme.separator)
        }
    }

    @ViewBuilder
    private var secondaryActions: some View {
        if viewModel.canCopyToPasteboard {
            LazyVGrid(columns: secondaryActionColumns, spacing: 10) {
                copyAction
                doneAction
            }
        } else {
            doneAction
        }
    }

    private var secondaryActionColumns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: 10),
            GridItem(.flexible(), spacing: 10)
        ]
    }

    private var copyAction: some View {
        Button {
            Haptics.impact(.light)
            Task {
                await viewModel.copyToPasteboard()
            }
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .tint(Theme.tint)
        .accessibilityLabel("Copy file to clipboard")
        .disabled(viewModel.isCopyingToPasteboard)
    }

    private var doneAction: some View {
        Button {
            Haptics.impact(.medium)
            TempStorage.cleanAll()
            ImportStorage.cleanAll()
            if let onConvertAnother {
                onConvertAnother()
            } else {
                path.removeAll()
            }
        } label: {
            Label("Done", systemImage: "checkmark")
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .tint(Theme.tint)
        .accessibilityLabel("Done")
    }

    private var usesWideOutputLayout: Bool {
        horizontalSizeClass == .regular && !dynamicTypeSize.isAccessibilitySize
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

    private func goBackToSettings() {
        // Normal results stay alive as the InputDetail screen's one-entry cache.
        // That screen removes the file when settings change or the flow is discarded;
        // History-owned results continue to be managed by ConversionHistoryStore.
        if !path.isEmpty {
            path.removeLast()
        }
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

#if canImport(UIKit)
private struct ResultInteractivePopGestureEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> ResultInteractivePopGestureViewController {
        ResultInteractivePopGestureViewController()
    }

    func updateUIViewController(_ uiViewController: ResultInteractivePopGestureViewController, context: Context) {}
}

private final class ResultInteractivePopGestureViewController: UIViewController {
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.interactivePopGestureRecognizer?.isEnabled = true
        navigationController?.interactivePopGestureRecognizer?.delegate = nil
    }
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
