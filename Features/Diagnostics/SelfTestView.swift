#if SELF_TEST
import SwiftUI

/// Settings → Diagnostics → Self-Test (development builds only). Runs every tool and the focused
/// end-to-end checks on this device with bundled real files, and validates each output.
struct SelfTestView: View {
    @State private var runner = SelfTestRunner()
    @State private var shareReport = false

    var body: some View {
        List {
            Section {
                summary
                    .listRowBackground(Color.clear)
            } footer: {
                Text("Runs every tool and the conversion engine on bundled sample files, then opens each result and checks it. Results that need real hardware (face detection, background removal, hardware encoders) only pass on a device.")
            }

            ForEach(SelfTestCase.Group.allCases, id: \.self) { group in
                let cases = runner.cases.filter { $0.group == group }
                if !cases.isEmpty {
                    Section(group.rawValue) {
                        ForEach(cases) { testCase in
                            NavigationLink {
                                SelfTestDetailView(testCase: testCase, result: runner.result(for: testCase.id))
                            } label: {
                                SelfTestRow(title: testCase.title, result: runner.result(for: testCase.id))
                            }
                            .accessibilityIdentifier("selftest.case.\(testCase.id)")
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Self-Test")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    shareReport = true
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(runner.completedCount == 0)
                .accessibilityLabel("Share report")
            }
        }
        .sheet(isPresented: $shareReport) {
            ActivityView(items: [runner.reportText]).presentationDetents([.medium, .large])
        }
        .onDisappear { if !runner.isRunning { SelfTestFixtures.cleanUp() } }
    }

    private var summary: some View {
        VStack(spacing: 16) {
            ZStack {
                ProgressRing(progress: runner.isRunning || runner.completedCount > 0 ? runner.progress : 0, lineWidth: 10)
                    .frame(width: 96, height: 96)
                VStack(spacing: 0) {
                    Text("\(runner.completedCount)")
                        .font(.title2.weight(.semibold).monospacedDigit())
                    Text("of \(runner.cases.count)")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                }
            }
            HStack(spacing: 18) {
                count(runner.passedCount, "passed", Theme.success)
                count(runner.failedCount, "failed", Theme.destructive)
                count(runner.skippedCount, "skipped", Theme.textMuted)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(runner.passedCount) passed, \(runner.failedCount) failed, \(runner.skippedCount) skipped")
            .accessibilityIdentifier(runner.finishedAt != nil ? "selftest.finished" : "selftest.summary")

            Button {
                Haptics.impact(.medium)
                if runner.isRunning { runner.cancel() } else { runner.start() }
            } label: {
                Label(runner.isRunning ? "Stop" : (runner.completedCount > 0 ? "Run Again" : "Run All Checks"),
                      systemImage: runner.isRunning ? "stop.fill" : "play.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(runner.isRunning ? Theme.destructive : Theme.tint)
            .accessibilityIdentifier("selftest.run")

            if !runner.isRunning, runner.failedCount > 0 {
                Button("Run Failed Checks Again") {
                    let failed = Set(runner.cases.map(\.id).filter {
                        if case .failed = runner.result(for: $0).status { true } else { false }
                    })
                    runner.start(only: failed)
                }
                .font(.subheadline.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func count(_ value: Int, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(Theme.textMuted)
        }
    }
}

private struct SelfTestRow: View {
    let title: String
    let result: SelfTestResult

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline).foregroundStyle(Theme.text)
                if let detail { Text(detail).font(.caption).foregroundStyle(detailColor).lineLimit(2) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var icon: some View {
        switch result.status {
        case .pending: Image(systemName: "circle").foregroundStyle(Theme.textTertiary)
        case .running: ProgressView()
        case .passed: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.success)
        case .failed: Image(systemName: "xmark.octagon.fill").foregroundStyle(Theme.destructive)
        case .skipped: Image(systemName: "minus.circle").foregroundStyle(Theme.textMuted)
        }
    }

    private var detail: String? {
        let time = String(format: "%.1fs", result.duration)
        switch result.status {
        case .pending, .running: return nil
        case .passed(let note): return [time, note].compactMap { $0 }.joined(separator: " · ")
        case .failed(let problems): return problems.first
        case .skipped(let reason): return reason
        }
    }

    private var detailColor: Color {
        if case .failed = result.status { return Theme.destructive }
        return Theme.textMuted
    }
}

private struct SelfTestDetailView: View {
    let testCase: SelfTestCase
    let result: SelfTestResult
    @State private var preview: IdentifiableURLs?

    var body: some View {
        List {
            Section("Result") {
                switch result.status {
                case .pending: Text("Not run yet")
                case .running: HStack { ProgressView(); Text("Running…") }
                case .passed(let note): Label(note ?? "Passed", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                case .failed(let problems):
                    ForEach(problems, id: \.self) { problem in
                        Label(problem, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.destructive)
                            .textSelection(.enabled)
                    }
                case .skipped(let reason): Label(reason, systemImage: "minus.circle").foregroundStyle(Theme.textMuted)
                }
                if result.status.isFinished {
                    LabeledContent("Time", value: String(format: "%.2f s", result.duration))
                }
            }
            let existing = result.outputs.filter { FileManager.default.fileExists(atPath: $0.path) }
            if !existing.isEmpty {
                Section("Outputs") {
                    ForEach(Array(existing.enumerated()), id: \.offset) { index, url in
                        Button {
                            preview = IdentifiableURLs(urls: existing, index: index)
                        } label: {
                            HStack(spacing: 12) {
                                FileThumbnail(url: url, size: CGSize(width: 40, height: 40), format: FileFormat(url: url))
                                Text(url.lastPathComponent).font(.subheadline).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(testCase.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $preview) { item in
            QuickLookPreview(urls: item.urls, initialIndex: item.index).ignoresSafeArea()
        }
    }
}
#endif
