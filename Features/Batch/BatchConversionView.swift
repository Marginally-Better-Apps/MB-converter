import SwiftUI
import UIKit

@MainActor @Observable final class BatchConversionModel {
    let inputs: [MediaFile]
    var selectedFormat: OutputFormat
    let formats: [OutputFormat]
    private(set) var outputs: [ConversionResult] = []
    private(set) var errors: [UUID: String] = [:]
    private(set) var progress: Double = 0
    private(set) var isRunning = false
    private(set) var finished = false
    private(set) var currentName = ""
    @ObservationIgnored private var worker: Task<Void, Never>?
    @ObservationIgnored private var converter: Converter?
    @ObservationIgnored private var backgroundID: UIBackgroundTaskIdentifier = .invalid

    init(inputs: [MediaFile]) {
        self.inputs = inputs
        formats = (inputs.first.map { FormatMatrix.allowedOutputs(for: $0.category) } ?? []).filter { format in
            inputs.allSatisfy { FormatMatrix.allowedOutputs(for: $0.category).contains(format) }
        }
        selectedFormat = formats.first ?? .zip
    }

    func start(merge: Bool = false) {
        guard !isRunning else { return }
        isRunning = true; finished = false; outputs = []; errors = [:]; progress = 0
        backgroundID = UIApplication.shared.beginBackgroundTask(withName: "Batch conversion") { [weak self] in
            Task { @MainActor in self?.cancel() }
        }
        let format = selectedFormat
        worker = Task {
            defer {
                converter = nil; isRunning = false; finished = true
                if backgroundID != .invalid { UIApplication.shared.endBackgroundTask(backgroundID); backgroundID = .invalid }
            }
            // Every input is recoverable before any encoder starts.
            for input in inputs {
                do { try await ConversionDraftStore.shared.save(input: input, config: .init(outputFormat: merge ? .pdf : format)) }
                catch { errors[input.id] = "Couldn't save draft: \(error.localizedDescription)" }
            }
            if merge {
                guard errors.isEmpty, let first = inputs.first else { return }
                currentName = "Merging PDFs"
                let merger = DocumentConverter(); converter = merger
                do {
                    let urls = inputs.map(\.url)
                    let task = Task.detached(priority: .userInitiated) {
                        try merger.mergePDFs(urls, progress: { [weak self] value in Task { @MainActor in self?.progress = value } })
                    }
                    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { merger.cancel(); task.cancel() }
                    if Task.isCancelled { try? FileManager.default.removeItem(at: result.url); throw CancellationError() }
                    outputs = [result]; progress = 1
                    ConversionHistoryStore.shared.record(input: first, config: .init(outputFormat: .pdf), result: result)
                    inputs.forEach { ConversionDraftStore.shared.remove(id: $0.id) }
                } catch { errors[first.id] = error.localizedDescription }
                return
            }
            for (index, input) in inputs.enumerated() {
                if Task.isCancelled { break }
                guard errors[input.id] == nil else { continue }
                currentName = input.originalFilename
                let config = ConversionConfig(outputFormat: format)
                do {
                    let engine = try ConversionRouter.converter(for: input, config: config); converter = engine
                    let task = Task.detached(priority: .userInitiated) {
                        try await engine.convert(input: input, config: config, progress: { [weak self] value in
                            Task { @MainActor in self?.progress = (Double(index) + value) / Double(max(1, self?.inputs.count ?? 1)) }
                        }, encodingStats: nil)
                    }
                    let result = try await withTaskCancellationHandler { try await task.value } onCancel: { engine.cancel(); task.cancel() }
                    if Task.isCancelled { try? FileManager.default.removeItem(at: result.url); throw CancellationError() }
                    outputs.append(result)
                    ConversionHistoryStore.shared.record(input: input, config: config, result: result)
                    ConversionDraftStore.shared.remove(id: input.id)
                } catch { errors[input.id] = error.localizedDescription }
                converter = nil
            }
            if !Task.isCancelled { progress = 1 }
        }
    }
    func checkpoint() async {
        guard !isRunning, !finished else { return }
        let format = selectedFormat
        for input in inputs {
            do { try await ConversionDraftStore.shared.save(input: input, config: .init(outputFormat: format)) }
            catch { errors[input.id] = "Couldn't save draft: \(error.localizedDescription)" }
        }
    }
    func cancel() { worker?.cancel(); converter?.cancel() }
}

struct BatchConversionView: View {
    @State private var model: BatchConversionModel
    init(inputs: [MediaFile]) { _model = State(initialValue: BatchConversionModel(inputs: inputs)) }
    var body: some View {
        @Bindable var model = model
        List {
            Section {
                HStack {
                    Text("Format")
                    Spacer()
                    FormatPicker(formats: model.formats, inputCategory: model.inputs.first?.category ?? .file, selection: $model.selectedFormat)
                }.disabled(model.isRunning)
                if model.isRunning {
                    ProgressView(value: model.progress)
                    Text(model.currentName).font(.caption).lineLimit(1)
                    Button("Cancel", role: .destructive) { model.cancel() }
                } else {
                    Button(model.finished ? "Convert Again" : "Convert All") { model.start() }
                    if model.inputs.count > 1 && model.inputs.allSatisfy({ $0.containerFormat == "pdf" }) {
                        Button("Merge PDFs") { model.start(merge: true) }
                    }
                }
                if !model.outputs.isEmpty {
                    ShareLink(items: model.outputs.map(\.url)) { Label("Share \(model.outputs.count) files", systemImage: "square.and.arrow.up") }
                }
            }
            Section("\(model.inputs.count) files") {
                ForEach(model.inputs) { input in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(input.originalFilename).lineLimit(1)
                        if let error = model.errors[input.id] { Text(error).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .navigationTitle("Batch")
        .navigationBarTitleDisplayMode(.inline)
        .tint(Theme.tint)
        .task(id: model.selectedFormat) { await model.checkpoint() }
        .onDisappear { model.cancel() }
    }
}
