import PDFKit
import SwiftUI

/// Tap the pages you mean (to delete, or to keep) instead of typing "2, 5-7". Inline on the tool
/// screen; reports the chosen pages, in document order, on every change.
struct PagePickerView: View {
    let url: URL
    let password: String?
    /// true: chosen pages are kept (Extract). false: chosen pages are removed (Delete).
    let keepsSelection: Bool
    let onChange: ([Int]) -> Void

    @State private var document: PDFDocument?
    @State private var selection: Set<Int>
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var loadError: String?

    init(url: URL, password: String?, keepsSelection: Bool, initialSelection: [Int], onChange: @escaping ([Int]) -> Void) {
        self.url = url
        self.password = password
        self.keepsSelection = keepsSelection
        self.onChange = onChange
        _selection = State(initialValue: Set(initialSelection))
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: 14)]

    var body: some View {
        Group {
            if let loadError {
                ContentUnavailableView("Can't Open PDF", systemImage: "lock.doc", description: Text(loadError))
            } else if let document {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(0 ..< document.pageCount, id: \.self) { index in
                            PageCell(edit: PDFToolkit.PageEdit(sourceIndex: index), number: index + 1, image: thumbnails[index],
                                     aspect: aspect(of: index), isSelected: selection.contains(index))
                                .opacity(!keepsSelection && selection.contains(index) ? 0.45 : 1)
                                .overlay {
                                    if !keepsSelection, selection.contains(index) {
                                        Image(systemName: "trash.fill")
                                            .font(.title2)
                                            .foregroundStyle(Theme.danger)
                                    }
                                }
                                .onTapGesture { toggle(index) }
                                .task { thumbnail(for: index) }
                                .accessibilityIdentifier("page.\(index + 1)")
                        }
                    }
                    .padding(Theme.Spacing.l)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) { bar }
        .task { load() }
    }

    private var bar: some View {
        HStack {
            Text(status)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            if !selection.isEmpty {
                Button("Clear") { set([]) }
            } else if keepsSelection, let count = document?.pageCount {
                Button("Select All") { set(Set(0 ..< count)) }
            }
        }
        .font(.subheadline.weight(.medium))
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider().overlay(Theme.separator) }
    }

    private var status: String {
        let total = document?.pageCount ?? 0
        if selection.isEmpty { return keepsSelection ? "Tap the pages to keep" : "Tap the pages to delete" }
        if keepsSelection { return "Keeping \(selection.count) of \(total) pages" }
        return "Deleting \(selection.count) · \(max(total - selection.count, 0)) left"
    }

    private func toggle(_ index: Int) {
        Haptics.selection()
        var next = selection
        if next.contains(index) { next.remove(index) } else { next.insert(index) }
        set(next)
    }

    private func set(_ pages: Set<Int>) {
        selection = pages
        onChange(pages.sorted())
    }

    private func load() {
        guard document == nil else { return }
        guard let document = PDFDocument(url: url) else {
            loadError = "The file isn't a readable PDF."
            return
        }
        if document.isLocked, !(password.map { document.unlock(withPassword: $0) } ?? false) {
            loadError = "Enter the PDF's password first."
            return
        }
        self.document = document
    }

    private func thumbnail(for index: Int) {
        guard thumbnails[index] == nil, let page = document?.page(at: index) else { return }
        thumbnails[index] = page.thumbnail(of: CGSize(width: 240, height: 320), for: .cropBox)
    }

    private func aspect(of index: Int) -> CGFloat {
        guard let page = document?.page(at: index) else { return 0.77 }
        let size = PDFRasterizer.displaySize(of: page)
        return size.width / max(size.height, 1)
    }
}
