import SwiftUI

struct ConversionHistoryListView: View {
    @Binding var path: [AppRoute]
    /// Allows deterministic previews without mutating the shared history store.
    var previewEntries: [ConversionHistoryEntry]? = nil
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.isRootSectionActive) private var isRootSectionActive
    @State private var store = ConversionHistoryStore.shared
    @State private var isClearAllConfirming = false
    @State private var entryPendingDeletion: ConversionHistoryEntry?

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
                        "No Conversions Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Converted files will appear here.")
                    )
                    .frame(maxWidth: .infinity)
                }
            } else {
                Section("Conversions") {
                    ForEach(entries) { entry in
                        historyRow(entry: entry)
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
        HStack(spacing: 14) {
            IconTile(systemImage: store.isEnabled ? "externaldrive.fill" : "hourglass")

            VStack(alignment: .leading, spacing: 2) {
                Text(store.storageSummaryTitle)
                    .font(.body)
                    .foregroundStyle(Theme.text)
                Text("\(entries.count) \(entries.count == 1 ? "conversion" : "conversions")")
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
                    rowText(entry: entry)
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
                    .frame(width: 60, height: 60)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
                        rowText(entry: entry)
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
        .accessibilityHint("Opens the converted file")
    }

    @ViewBuilder
    private func rowText(entry: ConversionHistoryEntry) -> some View {
        Text(entry.input.originalFilename)
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.text)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .truncationMode(.middle)
        Text("\(entry.result.outputFormat.displayName) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))")
            .font(.subheadline)
            .foregroundStyle(Theme.textMuted)
        Text(entry.createdAt.formatted(date: .abbreviated, time: .shortened))
            .font(.caption)
            .foregroundStyle(Theme.textTertiary)
    }
}

#Preview("History · Empty · Compact", traits: .fixedLayout(width: 390, height: 844)) {
    NavigationStack {
        ConversionHistoryListView(path: .constant([]), previewEntries: [])
    }
    .environment(\.horizontalSizeClass, .compact)
    .preferredColorScheme(.light)
}
