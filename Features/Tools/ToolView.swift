import PDFKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ToolView: View {
    @Binding var path: [AppRoute]
    @State private var viewModel: ToolViewModel
    @State private var isFileImporterPresented = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isPhotoPickerPresented = false
    @State private var showsMoreOptions = false
    @State private var isKeyboardVisible = false
    @State private var isDropTargeted = false
    @State private var mediaRouter = HomeViewModel()
    @State private var preview = ToolPreviewModel()
    @State private var isPreviewExpanded = true
    @FocusState private var focusedField: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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

    /// Everything that changes what the tool would produce.
    private struct PreviewKey: Hashable {
        let inputs: [UUID]
        let values: ToolOptionValues
        let editor: ToolEditorState
        let password: String
    }

    private var previewKey: PreviewKey {
        PreviewKey(inputs: viewModel.inputs.map(\.id), values: viewModel.values, editor: viewModel.editorState, password: viewModel.password)
    }

    private var showsPreview: Bool {
        guard tool.previewKind != nil, tool.editor == nil, !viewModel.needsPassword else { return false }
        return tool.input.acceptsFiles ? !viewModel.inputs.isEmpty : viewModel.blockingReason == nil
    }

    /// Editor tools show their editor as the screen once a file is in: pages, crop box, timeline,
    /// signature canvas or text boxes, with the action button below.
    private var showsInlineEditor: Bool {
        tool.editor != nil && !viewModel.inputs.isEmpty && !viewModel.needsPassword
    }

    /// Photo and video tools open Photos first; everything else opens Files.
    private var prefersPhotos: Bool {
        acceptsPhotos && tool.input.formats.allSatisfy { $0.family == .image || $0.family == .video }
    }

    var body: some View {
        presentations(screen)
    }

    private var screen: some View {
        VStack(spacing: 0) {
            if showsInlineEditor, let editor = tool.editor, let file = viewModel.inputs.first {
                // While typing on the canvas, the photo gets the room.
                if !isKeyboardVisible { fileStrip(file) }
                inlineEditor(editor, file: file)
                    .id(file.id)
                    .frame(maxHeight: .infinity)
                if !viewModel.optionSections.isEmpty || !viewModel.advancedOptions.isEmpty {
                    editorOptions
                }
            } else {
                if showsPreview, let kind = tool.previewKind {
                    ToolPreviewPanel(kind: kind, model: preview, isExpanded: $isPreviewExpanded)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                optionsScroll
            }
        }
        .animation(.snappy(duration: 0.25), value: showsPreview)
        .animation(.snappy(duration: 0.25), value: showsInlineEditor)
        .onChange(of: previewKey, initial: true) { _, _ in
            guard showsPreview else { preview.reset(); return }
            if let reason = viewModel.blockingReason {
                preview.showWaiting(for: reason, tool: tool, inputs: viewModel.inputs)
                return
            }
            preview.schedule(tool: tool, inputs: viewModel.inputs, options: viewModel.values, editor: viewModel.editorState)
        }
        .onDisappear { preview.tearDown() }
        .screenBackground()
        .navigationTitle(tool.title)
        .navigationBarTitleDisplayMode(.inline)
        .floatingBottomBar {
            if !(showsInlineEditor && isKeyboardVisible) { actionBar }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in isKeyboardVisible = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in isKeyboardVisible = false }
    }

    private var optionsScroll: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                // The description and privacy note help before a file is picked; after that they only
                // take room from the options.
                if viewModel.inputs.isEmpty { header }
                if tool.input.acceptsFiles { filesSection }
                if viewModel.needsPassword { passwordSection }
                ForEach(Array(viewModel.optionSections.enumerated()), id: \.offset) { _, section in
                    optionSection(section.title, section.options, single: viewModel.optionSections.count == 1)
                }
                if !viewModel.advancedOptions.isEmpty { moreOptions }
                if viewModel.inputs.isEmpty { PrivacyNote().padding(.top, Theme.Spacing.s) }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.s)
            .padding(.bottom, Theme.Spacing.xl)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.25), value: viewModel.visibleOptions.map(\.key))
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private func presentations<Content: View>(_ content: Content) -> some View {
        @Bindable var viewModel = viewModel
        return content
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: tool.input.contentTypes, allowsMultipleSelection: tool.input.allowsMultiple) { result in
            switch result {
            case .success(let urls):
                viewModel.importURLs(urls)
                runIfPickWasTheOnlyChoice()
            case .failure(let error): viewModel.errorMessage = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $isPhotoPickerPresented, selection: $photoItems,
                      maxSelectionCount: max(1, tool.input.maxCount - viewModel.inputs.count), matching: photoFilter)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                await viewModel.importPhotos(items)
                photoItems = []
                runIfPickWasTheOnlyChoice()
            }
        }
        .alert("Something went wrong", isPresented: Binding(get: { viewModel.errorMessage != nil }, set: { if !$0 { viewModel.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
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
            let buttons = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Theme.Spacing.s))
                : AnyLayout(HStackLayout(spacing: Theme.Spacing.s))
            buttons {
                Button {
                    isFileImporterPresented = true
                } label: {
                    Label("Files", systemImage: "folder")
                        .lineLimit(1)
                        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 140)
                }
                .buttonStyle(PrimaryButtonStyle())
                if acceptsPhotos {
                    PhotosPicker(selection: $photoItems, maxSelectionCount: tool.input.maxCount, matching: photoFilter) {
                        Label("Photos", systemImage: "photo.on.rectangle")
                            .lineLimit(1)
                            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 140)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? .infinity : 320)
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

    private func addMenu(compact: Bool, title: String? = nil) -> some View {
        Menu {
            Button { isFileImporterPresented = true } label: { Label("Choose Files", systemImage: "folder") }
            if acceptsPhotos {
                PhotosPicker(selection: $photoItems, maxSelectionCount: max(1, tool.input.maxCount - viewModel.inputs.count), matching: photoFilter) {
                    Label("Choose from Photos", systemImage: "photo.on.rectangle")
                }
            }
            Button { viewModel.importPasteboard(); runIfPickWasTheOnlyChoice() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
        } label: {
            let label = Label(title ?? (tool.input.allowsMultiple ? "Add" : "Replace"), systemImage: tool.input.allowsMultiple ? "plus" : "arrow.triangle.2.circlepath")
            Group {
                // Large text keeps the icon alone so the word never breaks across lines.
                if dynamicTypeSize.isAccessibilitySize { label.labelStyle(.iconOnly) } else { label.lineLimit(1).fixedSize() }
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.tint)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
    }

    /// One line above an inline editor: which file, and a way to swap it.
    private func fileStrip(_ file: ToolInputFile) -> some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: file.format.symbolName)
                .foregroundStyle(Theme.tint)
            Text(viewModel.inputs.count > 1 ? "\(viewModel.inputs.count) \(tool.input.noun)" : file.displayName)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            addMenu(compact: true, title: tool.input.allowsMultiple ? "Add" : "Change")
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, Theme.Spacing.s)
    }

    /// The few settings an editor tool has, under its editor.
    private var editorOptions: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                ForEach(Array(viewModel.optionSections.enumerated()), id: \.offset) { _, section in
                    optionSection(section.title, section.options, single: true)
                }
                if !viewModel.advancedOptions.isEmpty { moreOptions }
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: 720)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: viewModel.optionSections.isEmpty && !showsMoreOptions ? 64 : 230)
    }

    /// Settings most people never touch, folded into one row that says what they're set to.
    private var moreOptions: some View {
        @Bindable var viewModel = viewModel
        return VStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { showsMoreOptions.toggle() }
            } label: {
                HStack {
                    Text("More options")
                        .font(.body)
                        .foregroundStyle(Theme.text)
                    Spacer()
                    if !showsMoreOptions {
                        Text(advancedSummary)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textMuted)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textFaint)
                        .rotationEffect(.degrees(showsMoreOptions ? 180 : 0))
                }
                .padding(.horizontal, Theme.Spacing.l)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tool.moreOptions")
            if showsMoreOptions {
                ForEach(viewModel.advancedOptions) { option in
                    Divider().overlay(Theme.separator).padding(.leading, Theme.Spacing.l)
                    OptionControl(option: option, values: $viewModel.values, inputs: viewModel.inputs)
                }
            }
        }
        .card(padding: 0)
    }

    /// "Same as original · 90%": what the folded settings are set to.
    private var advancedSummary: String {
        viewModel.advancedOptions.prefix(3).compactMap { option -> String? in
            switch option.kind {
            case .choice(let choices, _):
                return choices.first { $0.value == viewModel.values.string(option.key) }?.label
            case .toggle:
                return viewModel.values.bool(option.key) ? option.label : nil
            case .slider(_, _, let format):
                return format(viewModel.values.double(option.key))
            case .stepper(_, let suffix):
                return "\(viewModel.values.int(option.key))\(suffix)"
            default:
                return nil
            }
        }.joined(separator: " · ")
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

    private func optionSection(_ title: String?, _ options: [ToolOption], single: Bool = false) -> some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            // A lone untitled card needs no "Options" heading.
            if let heading = title ?? (single ? nil : "Options") { sectionTitle(heading) }
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
                Button(action: primaryAction) {
                    PrimaryActionLabel(title: viewModel.blockingReason ?? tool.actionTitle,
                                       systemImage: viewModel.isMissingFiles ? "plus" : (viewModel.blockingReason == nil ? actionSymbol : "exclamationmark.circle"))
                }
                .accessibilityIdentifier("tool.run")
                .glassButtonStyle(prominent: true)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(Theme.tint)
                // Missing files: the button opens the picker. Anything else missing: it says what.
                .disabled(viewModel.blockingReason != nil && !viewModel.isMissingFiles)
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

    private func primaryAction() {
        if viewModel.isMissingFiles {
            openPicker()
        } else {
            perform()
        }
    }

    private func openPicker() {
        Haptics.impact(.light)
        if prefersPhotos { isPhotoPickerPresented = true } else { isFileImporterPresented = true }
    }

    /// For tools where picking the file was the only decision, picking it runs the tool.
    private func runIfPickWasTheOnlyChoice() {
        guard tool.runsOnPick, viewModel.blockingReason == nil, !viewModel.isRunning else { return }
        perform()
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

    /// The tool's editor, inline: every change goes straight into the tool's state.
    @ViewBuilder
    private func inlineEditor(_ editor: ToolEditorKind, file: ToolInputFile) -> some View {
        @Bindable var viewModel = viewModel
        switch editor {
        case .pageOrganizer:
            PageOrganizerView(url: file.url, password: viewModel.password.nilIfBlank, initialEdits: viewModel.editorState.pageEdits, embedded: true) { edits in
                viewModel.editorState = .pages(edits)
            }
        case .pagePicker(let keepsSelection):
            PagePickerView(url: file.url, password: viewModel.password.nilIfBlank, mode: keepsSelection ? .keep : .delete,
                           initialSelection: viewModel.editorState.selectedPages) { pages in
                viewModel.editorState = .pageSelection(pages)
            }
        case .splitPicker:
            PagePickerView(url: file.url, password: viewModel.password.nilIfBlank, mode: .split,
                           initialSelection: viewModel.editorState.selectedPages) { pages in
                viewModel.editorState = .pageSelection(pages)
            }
        case .pdfMarkup(let signatureFirst):
            PDFMarkupEditorView(url: file.url, password: viewModel.password.nilIfBlank, initialItems: viewModel.editorState.overlays,
                                startsWithSignature: signatureFirst, embedded: true) { items in
                viewModel.editorState = .overlays(items)
            }
        case .imageCrop:
            ImageCropEditorView(url: file.url, initialRect: viewModel.editorState.cropRect, embedded: true) { rect in
                viewModel.editorState = .crop(rect)
            }
        case .mediaRange:
            MediaRangeEditorView(url: file.url, initialRange: viewModel.editorState.range, embedded: true) { start, end in
                viewModel.editorState = .range(start: start, end: end)
            }
        case .textOverlay(let preset):
            TextOverlayEditor(url: file.url, preset: preset, imageCount: viewModel.inputs.count, overlays: Binding(
                get: { viewModel.editorState.texts(for: preset) },
                set: { viewModel.editorState = .texts($0) }
            ))
            .onAppear {
                // Seed the starting boxes once, so they keep their identity while being edited.
                if viewModel.editorState.textOverlays == nil { viewModel.editorState = .texts(TextOverlay.defaults(for: preset)) }
            }
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
