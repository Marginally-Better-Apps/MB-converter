import SwiftUI

struct ConversionHistoryListView: View {
    @Binding var path: [AppRoute]
    var showsContentTitle = false
    /// Allows deterministic previews without mutating the shared history store.
    var previewEntries: [ConversionHistoryEntry]? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var store = ConversionHistoryStore.shared
    @State private var isClearAllConfirming = false
    @State private var entryPendingDeletion: ConversionHistoryEntry?

    var body: some View {
        List {
            if showsContentTitle {
                Text("History")
                    .font(.largeTitle.bold())
                    .foregroundStyle(Theme.text)
                    .accessibilityAddTraits(.isHeader)
                    .listRowInsets(EdgeInsets(top: 4, leading: 20, bottom: 2, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }

            Section {
                historySummary
                    .listRowBackground(Theme.surface)
            }

            if entries.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No Conversions Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Converted files will appear here.")
                    )
                    .foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Theme.surface)
                }
            } else {
                Section("Conversions") {
                    ForEach(entries) { entry in
                        historyRow(entry: entry)
                            .listRowBackground(Theme.surface)
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .tint(Theme.primary)
        .navigationTitle(isRootSectionActive && !showsContentTitle ? "History" : "")
        .navigationBarTitleDisplayMode(.large)
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
            "Delete this conversion?",
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
                Text("This removes the result file for \(entry.input.originalFilename) from History.")
            }
        }
    }

    private var historySummary: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.storageSummaryTitle)
                        .font(.headline)
                        .foregroundStyle(Theme.text)
                    Text(store.storageSummaryDescription)
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
            } icon: {
                Image(systemName: store.isEnabled ? "externaldrive.fill" : "hourglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 32, height: 32)
                    .background(
                        Theme.secondary.opacity(0.2),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )
            }
            .labelStyle(.titleAndIcon)

            Divider()

            LabeledContent("Storage Used") {
                Text(MetadataFormatter.bytes(storageBytes))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.primary)
                    .monospacedDigit()
            }
            .foregroundStyle(Theme.text)

            if !entries.isEmpty {
                Button(role: .destructive) {
                    Haptics.warning()
                    isClearAllConfirming = true
                } label: {
                    Label("Clear History", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.destructive)
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(Theme.separator, lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
    }

    private var entries: [ConversionHistoryEntry] {
        previewEntries ?? store.entries
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

    private func historyRow(entry: ConversionHistoryEntry) -> some View {
        Button {
            Haptics.impact(.light)
            path.append(
                .result(
                    entry.input,
                    entry.config,
                    entry.result,
                    fromHistory: true
                )
            )
        } label: {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 5) {
                    Text(entry.input.originalFilename)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(
                        "\(entry.result.outputFormat.displayName) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))"
                    )
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    Text(entry.createdAt, format: .dateTime)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 14) {
                    MediaPreview(
                        url: entry.result.url,
                        category: entry.result.outputFormat.category,
                        compact: true,
                        showsChrome: false,
                        isInteractive: false
                    )
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.input.originalFilename)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Text(
                            "\(entry.result.outputFormat.displayName) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))"
                        )
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        Text(entry.createdAt, format: .dateTime)
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textMuted.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityHint("Opens the converted file")
    }
}

#Preview("History · Empty · Compact", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        ConversionHistoryListView(path: .constant([]), previewEntries: [])
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.light)
}
