import PDFKit
import SwiftUI

/// Tap the pages you mean instead of typing "2, 5-7": pages to delete, pages to keep, or the pages
/// where each new file starts (Split). Inline on the tool screen; reports the chosen pages, in
/// document order, on every change.
struct PagePickerView: View {
    enum Mode {
        /// Chosen pages are removed (Delete).
        case delete
        /// Chosen pages are kept (Extract).
        case keep
        /// A new file starts at each chosen page (Split). Page 1 always starts the first file.
        case split
    }

    let url: URL
    let password: String?
    let mode: Mode
    let onChange: ([Int]) -> Void

    @State private var document: PDFDocument?
    @State private var selection: Set<Int>
    @State private var thumbnails: [Int: UIImage] = [:]
    @State private var loadError: String?

    init(url: URL, password: String?, mode: Mode, initialSelection: [Int], onChange: @escaping ([Int]) -> Void) {
        self.url = url
        self.password = password
        self.mode = mode
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
                            page(index)
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

    private func page(_ index: Int) -> some View {
        let isChosen = selection.contains(index)
        return PageCell(edit: PDFToolkit.PageEdit(sourceIndex: index), number: index + 1, image: thumbnails[index],
                        aspect: aspect(of: index), isSelected: isChosen)
            .opacity(mode == .delete && isChosen ? 0.45 : 1)
            .overlay {
                if mode == .delete, isChosen {
                    Image(systemName: "trash.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.danger)
                }
            }
            .overlay(alignment: .topLeading) {
                if mode == .split, index == 0 || isChosen { partBadge(part(of: index)) }
            }
            .onTapGesture { toggle(index) }
            .task { thumbnail(for: index) }
            .accessibilityIdentifier("page.\(index + 1)")
            .accessibilityLabel(mode == .split ? "Page \(index + 1), in PDF \(part(of: index))" : "Page \(index + 1)")
            .accessibilityAddTraits(isChosen ? .isSelected : [])
            .accessibilityHint(mode == .split && index > 0 ? (isChosen ? "Double-tap to keep it with the page before." : "Double-tap to start a new PDF here.") : "")
    }

    /// "PDF 2" on the page that starts each part, with scissors where the cut is.
    private func partBadge(_ part: Int) -> some View {
        Label("PDF \(part)", systemImage: part == 1 ? "doc" : "scissors")
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(Theme.onPrimary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Theme.primary, in: Capsule())
            .offset(x: -6, y: -8)
            .accessibilityHidden(true)
    }

    /// Which output file a page lands in (1-based).
    private func part(of index: Int) -> Int {
        selection.filter { $0 > 0 && $0 <= index }.count + 1
    }

    private var bar: some View {
        HStack {
            Text(status)
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
            Spacer()
            if !selection.isEmpty {
                Button("Clear") { set([]) }
            } else if let count = document?.pageCount, count > 1 {
                switch mode {
                case .keep: Button("Select All") { set(Set(0 ..< count)) }
                case .split: Button("Every Page") { set(Set(1 ..< count)) }
                case .delete: EmptyView()
                }
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
        switch mode {
        case .delete:
            return selection.isEmpty ? "Tap the pages to delete" : "Deleting \(selection.count) · \(max(total - selection.count, 0)) left"
        case .keep:
            return selection.isEmpty ? "Tap the pages to keep" : "Keeping \(selection.count) of \(total) pages"
        case .split:
            return selection.isEmpty ? "Tap the page where each new PDF starts" : "Makes \(selection.count + 1) PDFs"
        }
    }

    private func toggle(_ index: Int) {
        // The first page always starts the first file.
        guard mode != .split || index > 0 else { return }
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
