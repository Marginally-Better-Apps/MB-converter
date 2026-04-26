import SwiftUI

struct ConversionHistoryListView: View {
    @Binding var path: [AppRoute]
    @State private var store = ConversionHistoryStore.shared
    @State private var isClearAllConfirming = false
    @State private var entryPendingDeletion: ConversionHistoryEntry?

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()

            if store.entries.isEmpty {
                ContentUnavailableView(
                    "No Conversions Yet",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("\(store.storageSummaryTitle). \(store.storageSummaryDescription)")
                )
                .foregroundStyle(Theme.text)
            } else {
                List {
                    Section {
                        historySummaryCard
                        .listRowBackground(Theme.surface)
                    }
                    Section {
                        ForEach(store.entries) { entry in
                            historyRow(entry: entry)
                                .listRowBackground(Theme.surface)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }

            if isClearAllConfirming {
                clearAllConfirmationOverlay
                    .transition(.opacity)
            }

            if let entryPendingDeletion {
                deleteEntryConfirmationOverlay(entry: entryPendingDeletion)
                    .transition(.opacity)
            }
        }
        .navigationTitle("History")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            store = ConversionHistoryStore.shared
            store.refreshForCurrentSettings()
        }
        .animation(.easeInOut(duration: 0.18), value: isClearAllConfirming)
    }

    private var historySummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: store.isEnabled ? "externaldrive.fill" : "hourglass")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.primary)
                    .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 5) {
                    Text(store.storageSummaryTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Text(store.storageSummaryDescription)
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Storage used")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                    Text(MetadataFormatter.bytes(store.totalStorageBytes))
                        .font(.title3.bold())
                        .foregroundStyle(Theme.primary)
                }
                Spacer()
                Button(role: .destructive) {
                    Haptics.warning()
                    isClearAllConfirming = true
                } label: {
                    Text("Clear all")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var clearAllConfirmationOverlay: some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    Haptics.impact(.light)
                    isClearAllConfirming = false
                }

            VStack(spacing: 18) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text("Delete all history?")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.text)

                    Text("This removes all result files shown here. This cannot be undone.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button(role: .destructive) {
                        Haptics.impact(.medium)
                        store.removeAll()
                        isClearAllConfirming = false
                    } label: {
                        Text("Clear all")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.impact(.light)
                        isClearAllConfirming = false
                    } label: {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundStyle(Theme.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 1)
            )
            .padding(24)
        }
    }

    private func deleteEntryConfirmationOverlay(entry: ConversionHistoryEntry) -> some View {
        ZStack {
            Color.black.opacity(0.38)
                .ignoresSafeArea()
                .onTapGesture {
                    Haptics.impact(.light)
                    entryPendingDeletion = nil
                }

            VStack(spacing: 18) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundStyle(.red)

                VStack(spacing: 8) {
                    Text("Delete this item?")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.text)

                    Text(entry.input.originalFilename)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)

                    Text("This removes the result file for this conversion from history.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    Button(role: .destructive) {
                        Haptics.impact(.medium)
                        store.removeEntry(id: entry.id)
                        entryPendingDeletion = nil
                    } label: {
                        Text("Delete item")
                            .font(.headline)
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(.red)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        Haptics.impact(.light)
                        entryPendingDeletion = nil
                    } label: {
                        Text("Cancel")
                            .font(.headline)
                            .foregroundStyle(Theme.primary)
                            .frame(maxWidth: .infinity, minHeight: 48)
                            .background(Theme.surface)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(Theme.accent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(22)
            .frame(maxWidth: 340)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Theme.accent, lineWidth: 1)
            )
            .padding(24)
        }
    }

    @ViewBuilder
    private func historyRow(entry: ConversionHistoryEntry) -> some View {
        HStack(alignment: .center, spacing: 14) {
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
                HStack(alignment: .center, spacing: 14) {
                    MediaPreview(
                        url: entry.result.url,
                        category: entry.result.outputFormat.category,
                        compact: true,
                        showsChrome: false
                    )
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.input.originalFilename)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                            .lineLimit(2)
                        Text(
                            "\(entry.result.outputFormat.displayName) · \(MetadataFormatter.bytes(entry.result.sizeOnDisk))"
                        )
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                        Text(entry.createdAt, format: .dateTime)
                            .font(.caption2)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)

            Button {
                Haptics.warning()
                entryPendingDeletion = entry
            } label: {
                Image(systemName: "trash")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove from history")
        }
    }
}
