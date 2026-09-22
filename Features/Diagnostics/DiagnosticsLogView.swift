import SwiftUI
import UIKit

struct DiagnosticsLogView: View {
    @State private var entries: [DiagnosticsLogEntry] = []
    @State private var report = ""
    @State private var isExportPresented = false
    @State private var exportError: String?
    @State private var didCopyAll = false

    private var errors: [DiagnosticsLogEntry] {
        entries.filter { $0.level == .error }
    }

    var body: some View {
        Group {
            if errors.isEmpty {
                ContentUnavailableView {
                    Label("No Errors Recorded", systemImage: "checkmark.circle")
                } description: {
                    Text("Conversion and app failures will appear here automatically.")
                }
            } else {
                List {
                    Section {
                        overviewRow
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))

                    ForEach(groupedErrors) { group in
                        Section(group.day.formatted(date: .complete, time: .omitted)) {
                            ForEach(group.entries) { entry in
                                NavigationLink {
                                    DiagnosticsLogDetailView(entry: entry)
                                } label: {
                                    DiagnosticsLogRow(entry: entry)
                                }
                            }
                        }
                        .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                    }

                    Section {
                        Text(
                            "Reports may contain filenames, conversion settings, and selected metadata. "
                            + "Review technical details before sharing."
                        )
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                    }
                    .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            if !errors.isEmpty {
                actionBar
            }
        }
        .navigationTitle("Error Log")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $isExportPresented,
            document: DiagnosticsLogDocument(text: report),
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result, !Self.isUserCancelled(error) {
                DiagnosticsLog.shared.record(error: error, context: "Export diagnostic report")
                refresh()
                exportError = error.localizedDescription
                Haptics.error()
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {
                exportError = nil
            }
        } message: {
            Text(exportError ?? "The diagnostic report could not be exported.")
        }
        .onAppear {
            refresh()
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                copyAll()
            } label: {
                Label(didCopyAll ? "Copied" : "Copy All", systemImage: didCopyAll ? "checkmark" : "doc.on.doc")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .appleGlassButton()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Theme.tint)
            .accessibilityHint("Copies the complete diagnostic report to the clipboard.")

            Button {
                Haptics.impact(.light)
                refresh()
                isExportPresented = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .appleGlassButton()
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .tint(Theme.tint)
            .accessibilityHint("Exports the complete diagnostic report as a text file.")
        }
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var overviewRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(Theme.destructive)
                .frame(width: 38, height: 38)
                .background(Theme.destructive.opacity(0.12), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("\(errors.count) \(errors.count == 1 ? "Error" : "Errors") Recorded")
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                if let latest = errors.first?.timestamp {
                    Text("Latest: \(latest.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var groupedErrors: [DiagnosticsDayGroup] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: errors) { entry in
            calendar.startOfDay(for: entry.timestamp)
        }
        return grouped
            .map { DiagnosticsDayGroup(day: $0.key, entries: $0.value.sorted { $0.timestamp > $1.timestamp }) }
            .sorted { $0.day > $1.day }
    }

    private func refresh() {
        entries = DiagnosticsLog.shared.entries()
        report = DiagnosticsLog.shared.report()
    }

    private func copyAll() {
        Haptics.impact(.light)
        refresh()
        UIPasteboard.general.string = report
        didCopyAll = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopyAll = false
        }
    }

    private var exportFilename: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "MB-Converter-Diagnostics-\(formatter.string(from: Date()))"
    }

    private static func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}

private struct DiagnosticsDayGroup: Identifiable {
    let day: Date
    let entries: [DiagnosticsLogEntry]

    var id: Date { day }
}

private struct DiagnosticsLogRow: View {
    let entry: DiagnosticsLogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Theme.destructive)
                .padding(.top, 2)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(entry.context)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }

                Text(entry.message)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(3)

                if let errorDomain = entry.errorDomain, let errorCode = entry.errorCode {
                    Text("\(errorDomain) · \(errorCode)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(1)
                } else if let returnCode = entry.metadata["Return code"] {
                    Text("FFmpeg return code \(returnCode)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(Theme.textMuted)
                }
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the complete error details.")
    }
}

private struct DiagnosticsLogDetailView: View {
    let entry: DiagnosticsLogEntry

    @State private var showsTechnicalDetails = false
    @State private var showsCallStack = false
    @State private var didCopy = false

    var body: some View {
        Form {
            Section("Error") {
                Text(entry.context)
                    .font(.headline)
                    .foregroundStyle(Theme.text)
                Text(entry.message)
                    .foregroundStyle(Theme.text)
                    .textSelection(.enabled)
                LabeledContent("Occurred") {
                    Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                        .foregroundStyle(Theme.textMuted)
                }
            }
            .listRowBackground(Theme.surface)

            if entry.errorType != nil || entry.errorDomain != nil || entry.errorCode != nil {
                Section("Classification") {
                    if let errorType = entry.errorType {
                        diagnosticValue("Type", errorType)
                    }
                    if let errorDomain = entry.errorDomain {
                        diagnosticValue("Domain", errorDomain)
                    }
                    if let errorCode = entry.errorCode {
                        diagnosticValue("Code", String(errorCode))
                    }
                }
                .listRowBackground(Theme.surface)
            }

            if !entry.metadata.isEmpty {
                Section("Conversion Context") {
                    ForEach(entry.metadata.keys.sorted(), id: \.self) { key in
                        diagnosticValue(key, entry.metadata[key] ?? "")
                    }
                }
                .listRowBackground(Theme.surface)
            }

            Section("Source") {
                diagnosticValue("File", entry.sourceFile)
                diagnosticValue("Function", entry.sourceFunction)
                diagnosticValue("Line", String(entry.sourceLine))
                diagnosticValue("Thread", entry.thread)
                diagnosticValue("Session", entry.sessionID)
            }
            .listRowBackground(Theme.surface)

            if let details = entry.details, !details.isEmpty {
                Section {
                    DisclosureGroup("Technical Details", isExpanded: $showsTechnicalDetails) {
                        Text(details)
                            .font(.caption.monospaced())
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                }
                .listRowBackground(Theme.surface)
            }

            if !entry.callStack.isEmpty {
                Section {
                    DisclosureGroup("Call Stack", isExpanded: $showsCallStack) {
                        Text(entry.callStack.joined(separator: "\n"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.text)
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Error Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Haptics.impact(.light)
                    UIPasteboard.general.string = entry.formattedText
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        didCopy = false
                    }
                } label: {
                    Label(didCopy ? "Copied" : "Copy", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .accessibilityHint("Copies this error and all of its technical details.")
            }
        }
    }

    @ViewBuilder
    private func diagnosticValue(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(Theme.text)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }
}
