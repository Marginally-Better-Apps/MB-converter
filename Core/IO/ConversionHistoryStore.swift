import Foundation
import Observation

// MARK: - UserDefaults

enum ConversionHistoryUserDefaults {
    static let isEnabledKey = "conversionHistoryEnabled"
    /// Results are kept unless the user turned that off; an explicit choice is always respected.
    static let defaultIsEnabled = true
    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: isEnabledKey) as? Bool ?? defaultIsEnabled }
        set { UserDefaults.standard.set(newValue, forKey: isEnabledKey) }
    }
}

// MARK: - Store

@MainActor
@Observable
final class ConversionHistoryStore {
    static let shared = ConversionHistoryStore()

    private let fileManager = FileManager.default
    private static var persistentRootDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport.appendingPathComponent("MBConverter/ConversionHistory", isDirectory: true)
    }

    private static var sessionRootDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MBConverter/SessionHistory", isDirectory: true)
    }

    private var rootDirectory: URL {
        Self.persistentRootDirectory
    }

    private var filesDirectory: URL {
        rootDirectory.appendingPathComponent("files", isDirectory: true)
    }

    private var sessionFilesDirectory: URL {
        Self.sessionRootDirectory.appendingPathComponent("files", isDirectory: true)
    }

    private var indexURL: URL {
        rootDirectory.appendingPathComponent("index.json", isDirectory: false)
    }

    private(set) var entries: [ConversionHistoryEntry] = [] {
        didSet { recomputeTotals() }
    }

    /// Finished tool runs (PDF, document, image and utility tools).
    private(set) var toolEntries: [ToolHistoryEntry] = [] {
        didSet { recomputeTotals() }
    }

    /// Conversions and tool runs together, newest first.
    var items: [HistoryItem] {
        (entries.map(HistoryItem.conversion) + toolEntries.map(HistoryItem.tool)).sorted { $0.createdAt > $1.createdAt }
    }

    private(set) var totalStorageBytes: Int64 = 0
    private var persistedEntries: [ConversionHistoryEntry] = []
    private var sessionEntries: [ConversionHistoryEntry] = []
    private var persistedToolEntries: [ToolHistoryEntry] = []
    private var sessionToolEntries: [ToolHistoryEntry] = []

    private var toolsDirectory: URL {
        rootDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    private var sessionToolsDirectory: URL {
        Self.sessionRootDirectory.appendingPathComponent("tools", isDirectory: true)
    }

    private var toolIndexURL: URL {
        rootDirectory.appendingPathComponent("tools.json", isDirectory: false)
    }

    private func recomputeTotals() {
        totalStorageBytes = Self.computeTotalBytes(from: entries) + toolEntries.reduce(0) { $0 + $1.totalBytes }
    }

    private init() {
        do {
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Create saved history directory")
        }
        reloadFromDisk()
        reloadToolsFromDisk()
        refreshForCurrentSettings()
    }

    var isEnabled: Bool {
        ConversionHistoryUserDefaults.isEnabled
    }

    var storageSummaryTitle: String {
        isEnabled ? "Saved history is on" : "Session history only"
    }

    var storageSummaryDescription: String {
        if isEnabled {
            return "Conversions and tool results are copied to this device and stay in History until you delete them."
        }
        return "Conversions and tool results are kept for this app session only. They are removed after you quit and reopen the app."
    }

    static func cleanSessionHistory() {
        try? FileManager.default.removeItem(at: sessionRootDirectory)
    }

    func refreshForCurrentSettings() {
        entries = isEnabled ? persistedEntries : sessionEntries
        toolEntries = isEnabled ? persistedToolEntries : sessionToolEntries
    }

    /// Turns saved history on, keeping this session's results. Returns `false` (and stays off)
    /// if they can't be copied.
    @discardableResult
    func enableSavedHistory() -> Bool {
        guard isEnabled || persistSessionHistory() else { return false }
        ConversionHistoryUserDefaults.isEnabled = true
        refreshForCurrentSettings()
        return true
    }

    /// Copies the current session's history into durable storage before saved history is enabled.
    /// Returns `false` without changing the session if any result cannot be copied or indexed.
    @discardableResult
    func persistSessionHistory() -> Bool {
        guard persistSessionToolHistory() else { return false }
        guard !sessionEntries.isEmpty else { return true }

        do {
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Enable saved conversion history")
            return false
        }

        var staged: [(entry: ConversionHistoryEntry, sessionURL: URL)] = []

        for sessionEntry in sessionEntries {
            let sessionURL = sessionEntry.result.url
            guard fileManager.fileExists(atPath: sessionURL.path) else {
                DiagnosticsLog.shared.record(
                    message: "A session history file no longer exists.",
                    context: "Enable saved conversion history",
                    metadata: ["History entry ID": sessionEntry.id.uuidString]
                )
                removeStagedHistoryFiles(staged)
                return false
            }

            let ext = sessionEntry.result.outputFormat.fileExtension
            let destinationURL = filesDirectory
                .appendingPathComponent("\(sessionEntry.id.uuidString).\(ext)")

            do {
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.copyItem(at: sessionURL, to: destinationURL)
            } catch {
                DiagnosticsLog.shared.record(
                    error: error,
                    context: "Copy session item into saved history",
                    metadata: [
                        "History entry ID": sessionEntry.id.uuidString,
                        "Output format": sessionEntry.result.outputFormat.displayName
                    ]
                )
                removeStagedHistoryFiles(staged)
                return false
            }

            let attrs = (try? fileManager.attributesOfItem(atPath: destinationURL.path)) ?? [:]
            let onDisk = (attrs[.size] as? NSNumber)?.int64Value
                ?? sessionEntry.result.sizeOnDisk
            let result = sessionEntry.result.copy(url: destinationURL, sizeOnDisk: onDisk)
            let promotedEntry = ConversionHistoryEntry(
                id: sessionEntry.id,
                createdAt: sessionEntry.createdAt,
                input: sessionEntry.input,
                config: sessionEntry.config,
                result: result
            )
            staged.append((promotedEntry, sessionURL))
        }

        let previousPersistedEntries = persistedEntries
        let promotedIDs = Set(staged.map { $0.entry.id })
        persistedEntries.removeAll { promotedIDs.contains($0.id) }
        persistedEntries.append(contentsOf: staged.map { $0.entry })
        persistedEntries.sort { $0.createdAt > $1.createdAt }

        guard persistIndex() else {
            persistedEntries = previousPersistedEntries
            removeStagedHistoryFiles(staged)
            return false
        }

        sessionEntries.removeAll { promotedIDs.contains($0.id) }
        for item in staged {
            try? fileManager.removeItem(at: item.sessionURL)
        }
        return true
    }

    /// Deletes all saved (on-disk) history entries and the index. Session-only entries are unchanged.
    func clearPersistedHistory() {
        for entry in persistedEntries {
            try? fileManager.removeItem(at: entry.result.url)
        }
        persistedEntries = []
        persistIndex()
        for entry in persistedToolEntries {
            try? fileManager.removeItem(at: entry.folder)
        }
        persistedToolEntries = []
        persistToolIndex()
    }

    /// Records a successful conversion, either persistently or for the current app session.
    func record(input: MediaFile, config: ConversionConfig, result: ConversionResult) {
        guard fileManager.fileExists(atPath: result.url.path) else { return }

        let savesPersistently = ConversionHistoryUserDefaults.isEnabled
        let id = UUID()
        let ext = result.outputFormat.fileExtension
        let directory = savesPersistently ? filesDirectory : sessionFilesDirectory
        let destURL = directory.appendingPathComponent("\(id.uuidString).\(ext)")

        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destURL.path) {
                try fileManager.removeItem(at: destURL)
            }
            try fileManager.copyItem(at: result.url, to: destURL)
        } catch {
            DiagnosticsLog.shared.record(
                error: error,
                context: "Record conversion in history",
                metadata: [
                    "History mode": savesPersistently ? "saved" : "session",
                    "Output format": result.outputFormat.displayName,
                    "Output bytes": String(result.sizeOnDisk)
                ]
            )
            return
        }

        let attrs = (try? fileManager.attributesOfItem(atPath: destURL.path)) ?? [:]
        let onDisk = (attrs[.size] as? NSNumber)?.int64Value ?? result.sizeOnDisk

        let newResult = ConversionResult(
            id: result.id,
            url: destURL,
            outputFormat: result.outputFormat,
            sizeOnDisk: onDisk,
            dimensions: result.dimensions,
            duration: result.duration,
            fps: result.fps,
            bitrate: result.bitrate,
            audioBitrate: result.audioBitrate,
            videoCodec: result.videoCodec,
            audioCodec: result.audioCodec
        )

        let entry = ConversionHistoryEntry(
            id: id,
            createdAt: Date(),
            input: input,
            config: config,
            result: newResult
        )

        if savesPersistently {
            persistedEntries.insert(entry, at: 0)
            persistIndex()
        } else {
            sessionEntries.insert(entry, at: 0)
        }
        refreshForCurrentSettings()
    }

    func entry(withId id: UUID) -> ConversionHistoryEntry? {
        entries.first { $0.id == id }
    }

    func removeEntry(id: UUID) {
        if toolEntries.contains(where: { $0.id == id }) {
            removeToolEntry(id: id)
            refreshForCurrentSettings()
            return
        }
        if isEnabled {
            removePersistedEntry(id: id)
        } else {
            removeSessionEntry(id: id)
        }
        refreshForCurrentSettings()
    }

    func removeAll() {
        if isEnabled {
            for entry in persistedEntries {
                try? fileManager.removeItem(at: entry.result.url)
            }
            persistedEntries = []
            persistIndex()
            for entry in persistedToolEntries {
                try? fileManager.removeItem(at: entry.folder)
            }
            persistedToolEntries = []
            persistToolIndex()
        } else {
            for entry in sessionEntries {
                try? fileManager.removeItem(at: entry.result.url)
            }
            sessionEntries = []
            for entry in sessionToolEntries {
                try? fileManager.removeItem(at: entry.folder)
            }
            sessionToolEntries = []
        }
        refreshForCurrentSettings()
    }

    // MARK: Tool runs

    /// Copies a finished tool run's outputs into history (saved or session-only, like conversions).
    /// The entry shares the run's ID so later renames on the result screen can follow it.
    func record(_ run: ToolRun, title: String) {
        let sources = run.output.files.map(\.url).filter { fileManager.fileExists(atPath: $0.path) }
        guard !sources.isEmpty || run.output.text?.nilIfBlank != nil else { return }
        guard !toolEntries.contains(where: { $0.id == run.id }) else { return }
        let savesPersistently = isEnabled
        let folder = (savesPersistently ? toolsDirectory : sessionToolsDirectory)
            .appendingPathComponent(run.id.uuidString, isDirectory: true)
        var copies: [URL] = []
        do {
            try? fileManager.removeItem(at: folder)
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
            for source in sources {
                let destination = ToolStorage.uniqueURL(in: folder, baseName: source.deletingPathExtension().lastPathComponent, ext: source.pathExtension)
                // APFS clones the file, so this costs no extra space until either copy changes.
                try fileManager.copyItem(at: source, to: destination)
                copies.append(destination)
            }
        } catch {
            try? fileManager.removeItem(at: folder)
            DiagnosticsLog.shared.record(error: error, context: "Record tool run in history", metadata: ["Tool": run.toolID.rawValue])
            return
        }
        let entry = ToolHistoryEntry(
            id: run.id,
            createdAt: Date(),
            toolID: run.toolID,
            title: title,
            inputNames: run.inputs.map(\.displayName),
            files: copies,
            summary: run.output.summary,
            text: run.output.text
        )
        if savesPersistently {
            persistedToolEntries.insert(entry, at: 0)
            persistToolIndex()
        } else {
            sessionToolEntries.insert(entry, at: 0)
        }
        refreshForCurrentSettings()
    }

    func toolEntry(withId id: UUID) -> ToolHistoryEntry? {
        toolEntries.first { $0.id == id }
    }

    /// Keeps history in step when a result file is renamed on the result screen.
    func renameToolOutput(runID: UUID, from oldName: String, to newName: String) {
        func rename(_ list: inout [ToolHistoryEntry]) -> Bool {
            guard let index = list.firstIndex(where: { $0.id == runID }),
                  let fileIndex = list[index].files.firstIndex(where: { $0.lastPathComponent == oldName })
            else { return false }
            let current = list[index].files[fileIndex]
            let target = list[index].folder.appendingPathComponent(newName)
            if current != target, fileManager.fileExists(atPath: current.path), !fileManager.fileExists(atPath: target.path) {
                do { try fileManager.moveItem(at: current, to: target) } catch { return false }
            }
            guard fileManager.fileExists(atPath: target.path) else { return false }
            list[index].files[fileIndex] = target
            return true
        }
        if rename(&persistedToolEntries) { persistToolIndex() } else { _ = rename(&sessionToolEntries) }
        refreshForCurrentSettings()
    }

    private func removeToolEntry(id: UUID) {
        if let index = persistedToolEntries.firstIndex(where: { $0.id == id }) {
            try? fileManager.removeItem(at: persistedToolEntries[index].folder)
            persistedToolEntries.remove(at: index)
            persistToolIndex()
        } else if let index = sessionToolEntries.firstIndex(where: { $0.id == id }) {
            try? fileManager.removeItem(at: sessionToolEntries[index].folder)
            sessionToolEntries.remove(at: index)
        }
    }

    /// Moves this session's tool runs into saved history. All-or-nothing.
    private func persistSessionToolHistory() -> Bool {
        guard !sessionToolEntries.isEmpty else { return true }
        var promoted: [ToolHistoryEntry] = []
        do {
            try fileManager.createDirectory(at: toolsDirectory, withIntermediateDirectories: true)
            for entry in sessionToolEntries {
                let destination = toolsDirectory.appendingPathComponent(entry.id.uuidString, isDirectory: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: entry.folder, to: destination)
                var moved = entry
                moved.files = entry.files.map { destination.appendingPathComponent($0.lastPathComponent) }
                promoted.append(moved)
            }
        } catch {
            for entry in promoted { try? fileManager.removeItem(at: entry.folder) }
            DiagnosticsLog.shared.record(error: error, context: "Enable saved tool history")
            return false
        }
        let previous = persistedToolEntries
        persistedToolEntries = (persistedToolEntries + promoted).sorted { $0.createdAt > $1.createdAt }
        guard persistToolIndex() else {
            persistedToolEntries = previous
            for entry in promoted { try? fileManager.removeItem(at: entry.folder) }
            return false
        }
        for entry in sessionToolEntries { try? fileManager.removeItem(at: entry.folder) }
        sessionToolEntries = []
        return true
    }

    @discardableResult
    private func persistToolIndex() -> Bool {
        let records = persistedToolEntries.map(PersistedToolEntry.init)
        do {
            try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(records).write(to: toolIndexURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Write saved tool history index", metadata: ["Entry count": String(records.count)])
            return false
        }
    }

    private func reloadToolsFromDisk() {
        guard let data = try? Data(contentsOf: toolIndexURL) else {
            persistedToolEntries = []
            return
        }
        do {
            let records = try JSONDecoder().decode([PersistedToolEntry].self, from: data)
            let loaded = records.compactMap { $0.entry(in: toolsDirectory) }
            persistedToolEntries = loaded
            if loaded.count != records.count { persistToolIndex() }
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Load saved tool history index")
            persistedToolEntries = []
        }
    }

    private func removePersistedEntry(id: UUID) {
        guard let index = persistedEntries.firstIndex(where: { $0.id == id }) else { return }
        let url = persistedEntries[index].result.url
        try? fileManager.removeItem(at: url)
        persistedEntries.remove(at: index)
        persistIndex()
    }

    private func removeSessionEntry(id: UUID) {
        guard let index = sessionEntries.firstIndex(where: { $0.id == id }) else { return }
        let url = sessionEntries[index].result.url
        try? fileManager.removeItem(at: url)
        sessionEntries.remove(at: index)
    }

    @discardableResult
    private func persistIndex() -> Bool {
        let records = persistedEntries.map { PersistedEntry(entry: $0) }
        do {
            let data = try JSONEncoder().encode(PersistedIndex(entries: records))
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            DiagnosticsLog.shared.record(
                error: error,
                context: "Write saved history index",
                metadata: ["Entry count": String(records.count)]
            )
            return false
        }
    }

    private func removeStagedHistoryFiles(
        _ staged: [(entry: ConversionHistoryEntry, sessionURL: URL)]
    ) {
        for item in staged {
            try? fileManager.removeItem(at: item.entry.result.url)
        }
    }

    private func reloadFromDisk() {
        guard fileManager.fileExists(atPath: indexURL.path) else {
            persistedEntries = []
            return
        }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode(PersistedIndex.self, from: data)
            let loaded: [ConversionHistoryEntry] = decoded.entries.compactMap { persist in
                let url = filesDirectory.appendingPathComponent(persist.storedFileName)
                guard fileManager.fileExists(atPath: url.path) else { return nil }
                return persist.toEntry(storedFileURL: url)
            }
            if loaded.count != decoded.entries.count {
                persistedEntries = loaded
                persistIndex()
            } else {
                persistedEntries = loaded
            }
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Load saved history index")
            persistedEntries = []
        }
    }

    private static func computeTotalBytes(from entries: [ConversionHistoryEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.result.sizeOnDisk }
    }
}

private extension ConversionResult {
    func copy(url: URL, sizeOnDisk: Int64) -> ConversionResult {
        ConversionResult(
            id: id,
            url: url,
            outputFormat: outputFormat,
            sizeOnDisk: sizeOnDisk,
            dimensions: dimensions,
            duration: duration,
            fps: fps,
            bitrate: bitrate,
            audioBitrate: audioBitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec
        )
    }
}

// MARK: - Runtime model

/// One row in History: a media conversion or a tool run.
enum HistoryItem: Identifiable, Hashable {
    case conversion(ConversionHistoryEntry)
    case tool(ToolHistoryEntry)

    var id: UUID {
        switch self {
        case .conversion(let entry): entry.id
        case .tool(let entry): entry.id
        }
    }

    var createdAt: Date {
        switch self {
        case .conversion(let entry): entry.createdAt
        case .tool(let entry): entry.createdAt
        }
    }
}

struct ToolHistoryEntry: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let toolID: ToolID
    let title: String
    let inputNames: [String]
    var files: [URL]
    let summary: String?
    let text: String?

    /// Every output lives in its own folder named after the entry.
    var folder: URL {
        files.first?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("MBConverter/SessionHistory/tools/\(id.uuidString)", isDirectory: true)
    }

    var totalBytes: Int64 {
        files.reduce(0) { total, url in
            total + ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0)
        }
    }

    /// Reopens the result screen for this entry.
    var run: ToolRun {
        ToolRun(id: id, toolID: toolID, inputs: [], output: ToolOutput(files: files, summary: summary, text: text), fromHistory: true)
    }
}

private struct PersistedToolEntry: Codable {
    var id: UUID
    var createdAt: Date
    var toolID: String
    var title: String
    var inputNames: [String]
    var fileNames: [String]
    var summary: String?
    var text: String?

    init(_ entry: ToolHistoryEntry) {
        id = entry.id
        createdAt = entry.createdAt
        toolID = entry.toolID.rawValue
        title = entry.title
        inputNames = entry.inputNames
        fileNames = entry.files.map(\.lastPathComponent)
        summary = entry.summary
        text = entry.text
    }

    func entry(in directory: URL) -> ToolHistoryEntry? {
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        let files = fileNames.map { folder.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty || text?.nilIfBlank != nil else { return nil }
        return ToolHistoryEntry(id: id, createdAt: createdAt, toolID: ToolID(rawValue: toolID), title: title, inputNames: inputNames, files: files, summary: summary, text: text)
    }
}

struct ConversionHistoryEntry: Identifiable, Hashable {
    let id: UUID
    let createdAt: Date
    let input: MediaFile
    let config: ConversionConfig
    let result: ConversionResult
}

// MARK: - Codable on-disk

private struct PersistedIndex: Codable {
    var entries: [PersistedEntry]
}

private struct PersistedEntry: Codable {
    var id: UUID
    var createdAt: Date
    var storedFileName: String
    var input: PersistedMediaFile
    var config: PersistedConversionConfig
    var result: PersistedConversionResult
}

private struct PersistedMediaFile: Codable, Hashable {
    var id: UUID
    var urlPath: String
    var originalFilename: String
    var category: MediaCategory
    var sizeOnDisk: Int64
    var width: Double?
    var height: Double?
    var duration: TimeInterval?
    var fps: Double?
    var bitrate: Int?
    var audioBitrate: Int?
    var videoCodec: String?
    var audioCodec: String?
    var containerFormat: String
}

private struct PersistedConversionConfig: Codable, Hashable {
    var outputFormat: OutputFormat
    var targetWidth: Double?
    var targetHeight: Double?
    var targetFPS: Double?
    var targetSizeBytes: Int64?
    var cropX: Double?
    var cropY: Double?
    var cropWidth: Double?
    var cropHeight: Double?
    var mediaRotation: MediaRotation?
    var isMirrored: Bool?
    var imageQuality: Double?
    var videoQuality: Double?
    var usesSinglePassVideoTargetEncode: Bool?
    var frameTimeForExtraction: Double?
    var preferredAudioBitrateKbps: Int?
    var operationMode: OutputOperationMode
    var autoTargetLockPolicy: AutoTargetLockPolicy
    var prefersRemuxWhenPossible: Bool
}

private struct PersistedConversionResult: Codable, Hashable {
    var resultId: UUID
    var outputFormat: OutputFormat
    var sizeOnDisk: Int64
    var width: Double?
    var height: Double?
    var duration: TimeInterval?
    var fps: Double?
    var bitrate: Int?
    var audioBitrate: Int?
    var videoCodec: String?
    var audioCodec: String?
}

private extension PersistedEntry {
    init(entry: ConversionHistoryEntry) {
        self.id = entry.id
        self.createdAt = entry.createdAt
        self.storedFileName = entry.result.url.lastPathComponent
        self.input = PersistedMediaFile(file: entry.input)
        self.config = PersistedConversionConfig(config: entry.config)
        self.result = PersistedConversionResult(result: entry.result)
    }

    func toEntry(storedFileURL: URL) -> ConversionHistoryEntry {
        let result = self.result.toConversionResult(url: storedFileURL)
        let config = self.config.toConversionConfig()
        let input = self.input.toMediaFile()
        return ConversionHistoryEntry(
            id: id,
            createdAt: createdAt,
            input: input,
            config: config,
            result: result
        )
    }
}

private extension PersistedMediaFile {
    init(file: MediaFile) {
        self.id = file.id
        self.urlPath = file.url.path
        self.originalFilename = file.originalFilename
        self.category = file.category
        self.sizeOnDisk = file.sizeOnDisk
        if let d = file.dimensions {
            self.width = d.width
            self.height = d.height
        } else {
            self.width = nil
            self.height = nil
        }
        self.duration = file.duration
        self.fps = file.fps
        self.bitrate = file.bitrate
        self.audioBitrate = file.audioBitrate
        self.videoCodec = file.videoCodec
        self.audioCodec = file.audioCodec
        self.containerFormat = file.containerFormat
    }

    func toMediaFile() -> MediaFile {
        let url = URL(fileURLWithPath: urlPath)
        let dim: CGSize?
        if let w = width, let h = height {
            dim = CGSize(width: w, height: h)
        } else {
            dim = nil
        }
        return MediaFile(
            id: id,
            url: url,
            originalFilename: originalFilename,
            category: category,
            sizeOnDisk: sizeOnDisk,
            dimensions: dim,
            duration: duration,
            fps: fps,
            bitrate: bitrate,
            audioBitrate: audioBitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec,
            containerFormat: containerFormat
        )
    }
}

private extension PersistedConversionConfig {
    init(config: ConversionConfig) {
        self.outputFormat = config.outputFormat
        if let d = config.targetDimensions {
            self.targetWidth = d.width
            self.targetHeight = d.height
        } else {
            self.targetWidth = nil
            self.targetHeight = nil
        }
        self.targetFPS = config.targetFPS
        self.targetSizeBytes = config.targetSizeBytes
        self.cropX = config.cropRegion?.x
        self.cropY = config.cropRegion?.y
        self.cropWidth = config.cropRegion?.width
        self.cropHeight = config.cropRegion?.height
        self.mediaRotation = config.mediaRotation
        self.isMirrored = config.isMirrored
        self.imageQuality = config.imageQuality
        self.videoQuality = config.videoQuality
        self.usesSinglePassVideoTargetEncode = config.usesSinglePassVideoTargetEncode
        self.frameTimeForExtraction = config.frameTimeForExtraction
        self.preferredAudioBitrateKbps = config.preferredAudioBitrateKbps
        self.operationMode = config.operationMode
        self.autoTargetLockPolicy = config.autoTargetLockPolicy
        self.prefersRemuxWhenPossible = config.prefersRemuxWhenPossible
    }

    func toConversionConfig() -> ConversionConfig {
        let dim: CGSize?
        if let w = targetWidth, let h = targetHeight {
            dim = CGSize(width: w, height: h)
        } else {
            dim = nil
        }
        let crop: CropRegion?
        if let x = cropX, let y = cropY, let width = cropWidth, let height = cropHeight {
            crop = CropRegion(x: x, y: y, width: width, height: height)
        } else {
            crop = nil
        }
        return ConversionConfig(
            outputFormat: outputFormat,
            targetDimensions: dim,
            targetFPS: targetFPS,
            targetSizeBytes: targetSizeBytes,
            cropRegion: crop,
            mediaRotation: mediaRotation ?? .none,
            isMirrored: isMirrored ?? false,
            imageQuality: imageQuality,
            videoQuality: videoQuality,
            usesSinglePassVideoTargetEncode: usesSinglePassVideoTargetEncode ?? false,
            frameTimeForExtraction: frameTimeForExtraction,
            preferredAudioBitrateKbps: preferredAudioBitrateKbps,
            operationMode: operationMode,
            autoTargetLockPolicy: autoTargetLockPolicy,
            prefersRemuxWhenPossible: prefersRemuxWhenPossible,
            metadata: .default
        )
    }
}

private extension PersistedConversionResult {
    init(result: ConversionResult) {
        self.resultId = result.id
        self.outputFormat = result.outputFormat
        self.sizeOnDisk = result.sizeOnDisk
        if let d = result.dimensions {
            self.width = d.width
            self.height = d.height
        } else {
            self.width = nil
            self.height = nil
        }
        self.duration = result.duration
        self.fps = result.fps
        self.bitrate = result.bitrate
        self.audioBitrate = result.audioBitrate
        self.videoCodec = result.videoCodec
        self.audioCodec = result.audioCodec
    }

    func toConversionResult(url: URL) -> ConversionResult {
        let dim: CGSize?
        if let w = width, let h = height {
            dim = CGSize(width: w, height: h)
        } else {
            dim = nil
        }
        return ConversionResult(
            id: resultId,
            url: url,
            outputFormat: outputFormat,
            sizeOnDisk: sizeOnDisk,
            dimensions: dim,
            duration: duration,
            fps: fps,
            bitrate: bitrate,
            audioBitrate: audioBitrate,
            videoCodec: videoCodec,
            audioCodec: audioCodec
        )
    }
}
