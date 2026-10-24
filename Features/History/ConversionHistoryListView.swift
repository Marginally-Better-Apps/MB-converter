import SwiftUI

struct ConversionHistoryListView: View {
    @Binding var path: [AppRoute]
    /// Allows deterministic previews without mutating the shared history store.
    var previewEntries: [ConversionHistoryEntry]? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var store = ConversionHistoryStore.shared
    @State private var isClearAllConfirming = false
    @State private var entryPendingDeletion: HistoryItem?

    var body: some View {
        List {
            Section {
                historySummary
            } footer: {
                Text(store.storageSummaryDescription)
            }

            if entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "Nothing Here Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Files you convert or make with Tools will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section("Recent") {
                    ForEach(entries) { entry in
                        historyRow(item: entry)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    Haptics.warning()
                                    entryPendingDeletion = entry
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }

                if store.isEnabled {
                    Section {
                        Button(role: .destructive) {
                            Haptics.warning()
                            isClearAllConfirming = true
                        } label: {
                            Text("Clear History")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background { AmbientBackground() }
        .tint(Theme.tint)
        .navigationTitle(isRootSectionActive ? "History" : "")
        .navigationBarTitleDisplayMode(.large)
        .settingsToolbarButton()
        .onAppear {
            guard previewEntries == nil else { return }
            store = ConversionHistoryStore.shared
            store.refreshForCurrentSettings()
        }
        .alert("Delete all history?", isPresented: $isClearAllConfirming) {
            Button("Delete All", role: .destructive) {
                Haptics.warning()
                store.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every result file shown in History. This action cannot be undone.")
        }
        .confirmationDialog(
            "Delete from History?",
            isPresented: deleteEntryConfirmationBinding,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                guard let entry = entryPendingDeletion else { return }
                Haptics.warning()
                store.removeEntry(id: entry.id)
                entryPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            if let entry = entryPendingDeletion {
                Text("This removes the result \(entry.fileCount == 1 ? "file" : "files") for \(entry.displayName) from History.")
            }
        }
    }

    private var historySummary: some View {
        HStack(spacing: 14) {
            IconTile(systemImage: store.isEnabled ? "externaldrive.fill" : "hourglass")

            VStack(alignment: .leading, spacing: 2) {
                Text(store.storageSummaryTitle)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                Text("\(entries.count) \(entries.count == 1 ? "item" : "items")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(MetadataFormatter.bytes(storageBytes))
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(Theme.tint)
                Text("Storage Used")
                    .font(.caption)
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var entries: [HistoryItem] {
        previewEntries?.map(HistoryItem.conversion) ?? store.items
    }

    private var storageBytes: Int64 {
        previewEntries?.reduce(0) { $0 + $1.result.sizeOnDisk } ?? store.totalStorageBytes
    }

    private var deleteEntryConfirmationBinding: Binding<Bool> {
        Binding(
            get: { entryPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    entryPendingDeletion = nil
                }
            }
        )
    }

    private func historyRow(item: HistoryItem) -> some View {
        Button {
            Haptics.impact(.light)
            switch item {
            case .conversion(let entry):
                path.append(.result(entry.input, entry.config, entry.result, fromHistory: true))
            case .tool(let entry):
                path.append(.toolResult(entry.run))
            }
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    rowText(item: item)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    HistoryThumbnail(item: item)
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        rowText(item: item)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 2)
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint("Opens the result")
        .accessibilityIdentifier("history.row")
    }

    @ViewBuilder
    private func rowText(item: HistoryItem) -> some View {
        Text(item.displayName)
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.middle)
        Text(item.detail)
            .font(.subheadline)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
    }
}

/// The result's own preview: media for conversions, the first output file for tool runs.
struct HistoryThumbnail: View {
    let item: HistoryItem
    var cornerRadius: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            Group {
                switch item {
                case .conversion(let entry):
                    MediaPreview(
                        url: entry.result.url,
                        category: entry.result.outputFormat.category,
                        compact: true,
                        showsChrome: false,
                        isInteractive: false
                    )
                case .tool(let entry):
                    if let file = entry.files.first {
                        FileThumbnail(url: file, size: proxy.size, format: FileFormat(url: file))
                    } else if let tool = ToolCatalog.tool(entry.toolID) {
                        ToolGlyph(symbol: tool.symbol, category: tool.category, size: proxy.size.width * 0.5)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(Theme.background)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

extension HistoryItem {
    /// What the user started from (or made, for tools without inputs).
    var displayName: String {
        switch self {
        case .conversion(let entry):
            return entry.input.originalFilename
        case .tool(let entry):
            if let first = entry.inputNames.first {
                return entry.inputNames.count > 1 ? "\(first) + \(entry.inputNames.count - 1) more" : first
            }
            return entry.files.first?.lastPathComponent ?? entry.title
        }
    }

    var detail: String {
        switch self {
        case .conversion(let entry):
            return "\(entry.result.outputFormat.displayName) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))"
        case .tool(let entry):
            let files = entry.files.count == 1
                ? (FileFormat(url: entry.files[0])?.displayName ?? entry.files[0].pathExtension.uppercased())
                : "\(entry.files.count) files"
            return entry.files.isEmpty ? entry.title : "\(entry.title) · \(files) · \(MetadataFormatter.bytes(entry.totalBytes))"
        }
    }

    var fileCount: Int {
        switch self {
        case .conversion: 1
        case .tool(let entry): entry.files.count
        }
    }
}

#Preview("History · Empty · Compact", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        ConversionHistoryListView(path: .constant([]), previewEntries: [])
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.light)
}
