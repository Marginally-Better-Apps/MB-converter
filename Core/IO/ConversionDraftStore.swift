import Foundation
import Observation

struct ConversionDraft: Codable, Hashable, Identifiable {
    var id: UUID { input.id }
    var sourceFingerprint: String? = nil
    var updatedAt: Date
    var input: MediaFile
    var config: ConversionConfig
}

/// Draft inputs live outside the temporary import directory. Each draft has an
/// atomic record, so a damaged record cannot hide the rest of the user's work.
@MainActor @Observable final class ConversionDraftStore {
    static let shared = ConversionDraftStore()
    private(set) var entries: [ConversionDraft] = []
    private let root: URL
    @ObservationIgnored private var copies: [UUID: Task<URL, Error>] = [:]
    @ObservationIgnored private var copyFingerprints: [UUID: String] = [:]
    @ObservationIgnored private var revisions: [UUID: Int] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ConversionDrafts", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        var localRoot = self.root
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? localRoot.setResourceValues(values)
        let directories = (try? FileManager.default.contentsOfDirectory(at: self.root, includingPropertiesForKeys: nil)) ?? []
        entries = directories.compactMap { directory in
            guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("draft.json")),
                  var draft = try? JSONDecoder().decode(ConversionDraft.self, from: bytes) else { return nil }
            let source = directory.appendingPathComponent("source.\(draft.input.containerFormat)")
            guard FileManager.default.fileExists(atPath: source.path) else { return nil }
            draft.input = draft.input.withURL(source)
            return draft
        }.sorted { $0.updatedAt > $1.updatedAt }
    }

    func save(input: MediaFile, config: ConversionConfig) async throws {
        let revision = (revisions[input.id] ?? 0) + 1
        revisions[input.id] = revision
        let directory = root.appendingPathComponent(input.id.uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent("source.\(input.containerFormat)")
        let attributes = try FileManager.default.attributesOfItem(atPath: input.url.path)
        let fingerprint = "\(input.url.path)|\(attributes[.size] ?? 0)|\(attributes[.modificationDate] ?? Date.distantPast)"
        let previous = copies[input.id]
        let priorFingerprint = entries.first(where: { $0.id == input.id })?.sourceFingerprint
        let reuse = copyFingerprints[input.id] == fingerprint ? previous : nil
        let needsCopy = input.url != destination && priorFingerprint != fingerprint
        let copy = reuse ?? Task.detached(priority: .utility) {
            if let previous { _ = try? await previous.value }
            let files = FileManager.default
            try Task.checkCancellation()
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            if needsCopy || !files.fileExists(atPath: destination.path) {
                let staging = directory.appendingPathComponent(UUID().uuidString + ".partial")
                defer { try? files.removeItem(at: staging) }
                try files.copyItem(at: input.url, to: staging)
                try Task.checkCancellation()
                if files.fileExists(atPath: destination.path) {
                    _ = try files.replaceItemAt(destination, withItemAt: staging)
                } else {
                    try files.moveItem(at: staging, to: destination)
                }
            }
            guard files.fileExists(atPath: destination.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            return destination
        }
        copies[input.id] = copy
        copyFingerprints[input.id] = fingerprint
        do {
            let source = try await copy.value
            guard revisions[input.id] == revision else { return }
            copies[input.id] = nil
            let draft = ConversionDraft(sourceFingerprint: fingerprint, updatedAt: Date(), input: input.withURL(source), config: config)
            try JSONEncoder().encode(draft).write(to: directory.appendingPathComponent("draft.json"), options: .atomic)
            entries.removeAll { $0.id == input.id }
            entries.insert(draft, at: 0)
        } catch {
            if revisions[input.id] == revision { copies[input.id] = nil }
            throw error
        }
    }

    func remove(id: UUID) {
        revisions[id] = (revisions[id] ?? 0) + 1
        copies[id]?.cancel()
        copies[id] = nil
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString))
    }
}
