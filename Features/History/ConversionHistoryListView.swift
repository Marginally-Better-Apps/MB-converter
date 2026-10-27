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
    /// Mirrors the store's setting so turning it on here or in Settings redraws the list.
    @AppStorage(ConversionHistoryUserDefaults.isEnabledKey)
    private var isSavedHistoryEnabled = ConversionHistoryUserDefaults.defaultIsEnabled

    var body: some View {
        List {
            Section {
                historySummary
            } footer: {
                Text(store.storageSummaryDescription)
            }

            if entries.isEmpty {
                Section {
                    emptyState
                }
            } else {
                ForEach(HistoryDay.group(entries)) { group in
                    Section(group.day.title) {
                        ForEach(group.items) { entry in
                            historyRow(item: entry, day: group.day)
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
                }

                if isSavedHistoryEnabled {
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
                Text("This removes the result \(entry.fileCount == 1 ? "file" : "files") for \(entry.outputName) from History.")
            }
        }
    }

    private var historySummary: some View {
        // Large text stacks the storage under the title instead of squeezing both into one row.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            if !dynamicTypeSize.isAccessibilitySize {
                IconTile(systemImage: isSavedHistoryEnabled ? "externaldrive.fill" : "hourglass")
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(store.storageSummaryTitle)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                Text("\(entries.count) \(entries.count == 1 ? "item" : "items")")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
            }

            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }

            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
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

    private func historyRow(item: HistoryItem, day: HistoryDay) -> some View {
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
                    rowText(item: item, day: day)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    HistoryThumbnail(item: item)
                        .frame(width: 60, height: 60)
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        rowText(item: item, day: day)
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
    private func rowText(item: HistoryItem, day: HistoryDay) -> some View {
        // What you got, then what made it, then where it came from and when.
        Text(item.outputName)
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.middle)
        Text(item.actionSummary)
            .font(.subheadline)
            .foregroundStyle(Theme.textMuted)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
        Text(item.sourceLine(timeOnly: day != .earlier))
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var emptyState: some View {
        ContentUnavailableView {
            Label("Nothing Here Yet", systemImage: "clock.arrow.circlepath")
        } description: {
            Text(isSavedHistoryEnabled
                 ? "Files you convert or make with Tools will appear here."
                 : "Keep your results to find them here next time.")
        } actions: {
            if !isSavedHistoryEnabled && previewEntries == nil {
                Button("Keep my results") {
                    Haptics.impact(.medium)
                    store.enableSavedHistory()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityHint("Saves what you convert on this device until you delete it.")
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// History sections: Today, Yesterday, then everything older.
enum HistoryDay: String, CaseIterable, Hashable {
    case today, yesterday, earlier

    var title: String {
        switch self {
        case .today: "Today"
        case .yesterday: "Yesterday"
        case .earlier: "Earlier"
        }
    }

    static func day(for date: Date, now: Date = .now, calendar: Calendar = .current) -> HistoryDay {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return date > now ? .today : .earlier
    }

    struct DayGroup: Identifiable {
        let day: HistoryDay
        let items: [HistoryItem]
        var id: HistoryDay { day }
    }

    /// Non-empty sections in order, keeping each section's items in the order given (newest first).
    static func group(_ items: [HistoryItem], now: Date = .now, calendar: Calendar = .current) -> [DayGroup] {
        let byDay = Dictionary(grouping: items) { day(for: $0.createdAt, now: now, calendar: calendar) }
        return allCases.compactMap { day in byDay[day].map { DayGroup(day: day, items: $0) } }
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

    /// The file the user got, as it's named when shared: "IMG_0234.jpg", "Report-compressed.pdf + 2 more".
    var outputName: String {
        switch self {
        case .conversion(let entry):
            let base = (entry.input.originalFilename as NSString).deletingPathExtension
            return "\(base.isEmpty ? "converted" : base).\(entry.result.outputFormat.fileExtension)"
        case .tool(let entry):
            guard let first = entry.files.first?.lastPathComponent else { return entry.title }
            return entry.files.count > 1 ? "\(first) + \(entry.files.count - 1) more" : first
        }
    }

    /// What made it: "HEIC to JPEG · 1.2 MB", "Compress PDF · 2 files · 3 MB".
    var actionSummary: String {
        switch self {
        case .conversion(let entry):
            let source = (entry.input.originalFilename as NSString).pathExtension.uppercased()
            let action = source.isEmpty
                ? "Converted to \(entry.result.outputFormat.displayName)"
                : "\(source) to \(entry.result.outputFormat.displayName)"
            return "\(action) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))"
        case .tool(let entry):
            guard !entry.files.isEmpty else { return entry.title }
            let files = entry.files.count == 1 ? nil : "\(entry.files.count) files"
            return ([entry.title, files, MetadataFormatter.bytes(entry.totalBytes)].compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// "From IMG_0234.HEIC · 3:41 PM"; the date is included for older items.
    func sourceLine(timeOnly: Bool) -> String {
        let time = timeOnly
            ? createdAt.formatted(date: .omitted, time: .shortened)
            : createdAt.formatted(date: .abbreviated, time: .shortened)
        let inputs: [String]
        switch self {
        case .conversion(let entry): inputs = [entry.input.originalFilename].filter { !$0.isEmpty }
        case .tool(let entry): inputs = entry.inputNames
        }
        guard let first = inputs.first else { return time }
        let source = inputs.count > 1 ? "\(first) + \(inputs.count - 1) more" : first
        return "From \(source) · \(time)"
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
