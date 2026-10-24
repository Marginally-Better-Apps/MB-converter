import PDFKit
import PhotosUI
import SwiftUI

struct PDFMarkupEditorView: View {
    let url: URL
    let password: String?
    let startsWithSignature: Bool
    let onDone: ([PDFOverlayItem]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var pageIndex = 0
    @State private var pageImage: UIImage?
    @State private var items: [PDFOverlayItem]
    @State private var selectedID: UUID?
    @State private var isSignaturePresented = false
    @State private var editingText: PDFOverlayItem?
    @State private var textDraft = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var loadError: String?
    @State private var didAutoOpenSignature = false

    init(url: URL, password: String?, initialItems: [PDFOverlayItem], startsWithSignature: Bool, onDone: @escaping ([PDFOverlayItem]) -> Void) {
        self.url = url
        self.password = password
        self.startsWithSignature = startsWithSignature
        self.onDone = onDone
        _items = State(initialValue: initialItems)
    }

    private var pageCount: Int { document?.pageCount ?? 0 }

    private var pageSize: CGSize {
        guard let page = document?.page(at: pageIndex) else { return CGSize(width: 612, height: 792) }
        return PDFRasterizer.displaySize(of: page)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let loadError {
                    ContentUnavailableView("Can't Open PDF", systemImage: "lock.doc", description: Text(loadError))
                } else {
                    pageCanvas
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.surfaceSunken.ignoresSafeArea())
            .navigationTitle(pageCount > 0 ? "Page \(pageIndex + 1) of \(pageCount)" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(items)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .safeAreaInset(edge: .bottom) { toolbar }
        }
        .task { load() }
        .sheet(isPresented: $isSignaturePresented) {
            SignaturePadView { data in add(.image(data), aspect: aspectRatio(of: data)) }
        }
        .alert("Text", isPresented: Binding(get: { editingText != nil }, set: { if !$0 { editingText = nil } })) {
            TextField("Text", text: $textDraft)
            Button("Cancel", role: .cancel) {}
            Button("Done") { commitText() }
        }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    add(.image(data), aspect: aspectRatio(of: data))
                }
                photoItem = nil
            }
        }
    }

    // MARK: Canvas

    private var pageCanvas: some View {
        GeometryReader { geometry in
            let available = CGSize(width: geometry.size.width - 32, height: geometry.size.height - 32)
            let scale = min(available.width / pageSize.width, available.height / pageSize.height)
            let displaySize = CGSize(width: pageSize.width * scale, height: pageSize.height * scale)
            ZStack(alignment: .topLeading) {
                Group {
                    if let pageImage {
                        Image(uiImage: pageImage).resizable()
                    } else {
                        Color.white.overlay { ProgressView() }
                    }
                }
                .frame(width: displaySize.width, height: displaySize.height)
                .onTapGesture { selectedID = nil }

                ForEach(items.filter { $0.pageIndex == pageIndex }) { item in
                    OverlayItemView(
                        item: binding(for: item.id),
                        canvasSize: displaySize,
                        pointScale: scale,
                        isSelected: selectedID == item.id,
                        onSelect: { selectedID = item.id },
                        onEdit: { beginEditing(item) },
                        onDelete: { delete(item.id) }
                    )
                }
            }
            .frame(width: displaySize.width, height: displaySize.height)
            .clipped()
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .gesture(DragGesture(minimumDistance: 40).onEnded { value in
            // Swipe left/right on empty space to change pages.
            guard selectedID == nil, abs(value.translation.width) > abs(value.translation.height) else { return }
            go(value.translation.width < 0 ? 1 : -1)
        })
    }

    private var toolbar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.separator)
            HStack(spacing: Theme.Spacing.s) {
                Button { go(-1) } label: { Image(systemName: "chevron.left").frame(width: 32, height: 44) }
                    .disabled(pageIndex == 0)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        toolButton("Sign", "signature") { isSignaturePresented = true }
                        toolButton("Text", "textformat") { add(.text("Text", fontSize: 14, colorHex: 0x111111, bold: false), size: CGSize(width: 0.36, height: 0.04)); beginEditing(items.last!) }
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            toolLabel("Image", "photo")
                        }
                        toolButton("Highlight", "highlighter") { add(.highlight(colorHex: 0xFFE14D), size: CGSize(width: 0.4, height: 0.025)) }
                        toolButton("Box", "rectangle") { add(.rectangle(colorHex: 0xC0392B, lineWidth: 2), size: CGSize(width: 0.3, height: 0.1)) }
                        toolButton("Strike", "strikethrough") { add(.strikeLine(colorHex: 0xC0392B), size: CGSize(width: 0.3, height: 0.02)) }
                        toolButton("White-out", "eraser") { add(.whiteout, size: CGSize(width: 0.3, height: 0.04)) }
                        toolButton("Redact", "rectangle.fill") { add(.redaction, size: CGSize(width: 0.3, height: 0.03)) }
                    }
                }
                Button { go(1) } label: { Image(systemName: "chevron.right").frame(width: 32, height: 44) }
                    .disabled(pageIndex >= pageCount - 1)
            }
            .padding(.horizontal, Theme.Spacing.s)
            .padding(.vertical, 4)
        }
        .background(.bar)
    }

    private func toolButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.impact(.light)
            action()
        } label: {
            toolLabel(title, symbol)
        }
        .buttonStyle(.plain)
    }

    private func toolLabel(_ title: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 18))
            Text(title).font(.caption2)
        }
        .foregroundStyle(Theme.tint)
        .frame(width: 64, height: 46)
        .contentShape(Rectangle())
    }

    // MARK: Actions

    private func load() {
        guard document == nil else { return }
        guard let document = PDFDocument(url: url) else {
            loadError = "The file isn't a readable PDF."
            return
        }
        if document.isLocked, !(password.map { document.unlock(withPassword: $0) } ?? false) {
            loadError = "Enter the PDF's password on the previous screen first."
            return
        }
        self.document = document
        renderPage()
        if startsWithSignature, !didAutoOpenSignature, items.isEmpty {
            didAutoOpenSignature = true
            isSignaturePresented = true
        }
    }

    private func renderPage() {
        guard let page = document?.page(at: pageIndex) else { return }
        let size = PDFRasterizer.displaySize(of: page)
        let target = CGSize(width: 1_400, height: 1_400 * size.height / max(size.width, 1))
        pageImage = page.thumbnail(of: target, for: .cropBox)
    }

    private func go(_ delta: Int) {
        let next = pageIndex + delta
        guard next >= 0, next < pageCount else { return }
        selectedID = nil
        pageIndex = next
        pageImage = nil
        renderPage()
        Haptics.selection()
    }

    private func add(_ kind: PDFOverlayItem.Kind, size: CGSize = CGSize(width: 0.3, height: 0.1), aspect: CGFloat? = nil) {
        var frameSize = size
        if let aspect, aspect > 0 {
            // Keep image proportions relative to the page's own aspect ratio.
            let width: CGFloat = 0.32
            frameSize = CGSize(width: width, height: width * (pageSize.width / pageSize.height) / aspect)
        }
        let item = PDFOverlayItem(
            pageIndex: pageIndex,
            frame: CGRect(x: (1 - frameSize.width) / 2, y: (1 - frameSize.height) / 2, width: frameSize.width, height: frameSize.height),
            kind: kind
        )
        items.append(item)
        selectedID = item.id
    }

    private func aspectRatio(of data: Data) -> CGFloat {
        guard let image = UIImage(data: data), image.size.height > 0 else { return 2 }
        return image.size.width / image.size.height
    }

    private func binding(for id: UUID) -> Binding<PDFOverlayItem> {
        Binding(
            get: { items.first { $0.id == id } ?? PDFOverlayItem(pageIndex: 0, frame: .zero, kind: .whiteout) },
            set: { newValue in
                if let index = items.firstIndex(where: { $0.id == id }) { items[index] = newValue }
            }
        )
    }

    private func beginEditing(_ item: PDFOverlayItem) {
        guard case .text(let text, _, _, _) = item.kind else { return }
        textDraft = text == "Text" ? "" : text
        editingText = item
    }

    private func commitText() {
        guard let item = editingText, let index = items.firstIndex(where: { $0.id == item.id }),
              case .text(_, let size, let color, let bold) = item.kind else { return }
        if let text = textDraft.nilIfBlank {
            items[index].kind = .text(text, fontSize: size, colorHex: color, bold: bold)
            // Fit the box to the text so it doesn't wrap unexpectedly.
            let font = UIFont.systemFont(ofSize: size)
            let width = (text as NSString).size(withAttributes: [.font: font]).width + 8
            items[index].frame.size.width = min(0.95, max(items[index].frame.width, width / pageSize.width))
        } else {
            items.remove(at: index)
        }
        editingText = nil
    }

    private func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
        selectedID = nil
        Haptics.impact(.light)
    }
}

/// One draggable, resizable overlay drawn in normalized page coordinates.
private struct OverlayItemView: View {
    @Binding var item: PDFOverlayItem
    let canvasSize: CGSize
    let pointScale: CGFloat
    let isSelected: Bool
    let onSelect: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var dragStart: CGRect?
    @State private var resizeStart: CGRect?

    private var rect: CGRect {
        CGRect(x: item.frame.minX * canvasSize.width, y: item.frame.minY * canvasSize.height, width: item.frame.width * canvasSize.width, height: item.frame.height * canvasSize.height)
    }

    private var keepsAspect: Bool {
        if case .image = item.kind { return true }
        return false
    }

    var body: some View {
        content
            .frame(width: max(rect.width, 8), height: max(rect.height, 6))
            .overlay {
                if isSelected {
                    Rectangle().strokeBorder(Theme.tint, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if isSelected {
                    Circle()
                        .fill(Theme.tint)
                        .frame(width: 18, height: 18)
                        .overlay { Image(systemName: "arrow.up.left.and.arrow.down.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white) }
                        .offset(x: 9, y: 9)
                        .gesture(resizeGesture)
                        .accessibilityLabel("Resize")
                }
            }
            .overlay(alignment: .topLeading) {
                if isSelected {
                    HStack(spacing: 6) {
                        if case .text = item.kind {
                            chip("pencil", action: onEdit)
                        }
                        chip("trash", action: onDelete)
                    }
                    .offset(y: -34)
                }
            }
            .position(x: rect.midX, y: rect.midY)
            .gesture(dragGesture)
            .onTapGesture(count: 2) { onEdit() }
            .onTapGesture { onSelect() }
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text(let text, let fontSize, let colorHex, let bold):
            Text(text)
                .font(.system(size: fontSize * pointScale, weight: bold ? .semibold : .regular))
                .foregroundStyle(Color(uiColor: UIColor(hex: colorHex)))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .image(let data):
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable()
            }
        case .highlight(let colorHex):
            Rectangle().fill(Color(uiColor: UIColor(hex: colorHex)).opacity(0.45)).blendMode(.multiply)
        case .whiteout:
            Rectangle().fill(Color.white)
        case .redaction:
            Rectangle().fill(Color.black)
        case .rectangle(let colorHex, let lineWidth):
            Rectangle().strokeBorder(Color(uiColor: UIColor(hex: colorHex)), lineWidth: lineWidth * pointScale)
        case .strikeLine(let colorHex):
            Rectangle().fill(Color(uiColor: UIColor(hex: colorHex))).frame(height: max(1, rect.height * 0.12))
        }
    }

    private func chip(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 28)
                .background(Theme.primary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStart == nil { dragStart = item.frame; onSelect() }
                guard let start = dragStart else { return }
                var frame = start
                frame.origin.x = min(max(0, start.minX + value.translation.width / canvasSize.width), 1 - start.width)
                frame.origin.y = min(max(0, start.minY + value.translation.height / canvasSize.height), 1 - start.height)
                item.frame = frame
            }
            .onEnded { _ in dragStart = nil }
    }

    private var resizeGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if resizeStart == nil { resizeStart = item.frame }
                guard let start = resizeStart else { return }
                var width = max(0.02, start.width + value.translation.width / canvasSize.width)
                var height = max(0.01, start.height + value.translation.height / canvasSize.height)
                if keepsAspect {
                    let ratio = start.height / max(start.width, 0.0001)
                    height = width * ratio
                }
                width = min(width, 1 - start.minX)
                height = min(height, 1 - start.minY)
                item.frame.size = CGSize(width: width, height: height)
                if case .text(let text, _, let color, let bold) = item.kind {
                    // Text scales with its box height.
                    let points = height * canvasSize.height / pointScale * 0.72
                    item.kind = .text(text, fontSize: max(6, points), colorHex: color, bold: bold)
                }
            }
            .onEnded { _ in resizeStart = nil }
    }
}
