import Foundation
@main struct DraftPersistenceTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let inputURL = root.appendingPathComponent("source.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("Keep this draft".utf8).write(to: inputURL)
        let input = MediaFile(url: inputURL, originalFilename: "source.txt", category: .document, sizeOnDisk: 15, containerFormat: "txt")
        var config = ConversionConfig(outputFormat: .docx, cropRegion: CropRegion(x: 2, y: 4, width: 30, height: 40), mediaRotation: .clockwise90, audioEdits: AudioEditSettings(volume: 0.5, speed: 1.25))
        config.metadata.stripAll = false
        config.metadata.retainedFormatTags = ["author": "Draft author"]
        config.document.pages = "1-3"
        let store = ConversionDraftStore(root: root.appendingPathComponent("drafts"))
        try await store.save(input: input, config: config)
        try FileManager.default.removeItem(at: inputURL)
        let reopened = ConversionDraftStore(root: root.appendingPathComponent("drafts"))
        guard let draft = reopened.entries.first else { fatalError("Draft must survive relaunch and removal of temporary imports") }
        precondition(draft.config == config, "All edits and metadata must round trip")
        let contents = try String(contentsOf: draft.input.url, encoding: .utf8)
        precondition(contents == "Keep this draft")
        var changed = config; changed.outputFormat = .pdf
        try await reopened.save(input: draft.input, config: changed)
        let newest = ConversionDraftStore(root: root.appendingPathComponent("drafts"))
        precondition(newest.entries.count == 1 && newest.entries[0].config == changed, "Autosave updates one draft")
        let replacement = root.appendingPathComponent("trimmed.txt")
        try Data("Changed source".utf8).write(to: replacement)
        try await newest.save(input: draft.input.withURL(replacement), config: changed)
        let replaced = ConversionDraftStore(root: root.appendingPathComponent("drafts"))
        let changedText = try String(contentsOf: replaced.entries[0].input.url, encoding: .utf8)
        precondition(changedText == "Changed source", "Trimmed input must replace the draft source")
        newest.remove(id: input.id)
        precondition(ConversionDraftStore(root: root.appendingPathComponent("drafts")).entries.isEmpty, "Deleted drafts stay deleted")
        print("Draft persistence passed")
    }
}
