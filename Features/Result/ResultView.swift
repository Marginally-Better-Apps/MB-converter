import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ResultView: View {
    @Binding var path: [AppRoute]
    @State private var viewModel: ResultViewModel
    @State private var isRenamePromptPresented = false
    @State private var renameDraft = ""
    @State private var shareItem: ShareSheetItem?
    private let fromHistory: Bool

    init(
        input: MediaFile,
        config: ConversionConfig,
        result: ConversionResult,
        fromHistory: Bool,
        path: Binding<[AppRoute]>
    ) {
        self._path = path
        self.fromHistory = fromHistory
        self._viewModel = State(initialValue: ResultViewModel(input: input, config: config, result: result))
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 14) {
                        Button {
                            Haptics.impact(.light)
                            renameDraft = viewModel.editableBaseName
                            isRenamePromptPresented = true
                        } label: {
                            HStack(spacing: 8) {
                                Text(viewModel.exportFilename)
                                    .font(.headline.weight(.semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Image(systemName: "pencil")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .foregroundStyle(Theme.text)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Rename output file")

                        HStack(alignment: .center, spacing: 20) {
                        MediaPreview(
                            url: viewModel.result.url,
                            category: viewModel.result.outputFormat.category,
                            compact: true,
                            showsChrome: false
                        )
                        .frame(minWidth: 200, idealWidth: 260, maxWidth: 320)

                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(MetadataFormatter.summaryRows(for: viewModel.result)) { row in
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Theme.accent, lineWidth: 1)
                    )

                    Text(viewModel.comparisonText)
                        .font(.headline)
                        .foregroundStyle(Theme.primary)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                    actionRow
                }
                .frame(maxWidth: 1100)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .scrollBounceBehavior(.basedOnSize)

            if viewModel.isCopyingToPasteboard {
                ZStack {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()

                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(Theme.primary)
                        Text("Copying...")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                    }
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .transition(.opacity)
            }
        }
        .navigationTitle("Result")
        .navigationBarBackButtonHidden()
        .toolbar {
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

    private var actionRow: some View {
        VStack(spacing: 12) {
            Button {
                Haptics.impact(.light)
                do {
                    let url = try viewModel.prepareShareFileURL()
                    shareItem = ShareSheetItem(url: url)
                } catch {
                    viewModel.errorMessage = "Couldn't prepare the file for sharing."
                    Haptics.error()
                }
            } label: {
                actionLabel("Share", systemImage: "square.and.arrow.up", filled: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Share converted file")

            if viewModel.canCopyToPasteboard {
                Button {
                    Haptics.impact(.light)
                    Task {
                        await viewModel.copyToPasteboard()
                    }
                } label: {
                    actionLabel("Copy", systemImage: "doc.on.doc", filled: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy file to clipboard")
                .disabled(viewModel.isCopyingToPasteboard)
            }

            Button {
                Haptics.impact(.medium)
                TempStorage.cleanAll()
                ImportStorage.cleanAll()
                path.removeAll()
            } label: {
                actionLabel("Convert Another", systemImage: "arrow.counterclockwise", filled: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Convert another file")
        }
    }

    private func actionLabel(_ title: String, systemImage: String, filled: Bool) -> some View {
        HStack {
            Image(systemName: systemImage)
            Text(title)
                .fontWeight(.semibold)
        }
        .foregroundStyle(filled ? Theme.background : Theme.primary)
        .frame(maxWidth: .infinity, minHeight: 52)
        .background(filled ? Theme.primary : Theme.surface)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Theme.accent, lineWidth: filled ? 0 : 1))
    }

    private func goBackToSettings() {
        if !fromHistory {
            try? FileManager.default.removeItem(at: viewModel.result.url)
        }
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

#Preview {
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
}
