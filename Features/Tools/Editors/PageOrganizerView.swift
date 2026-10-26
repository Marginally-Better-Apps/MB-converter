import PDFKit
import SwiftUI

struct PageOrganizerView: View {
    let url: URL
    let password: String?
    /// Shown inline on the tool screen: no navigation bar or Done/Cancel; every change is reported.
    var embedded = false
    let onDone: ([PDFToolkit.PageEdit]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var edits: [PDFToolkit.PageEdit]
    @State private var selection: Set<UUID> = []
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var loadError: String?

    init(url: URL, password: String?, initialEdits: [PDFToolkit.PageEdit]?, embedded: Bool = false, onDone: @escaping ([PDFToolkit.PageEdit]) -> Void) {
        self.url = url
        self.password = password
        self.embedded = embedded
        self.onDone = onDone
        _edits = State(initialValue: initialEdits ?? [])
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    var body: some View {
        if embedded {
            content
                .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
                .task { load() }
                .onChange(of: edits) { _, edits in onDone(edits) }
        } else {
            sheet
        }
    }

    private var content: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Can't Open PDF", systemImage: "lock.doc", description: Text(loadError))
            } else if document == nil {
                ProgressView()
            } else {
                grid
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sheet: some View {
        NavigationStack {
            content
            .screenBackground()
            .navigationTitle(selection.isEmpty ? "\(edits.count) Pages" : "\(selection.count) Selected")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onDone(edits)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(edits.isEmpty)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
        }
        .task { load() }
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(Array(edits.enumerated()), id: \.element.id) { index, edit in
                    PageCell(edit: edit, number: index + 1, image: edit.sourceIndex.flatMap { thumbnails[$0] }, aspect: aspect(for: edit), isSelected: selection.contains(edit.id))
                        .onTapGesture {
                            Haptics.selection()
                            if selection.contains(edit.id) { selection.remove(edit.id) } else { selection.insert(edit.id) }
                        }
                        .draggable(edit.id.uuidString) {
                            PageCell(edit: edit, number: index + 1, image: edit.sourceIndex.flatMap { thumbnails[$0] }, aspect: aspect(for: edit), isSelected: true)
                                .frame(width: 90)
                        }
                        .dropDestination(for: String.self) { items, _ in
                            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
                            move(id, to: edit.id)
                            return true
                        }
                        .task(id: edit.sourceIndex) { thumbnail(for: edit.sourceIndex) }
                }
            }
            .padding(Theme.Spacing.l)
            Text(embedded ? "\(edits.count) pages · tap to select, drag to reorder" : "Tap to select. Drag to reorder.")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .padding(.bottom, Theme.Spacing.l)
        }
    }

    private var actionBar: some View {
        HStack(spacing: 0) {
            if selection.isEmpty {
                barButton("Select All", "checkmark.circle") { selection = Set(edits.map(\.id)) }
                barButton("Reverse", "arrow.up.arrow.down") { withAnimation { edits.reverse() } }
                barButton("Add Blank", "doc.badge.plus") { withAnimation { edits.append(PDFToolkit.PageEdit(sourceIndex: nil)) } }
            } else {
                barButton("Left", "rotate.left") { rotate(-90) }
                barButton("Right", "rotate.right") { rotate(90) }
                barButton("Duplicate", "plus.square.on.square") { duplicate() }
                barButton("Blank After", "doc.badge.plus") { insertBlank() }
                barButton("Delete", "trash", role: .destructive) { delete() }
                    .disabled(selection.count >= edits.count)
            }
        }
        .padding(.horizontal, Theme.Spacing.s)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .top) { Divider().overlay(Theme.separator) }
    }

    private func barButton(_ title: String, _ symbol: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role) {
            Haptics.impact(.light)
            action()
        } label: {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 18))
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(role == .destructive ? Theme.danger : Theme.tint)
        }
        .buttonStyle(.plain)
    }

    // MARK: Data

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
        if edits.isEmpty { edits = PDFToolkit.PageEdit.identity(pageCount: document.pageCount) }
    }

    private func thumbnail(for index: Int?) {
        guard let index, thumbnails[index] == nil, let page = document?.page(at: index) else { return }
        thumbnails[index] = page.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
    }

    private func aspect(for edit: PDFToolkit.PageEdit) -> CGFloat {
        let page = edit.sourceIndex.flatMap { document?.page(at: $0) } ?? document?.page(at: 0)
        guard let page else { return 0.77 }
        let size = PDFRasterizer.displaySize(of: page)
        return size.width / max(size.height, 1)
    }

    private func rotate(_ degrees: Int) {
        withAnimation(.snappy) {
            for index in edits.indices where selection.contains(edits[index].id) {
                edits[index].rotation = PDFToolkit.normalizedRotation(edits[index].rotation + degrees)
            }
        }
    }

    private func duplicate() {
        withAnimation(.snappy) {
            var result: [PDFToolkit.PageEdit] = []
            for edit in edits {
                result.append(edit)
                if selection.contains(edit.id) { result.append(PDFToolkit.PageEdit(sourceIndex: edit.sourceIndex, rotation: edit.rotation)) }
            }
            edits = result
        }
    }

    private func insertBlank() {
        guard let last = edits.lastIndex(where: { selection.contains($0.id) }) else { return }
        withAnimation(.snappy) { edits.insert(PDFToolkit.PageEdit(sourceIndex: nil), at: last + 1) }
    }

    private func delete() {
        withAnimation(.snappy) {
            edits.removeAll { selection.contains($0.id) }
            selection.removeAll()
        }
    }

    private func move(_ id: UUID, to target: UUID) {
        guard id != target, let from = edits.firstIndex(where: { $0.id == id }), let to = edits.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(.snappy) {
            let item = edits.remove(at: from)
            edits.insert(item, at: to)
        }
        Haptics.impact(.light)
    }
}

private struct PageCell: View {
    let edit: PDFToolkit.PageEdit
    let number: Int
    let image: UIImage?
    let aspect: CGFloat
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if edit.sourceIndex == nil {
                    Text("Blank")
                        .font(.caption)
                        .foregroundStyle(.gray)
                } else {
                    ProgressView()
                }
            }
            .aspectRatio(aspect, contentMode: .fit)
            .rotationEffect(.degrees(Double(edit.rotation)))
            .frame(height: 140)
            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Theme.tint : Color.clear, lineWidth: 3)
                    .padding(-4)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Theme.onPrimary, Theme.tint)
                        .offset(x: 8, y: -8)
                }
            }
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isSelected ? Theme.tint : Theme.textMuted)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(edit.sourceIndex.map { "Page \(number), original page \($0 + 1)" } ?? "Page \(number), blank")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
