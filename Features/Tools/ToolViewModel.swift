import Foundation
import Observation
import PDFKit
import PhotosUI
import SwiftUI

@MainActor
@Observable
final class ToolViewModel {
    let tool: ToolDefinition
    var inputs: [ToolInputFile] = [] {
        didSet { inputsChanged(oldValue: oldValue) }
    }
    var values: ToolOptionValues
    var editorState: ToolEditorState = .none
    var password = ""
    var isRunning = false
    var isImporting = false
    var progress: Double?
    var errorMessage: String?
    private(set) var lockedPDFs: Set<UUID> = []
    private var runTask: Task<ToolRun?, Never>?

    init(tool: ToolDefinition, inputs: [ToolInputFile]) {
        self.tool = tool
        var values = ToolOptionValues(defaults: tool.options)
        if values["pageSize"] != nil { values["pageSize"] = .string(PageSizePreference.current.rawValue) }
        self.values = values
        let accepted = inputs.filter { tool.input.accepts($0.format) }
        self.inputs = Array(accepted.prefix(tool.input.maxCount))
        inputsChanged(oldValue: [])
    }

    // MARK: Derived state

    var visibleOptions: [ToolOption] {
        tool.options.filter { option in
            guard option.isVisible(values) else { return false }
            if case .dynamicChoice(let provider) = option.kind { return !provider(inputs).isEmpty }
            return true
        }
    }

    /// Visible advanced options, folded under "More options".
    var advancedOptions: [ToolOption] {
        visibleOptions.filter(\.isAdvanced)
    }

    /// Visible everyday options grouped by section, in declaration order.
    var optionSections: [(title: String?, options: [ToolOption])] {
        var sections: [(String?, [ToolOption])] = []
        for option in visibleOptions where !option.isAdvanced {
            if let index = sections.firstIndex(where: { $0.0 == option.section }) {
                sections[index].1.append(option)
            } else {
                sections.append((option.section, [option]))
            }
        }
        return sections.map { (title: $0.0, options: $0.1) }
    }

    var needsPassword: Bool {
        !lockedPDFs.isEmpty && tool.id != "pdf.unlock"
    }

    var canAddMore: Bool {
        inputs.count < tool.input.maxCount
    }

    var blockingReason: String? {
        if tool.input.acceptsFiles {
            // A noun like "a video and a song" already says how many.
            let counted = tool.input.noun.contains(" and ")
            if inputs.isEmpty { return "Add \(tool.input.minCount > 1 && !counted ? "at least \(tool.input.minCount) " : "")\(tool.input.noun)" }
            if inputs.count < tool.input.minCount { return counted ? "Add \(tool.input.noun)" : "Add at least \(tool.input.minCount) \(tool.input.noun)" }
        }
        if needsPassword, password.isEmpty { return "Enter the PDF password" }
        return tool.validate?(values, editorState, inputs)
    }

    /// Only files are missing: the action button opens the picker instead of being disabled.
    var isMissingFiles: Bool {
        tool.input.acceptsFiles && inputs.count < tool.input.minCount
    }

    var editorSummary: String {
        switch editorState {
        case .none: return "Not edited yet"
        case .pages(let edits):
            let rotated = edits.filter { $0.rotation % 360 != 0 }.count
            return "\(edits.count) page\(edits.count == 1 ? "" : "s")" + (rotated > 0 ? " · \(rotated) rotated" : "")
        case .overlays(let items):
            let pages = Set(items.map(\.pageIndex)).count
            return items.isEmpty ? "Nothing added yet" : "\(items.count) item\(items.count == 1 ? "" : "s") on \(pages) page\(pages == 1 ? "" : "s")"
        case .crop(let rect):
            return rect == CGRect(x: 0, y: 0, width: 1, height: 1) ? "Full image" : "\(Int((rect.width * 100).rounded()))% × \(Int((rect.height * 100).rounded()))% of original"
        case .range(let start, let end):
            return "\(MetadataFormatter.durationText(start)) – \(MetadataFormatter.durationText(end)) · \(MetadataFormatter.durationText(end - start))"
        case .texts(let overlays):
            let count = overlays.filter { !$0.isEmpty }.count
            return count == 0 ? "No text yet" : "\(count) text box\(count == 1 ? "" : "es")"
        }
    }

    // MARK: Inputs

    private func inputsChanged(oldValue: [ToolInputFile]) {
        lockedPDFs = Set(inputs.filter { $0.format == .pdf && (PDFDocument(url: $0.url)?.isLocked ?? false) }.map(\.id))
        for option in tool.options {
            guard case .dynamicChoice(let provider) = option.kind else { continue }
            let choices = provider(inputs)
            if !choices.contains(where: { $0.value == values.string(option.key) }) {
                values[option.key] = .string(choices.first?.value ?? "")
            }
        }
        if oldValue.map(\.id) != inputs.map(\.id) {
            // Editor edits are tied to a specific file.
            if oldValue.first?.id != inputs.first?.id { editorState = .none }
        }
    }

    func add(_ files: [ToolInputFile]) {
        let accepted = files.filter { tool.input.accepts($0.format) }
        let rejected = files.count - accepted.count
        if tool.input.maxCount == 1, let first = accepted.first {
            inputs = [first]
            Haptics.success()
            if rejected > 0 { errorMessage = "That file type isn't supported by \(tool.title)." }
            return
        }
        let room = tool.input.maxCount - inputs.count
        inputs += accepted.prefix(max(room, 0))
        if rejected > 0 {
            errorMessage = "\(rejected) file\(rejected == 1 ? " isn't" : "s aren't") supported by \(tool.title)."
        } else if accepted.count > room {
            errorMessage = "\(tool.title) accepts up to \(tool.input.maxCount) \(tool.input.noun)."
        }
        if !accepted.isEmpty { Haptics.success() }
    }

    func importURLs(_ urls: [URL]) {
        do {
            add(try urls.map(FileIntake.importFile(at:)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPhotos(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer { isImporting = false }
        do {
            add(try await FileIntake.importPhotos(items))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importPasteboard() {
        do {
            add(try FileIntake.importPasteboard())
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(_ file: ToolInputFile) {
        inputs.removeAll { $0.id == file.id }
    }

    func move(_ file: ToolInputFile, before target: ToolInputFile) {
        guard let from = inputs.firstIndex(of: file), let to = inputs.firstIndex(of: target), from != to else { return }
        var copy = inputs
        let item = copy.remove(at: from)
        copy.insert(item, at: to)
        inputs = copy
    }

    func move(from source: IndexSet, to destination: Int) {
        inputs.move(fromOffsets: source, toOffset: destination)
    }

    // MARK: Run

    func run() async -> ToolRun? {
        guard blockingReason == nil, !isRunning else { return nil }
        isRunning = true
        progress = nil
        errorMessage = nil
        let reporter = ToolProgress { [weak self] fraction, _ in
            Task { @MainActor in self?.progress = fraction }
        }
        let context = ToolContext(inputs: inputs, options: values, editor: editorState, password: password.nilIfBlank, progress: reporter)
        let tool = tool
        let inputs = inputs
        let task = Task<ToolRun?, Never> { @MainActor in
            do {
                let output = try await tool.run(context)
                try Task.checkCancellation()
                Haptics.success()
                let run = ToolRun(toolID: tool.id, inputs: inputs, output: output)
                ConversionHistoryStore.shared.record(run, title: tool.title)
                return run
            } catch is CancellationError {
                return nil
            } catch ConversionError.cancelled {
                return nil
            } catch {
                self.errorMessage = error.localizedDescription
                DiagnosticsLog.shared.record(error: error, context: "Tool: \(tool.title)")
                Haptics.error()
                return nil
            }
        }
        runTask = task
        let result = await task.value
        isRunning = false
        progress = nil
        runTask = nil
        return result
    }

    func cancel() {
        runTask?.cancel()
        isRunning = false
    }
}
