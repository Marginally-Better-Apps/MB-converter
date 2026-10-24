import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ToolView: View {
    @Binding var path: [AppRoute]
    @State private var viewModel: ToolViewModel
    @State private var isFileImporterPresented = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isEditorPresented = false
    @State private var isDropTargeted = false
    @State private var mediaRouter = HomeViewModel()
    @FocusState private var focusedField: Bool

    init(tool: ToolDefinition, initialInputs: [ToolInputFile] = [], preset: [String: String] = [:], path: Binding<[AppRoute]>) {
        _path = path
        let model = ToolViewModel(tool: tool, inputs: initialInputs)
        for (key, value) in preset { model.values[key] = .string(value) }
        _viewModel = State(initialValue: model)
    }

    private var tool: ToolDefinition { viewModel.tool }

    private var acceptsPhotos: Bool {
        tool.input.formats.contains { $0.family == .image || $0.family == .video }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                header
                if tool.input.acceptsFiles { filesSection }
                if let editor = tool.editor, !viewModel.inputs.isEmpty { editorSection(editor) }
                if viewModel.needsPassword { passwordSection }
                ForEach(Array(viewModel.optionSections.enumerated()), id: \.offset) { _, section in
                    optionSection(section.title, section.options)
                }
                PrivacyNote().padding(.top, Theme.Spacing.s)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: viewModel.visibleOptions.map(\.key))
        }
        .scrollDismissesKeyboard(.interactively)
        .screenBackground()
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .floatingBottomBar { actionBar }
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: tool.input.contentTypes, allowsMultipleSelection: tool.input.allowsMultiple) { result in
            switch result {
            case .success(let urls): viewModel.importURLs(urls)
            case .failure(let error): viewModel.errorMessage = error.localizedDescription
            }
        }
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await viewModel.importPhotos(items)
                photoItems = []
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        .fullScreenCover(isPresented: $isEditorPresented) {
            if let editor = tool.editor, let file = viewModel.inputs.first {
                editorView(editor, file: file)
            }
        }
        #if DEBUG
        .task {
            if DebugLaunchRouter.opensEditor, tool.editor != nil, !viewModel.inputs.isEmpty {
                try? await Task.sleep(for: .milliseconds(600))
                isEditorPresented = true
            }
        }
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = false; hideKeyboard() }
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            ToolGlyph(symbol: tool.symbol, category: tool.category, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(tool.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                if tool.input.acceptsFiles {
                    HStack(spacing: 4) {
                        ForEach(badges, id: \.self) { FormatBadge(text: $0, tint: Theme.tint(for: tool.category)) }
                    }
                }
            }
        }
    }

    private var badges: [String] {
        let formats = tool.input.formats.sorted { $0.rawValue < $1.rawValue }
        if formats.count > 5 {
            let families = Set(formats.map(\.family))
            if families == [.image] { return ["Images"] }
            if families.isSubset(of: [.video, .audio]) { return families.contains(.audio) && families.contains(.video) ? ["Video", "Audio"] : [families.contains(.video) ? "Video" : "Audio"] }
            return Array(formats.prefix(4).map(\.badge)) + ["+\(formats.count - 4)"]
        }
        return formats.map(\.badge)
    }

    private var filesSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack {
                sectionTitle(tool.input.allowsMultiple ? "Files" : "File")
                Spacer()
                if !viewModel.inputs.isEmpty, viewModel.canAddMore || !tool.input.allowsMultiple { addMenu(compact: true) }
            }
            if viewModel.inputs.isEmpty {
                emptyDropZone
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.inputs.enumerated()), id: \.element.id) { index, file in
                        FileRow(file: file, index: tool.input.allowsMultiple ? index + 1 : nil, isLocked: viewModel.lockedPDFs.contains(file.id)) {
                            withAnimation { viewModel.remove(file) }
                        }
                        .draggable(file.id.uuidString)
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first.flatMap(UUID.init(uuidString:)), let dragged = viewModel.inputs.first(where: { $0.id == id }) else { return false }
                            withAnimation { viewModel.move(dragged, before: file) }
                            return true
                        }
                        if index < viewModel.inputs.count - 1 {
                            Divider().overlay(Theme.separator).padding(.leading, 70)
                        }
                    }
                }
                .card(padding: 0)
                if tool.input.allowsMultiple, viewModel.inputs.count > 1 {
                    Text("Drag files to change their order.")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.leading, Theme.Spacing.xs)
                }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            viewModel.importURLs(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var emptyDropZone: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: tool.input.formats.contains(.pdf) ? "doc.badge.plus" : "plus.rectangle.on.folder")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.tint)
            VStack(spacing: 2) {
                Text("Add \(tool.input.noun)")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(tool.input.allowsMultiple ? "Choose up to \(tool.input.maxCount), or drop them here" : "Choose a file, or drop it here")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }
            HStack(spacing: Theme.Spacing.s) {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Files", systemImage: "folder")
                        .frame(maxWidth: 140)
                }
                .buttonStyle(PrimaryButtonStyle())
                if acceptsPhotos {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: tool.input.maxCount, matching: photoFilter) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .frame(maxWidth: 140)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: 320)
            if viewModel.isImporting { ProgressView().padding(.top, 4) }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Spacing.xl)
        .padding(.horizontal, Theme.Spacing.l)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(isDropTargeted ? Theme.tint : Theme.separator, style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4]))
        }
    }

    private var photoFilter: PHPickerFilter {
        let images = tool.input.formats.contains { $0.family == .image }
        let videos = tool.input.formats.contains { $0.family == .video }
        if images && videos { return .any(of: [.images, .videos]) }
        return videos ? .videos : .images
    }

    private func addMenu(compact: Bool) -> some View {
        Menu {
            Button { isFileImporterPresented = true } label: { Label("Choose Files", systemImage: "folder") }
            if acceptsPhotos {
                PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, tool.input.maxCount - viewModel.inputs.count), matching: photoFilter) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
            }
            Button { viewModel.importPasteboard() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            Label(tool.input.allowsMultiple ? "Add" : "Replace", systemImage: "plus")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.tint)
        }
    }

    private func editorSection(_ editor: ToolEditorKind) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle(editorTitle(editor))
            Button {
                Haptics.impact(.light)
                isEditorPresented = true
            } label: {
                HStack(spacing: Theme.Spacing.m) {
                    ToolGlyph(symbol: editorSymbol(editor), size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(editorActionTitle(editor))
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text(viewModel.editorSummary)
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textFaint)
                }
                .card(padding: 14)
            }
            .buttonStyle(PressableStyle())
        }
    }

    private var passwordSection: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle("Password")
            VStack(alignment: .leading, spacing: 6) {
                SecureField("PDF password", text: $viewModel.password)
                    .textInputAutocapitalization(.never)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous))
                Text("This PDF is locked. Enter its password to continue.")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
            .card(padding: Theme.Spacing.l)
        }
    }

    private func optionSection(_ title: String?, _ options: [ToolOption]) -> some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            sectionTitle(title ?? "Options")
            VStack(spacing: 0) {
                ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                    OptionControl(option: option, values: $viewModel.values, inputs: viewModel.inputs)
                    if index < options.count - 1 {
                        Divider().overlay(Theme.separator).padding(.leading, Theme.Spacing.l)
                    }
                }
            }
            .card(padding: 0)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .textCase(.uppercase)
            .tracking(0.4)
            .foregroundStyle(Theme.textMuted)
            .padding(.leading, Theme.Spacing.xs)
    }

    // MARK: Action bar

    private var actionBar: some View {
        Group {
            if viewModel.isRunning {
                HStack(spacing: Theme.Spacing.m) {
                    ProgressRing(progress: viewModel.progress, lineWidth: 4)
                        .frame(width: 26, height: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Working…")
                            .font(.subheadline.weight(.semibold))
                        if let progress = viewModel.progress {
                            Text("\(Int((progress * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(Theme.textMuted)
                        }
                    }
                    Spacer()
                    Button("Cancel", role: .cancel) { viewModel.cancel() }
                        .glassButtonStyle()
                        .buttonBorderShape(.capsule)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .glassSurface(in: Capsule())
            } else {
                Button(action: perform) {
                    PrimaryActionLabel(title: viewModel.blockingReason ?? tool.actionTitle, systemImage: viewModel.blockingReason == nil ? actionSymbol : "plus")
                }
                .accessibilityIdentifier("tool.run")
                .glassButtonStyle(prominent: true)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Theme.tint)
                .disabled(viewModel.blockingReason != nil)
            }
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var actionSymbol: String {
        tool.opensMediaConverter ? "arrow.right" : (tool.input.acceptsFiles ? "checkmark" : "sparkles")
    }

    private func perform() {
        hideKeyboard()
        Haptics.impact(.medium)
        if tool.opensMediaConverter {
            Task { await openMediaConverter() }
            return
        }
        Task {
            if let run = await viewModel.run() {
                path.append(.toolResult(run))
            }
        }
    }

    private func openMediaConverter() async {
        guard let file = viewModel.inputs.first else { return }
        viewModel.isRunning = true
        defer { viewModel.isRunning = false }
        if let media = await mediaRouter.importFromFiles(file.url) {
            path.append(.inputDetail(media))
        } else {
            viewModel.errorMessage = mediaRouter.errorMessage
        }
    }

    // MARK: Editors

    @ViewBuilder
    private func editorView(_ editor: ToolEditorKind, file: ToolInputFile) -> some View {
        @Bindable var viewModel = viewModel
        switch editor {
        case .pageOrganizer:
            PageOrganizerView(url: file.url, password: viewModel.password.nilIfBlank, initialEdits: viewModel.editorState.pageEdits) { edits in
                viewModel.editorState = .pages(edits)
            }
        case .pdfMarkup(let signatureFirst):
            PDFMarkupEditorView(url: file.url, password: viewModel.password.nilIfBlank, initialItems: viewModel.editorState.overlays, startsWithSignature: signatureFirst) { items in
                viewModel.editorState = .overlays(items)
            }
        case .imageCrop:
            ImageCropEditorView(url: file.url, initialRect: viewModel.editorState.cropRect) { rect in
                viewModel.editorState = .crop(rect)
            }
        case .mediaRange:
            MediaRangeEditorView(url: file.url, initialRange: viewModel.editorState.range) { start, end in
                viewModel.editorState = .range(start: start, end: end)
            }
        }
    }

    private func editorTitle(_ editor: ToolEditorKind) -> String {
        switch editor {
        case .pageOrganizer: "Pages"
        case .pdfMarkup: "Edit"
        case .imageCrop: "Crop"
        case .mediaRange: "Range"
        }
    }

    private func editorActionTitle(_ editor: ToolEditorKind) -> String {
        switch editor {
        case .pageOrganizer: "Arrange pages"
        case .pdfMarkup(let signature): signature ? "Place signature" : "Open editor"
        case .imageCrop: "Choose crop"
        case .mediaRange: "Choose start and end"
        }
    }

    private func editorSymbol(_ editor: ToolEditorKind) -> String {
        switch editor {
        case .pageOrganizer: "square.grid.2x2"
        case .pdfMarkup(let signature): signature ? "signature" : "pencil.tip.crop.circle"
        case .imageCrop: "crop"
        case .mediaRange: "timeline.selection"
        }
    }
}

struct FileRow: View {
    let file: ToolInputFile
    var index: Int?
    var isLocked = false
    var onRemove: (() -> Void)?

    @State private var detail: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            FileThumbnail(url: file.url, size: CGSize(width: 42, height: 42), format: file.format)
                .overlay(alignment: .topLeading) {
                    if let index {
                        Text("\(index)")
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.onPrimary)
                            .frame(minWidth: 16, minHeight: 16)
                            .background(Theme.primary, in: Circle())
                            .offset(x: -5, y: -5)
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(file.displayName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    FormatBadge(text: file.format.badge)
                    Text(detail ?? file.byteCount.formattedBytes)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                    if isLocked {
                        Image(systemName: "lock.fill").font(.caption2).foregroundStyle(Theme.warning)
                    }
                }
            }
            Spacer(minLength: 0)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Theme.textFaint)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(file.displayName)")
            }
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: file.id) { detail = await Self.details(for: file) }
    }

    static func details(for file: ToolInputFile) async -> String {
        var parts = [file.byteCount.formattedBytes]
        switch file.format {
        case .pdf:
            if let document = PDFDocument(url: file.url) {
                parts.append(document.isLocked ? "locked" : "\(document.pageCount) page\(document.pageCount == 1 ? "" : "s")")
            }
        case .pptx:
            let count = PPTXReader.slideCount(url: file.url)
            if count > 0 { parts.append("\(count) slide\(count == 1 ? "" : "s")") }
        default:
            if file.format.family == .image, let source = CGImageSourceCreateWithURL(file.url as CFURL, nil),
               let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
               let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int {
                parts.append("\(width) × \(height)")
            } else if file.format.family == .video || file.format.family == .audio,
                      let probe = try? await MediaToolkit.probe(file.url), probe.duration > 0 {
                parts.append(MetadataFormatter.durationText(probe.duration))
            }
        }
        return parts.joined(separator: " · ")
    }
}

func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}
