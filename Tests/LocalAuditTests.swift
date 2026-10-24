import Foundation
import PDFKit
import Testing
@testable import Converter

/// Runs real-world files through the tools and writes every output to a folder for manual review.
/// Off by default; enable with `TEST_RUNNER_MB_AUDIT_INPUTS=/dir/with/files TEST_RUNNER_MB_AUDIT_OUTPUT=/out xcodebuild test …`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MB_AUDIT_INPUTS"] != nil))
@MainActor
struct LocalAuditTests {
    static var inputDirectory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MB_AUDIT_INPUTS"] ?? "/tmp") }
    static var outputDirectory: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["MB_AUDIT_OUTPUT"] ?? "/tmp/mbaudit-out") }
    static var onlyTools: Set<String>? {
        ProcessInfo.processInfo.environment["MB_AUDIT_TOOLS"].map { Set($0.split(separator: ",").map(String.init)) }
    }

    @Test func runEveryApplicableTool() async throws {
        let files = try FileManager.default.contentsOfDirectory(at: Self.inputDirectory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var report: [String] = []
        for file in files {
            let input = try FileIntake.importFile(at: file)
            for tool in ToolCatalog.all where tool.input.accepts(input.format) && tool.input.minCount <= 1 && !tool.opensMediaConverter {
                if let only = Self.onlyTools, !only.contains(tool.id.rawValue) { continue }
                let folder = Self.outputDirectory
                    .appendingPathComponent(file.deletingPathExtension().lastPathComponent, isDirectory: true)
                    .appendingPathComponent(tool.id.rawValue, isDirectory: true)
                try? FileManager.default.removeItem(at: folder)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var options = ToolOptionValues(defaults: tool.options)
                for option in tool.options {
                    if case .dynamicChoice(let provider) = option.kind { options[option.key] = .string(provider([input]).first?.value ?? "") }
                }
                for (key, value) in ToolRunTests.overrides[tool.id.rawValue] ?? [:] { options[key] = value }
                let editor: ToolEditorState = switch tool.editor {
                case .pdfMarkup: .overlays([PDFOverlayItem(pageIndex: 0, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05), kind: .text("Approved", fontSize: 14, colorHex: 0, bold: true))])
                case .imageCrop: .crop(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
                case .mediaRange: .range(start: 0.5, end: 2.5)
                default: .none
                }
                let context = ToolContext(inputs: [input], options: options, editor: editor)
                let started = Date()
                do {
                    let output = try await tool.run(context)
                    var problems: [String] = []
                    var expectations = OutputValidator.Expectations()
                    expectations.text = output.files.count == 1 ? ToolRunTests.textMarkers(for: [input]) : []
                    for item in output.files {
                        try? FileManager.default.copyItem(at: item.url, to: folder.appendingPathComponent(item.name))
                        problems += await OutputValidator.problems(in: item.url, expecting: expectations)
                    }
                    if let text = output.text { try text.write(to: folder.appendingPathComponent("_text.txt"), atomically: true, encoding: .utf8) }
                    let status = problems.isEmpty ? "OK   " : "CHECK"
                    report.append("\(status) \(file.lastPathComponent) · \(tool.id.rawValue) · \(output.files.count) file(s) · \(String(format: "%.1fs", Date().timeIntervalSince(started))) · \(output.summary ?? "")" + problems.map { "\n        ↳ \($0)" }.joined())
                } catch {
                    report.append("FAIL  \(file.lastPathComponent) · \(tool.id.rawValue) · \(error.localizedDescription)")
                }
            }
        }
        try report.joined(separator: "\n").write(to: Self.outputDirectory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
    }
}
