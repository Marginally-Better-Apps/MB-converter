import Foundation
import Observation

// MARK: - UserDefaults

enum ConversionHistoryUserDefaults {
    static let isEnabledKey = "conversionHistoryEnabled"
    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: isEnabledKey) }
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
        didSet { totalStorageBytes = Self.computeTotalBytes(from: entries) }
    }

    private(set) var totalStorageBytes: Int64 = 0
    private var persistedEntries: [ConversionHistoryEntry] = []
    private var sessionEntries: [ConversionHistoryEntry] = []

    private init() {
        do {
            try fileManager.createDirectory(at: filesDirectory, withIntermediateDirectories: true)
        } catch {
            print("[HISTORY] Could not create history directory: \(error)")
        }
        reloadFromDisk()
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
            return "New conversions are copied to this device and stay in History until you delete them."
        }
        return "New conversions are kept for this app session only. They are removed after you quit and reopen the app."
    }

    static func cleanSessionHistory() {
        try? FileManager.default.removeItem(at: sessionRootDirectory)
    }

    func refreshForCurrentSettings() {
        entries = isEnabled ? persistedEntries : sessionEntries
    }

    /// Deletes all saved (on-disk) history entries and the index. Session-only entries are unchanged.
    func clearPersistedHistory() {
        for entry in persistedEntries {
            try? fileManager.removeItem(at: entry.result.url)
        }
        persistedEntries = []
        persistIndex()
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
            print("[HISTORY] Copy failed: \(error)")
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
        } else {
            for entry in sessionEntries {
                try? fileManager.removeItem(at: entry.result.url)
            }
            sessionEntries = []
        }
        refreshForCurrentSettings()
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

    private func persistIndex() {
        let records = persistedEntries.map { PersistedEntry(entry: $0) }
        do {
            let data = try JSONEncoder().encode(PersistedIndex(entries: records))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            print("[HISTORY] Persist index failed: \(error)")
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
            print("[HISTORY] Load index failed: \(error)")
            persistedEntries = []
        }
    }

    private static func computeTotalBytes(from entries: [ConversionHistoryEntry]) -> Int64 {
        entries.reduce(0) { $0 + $1.result.sizeOnDisk }
    }
}

// MARK: - Runtime model

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
