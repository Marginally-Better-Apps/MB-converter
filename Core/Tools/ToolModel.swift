import CoreGraphics
import Foundation
import UniformTypeIdentifiers

// MARK: - Identity & categories

struct ToolID: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    let rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { self.rawValue = value }
    var description: String { rawValue }
}

enum ToolCategory: String, CaseIterable, Identifiable, Hashable, Codable, Sendable {
    case pdf, documents, spreadsheets, images, video, audio, utilities

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .documents: "Documents"
        case .spreadsheets: "Spreadsheets & Data"
        case .images: "Images"
        case .video: "Video"
        case .audio: "Audio"
        case .utilities: "Utilities"
        }
    }

    var shortTitle: String {
        switch self {
        case .spreadsheets: "Data"
        default: title
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .documents: "doc.text"
        case .spreadsheets: "tablecells"
        case .images: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .utilities: "wrench.and.screwdriver"
        }
    }

    var summary: String {
        switch self {
        case .pdf: "Merge, split, compress, sign and secure PDFs"
        case .documents: "Word, OpenDocument, Markdown, EPUB and more"
        case .spreadsheets: "Excel, CSV, JSON and XML conversions"
        case .images: "Convert, resize, crop and retouch photos"
        case .video: "Trim, compress, rotate and make GIFs"
        case .audio: "Trim, convert, fade and join audio"
        case .utilities: "QR codes, ZIP archives and web pages"
        }
    }
}

// MARK: - Inputs

struct ToolInputFile: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let displayName: String
    let format: FileFormat
    let byteCount: Int64

    init(id: UUID = UUID(), url: URL, displayName: String? = nil, format: FileFormat? = nil) throws {
        guard let resolved = format ?? FileFormat(url: url) else {
            throw DocumentError.unsupportedFormat(url.pathExtension.isEmpty ? url.lastPathComponent : ".\(url.pathExtension)")
        }
        self.id = id
        self.url = url
        self.displayName = displayName ?? url.lastPathComponent
        self.format = resolved
        self.byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    var baseName: String {
        let name = (displayName as NSString).deletingPathExtension
        return name.isEmpty ? "file" : name
    }
}

struct InputSpec: Hashable, Sendable {
    var formats: Set<FileFormat>
    var minCount: Int
    var maxCount: Int
    /// Noun for the picker, e.g. "PDFs" or "images".
    var noun: String

    static func one(_ formats: Set<FileFormat>, noun: String) -> InputSpec {
        InputSpec(formats: formats, minCount: 1, maxCount: 1, noun: noun)
    }

    static func many(_ formats: Set<FileFormat>, noun: String, min: Int = 1, max: Int = 50) -> InputSpec {
        InputSpec(formats: formats, minCount: min, maxCount: max, noun: noun)
    }

    static let none = InputSpec(formats: [], minCount: 0, maxCount: 0, noun: "")

    var acceptsFiles: Bool { maxCount > 0 }
    var allowsMultiple: Bool { maxCount > 1 }

    var contentTypes: [UTType] {
        if formats.contains(.zip) && formats.count == 1 { return [.zip] }
        var types = formats.map(\.utType)
        if formats.contains(where: { $0.family == .image }) { types.append(.image) }
        if formats.contains(where: { $0.family == .video }) { types.append(.movie) }
        if formats.contains(where: { $0.family == .audio }) { types.append(.audio) }
        return Array(Set(types))
    }

    func accepts(_ format: FileFormat) -> Bool { formats.contains(format) }
}

// MARK: - Options

enum OptionValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case number(Double)
    case data(Data?)
}

struct ToolChoice: Hashable, Identifiable, Sendable {
    let value: String
    let label: String
    var id: String { value }

    init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

struct ToolOption: Identifiable, @unchecked Sendable {
    enum Kind {
        case choice([ToolChoice], segmented: Bool)
        /// Choices that depend on the selected inputs (e.g. conversion targets).
        case dynamicChoice(([ToolInputFile]) -> [ToolChoice])
        case toggle
        case slider(ClosedRange<Double>, step: Double, format: (Double) -> String)
        case stepper(ClosedRange<Int>, suffix: String)
        case text(placeholder: String, secure: Bool, multiline: Bool, keyboard: TextKeyboard)
        case color
        case image
    }

    enum TextKeyboard: Sendable {
        case standard, url, number
    }

    let key: String
    let label: String
    let kind: Kind
    let defaultValue: OptionValue
    var footnote: String?
    var section: String?
    var isVisible: (ToolOptionValues) -> Bool = { _ in true }
    /// Settings most people never need (output format, quality, dpi…): folded under "More options".
    var isAdvanced = false

    var id: String { key }

    /// The same option, folded under "More options".
    func advanced() -> ToolOption {
        var copy = self
        copy.isAdvanced = true
        return copy
    }

    static func choice(_ key: String, _ label: String, _ choices: [ToolChoice], default value: String? = nil, segmented: Bool = false, section: String? = nil, footnote: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .choice(choices, segmented: segmented), defaultValue: .string(value ?? choices.first?.value ?? ""), footnote: footnote, section: section, isVisible: visible)
    }

    static func toggle(_ key: String, _ label: String, default value: Bool = false, section: String? = nil, footnote: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .toggle, defaultValue: .bool(value), footnote: footnote, section: section, isVisible: visible)
    }

    static func slider(_ key: String, _ label: String, range: ClosedRange<Double>, step: Double = 1, default value: Double, section: String? = nil, footnote: String? = nil, format: @escaping (Double) -> String = { "\(Int($0))" }, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .slider(range, step: step, format: format), defaultValue: .number(value), footnote: footnote, section: section, isVisible: visible)
    }

    static func stepper(_ key: String, _ label: String, range: ClosedRange<Int>, default value: Int, suffix: String = "", section: String? = nil, footnote: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .stepper(range, suffix: suffix), defaultValue: .number(Double(value)), footnote: footnote, section: section, isVisible: visible)
    }

    static func text(_ key: String, _ label: String, placeholder: String = "", default value: String = "", secure: Bool = false, multiline: Bool = false, keyboard: TextKeyboard = .standard, section: String? = nil, footnote: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .text(placeholder: placeholder, secure: secure, multiline: multiline, keyboard: keyboard), defaultValue: .string(value), footnote: footnote, section: section, isVisible: visible)
    }

    static func color(_ key: String, _ label: String, default hex: UInt32, section: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .color, defaultValue: .number(Double(hex)), section: section, isVisible: visible)
    }

    static func image(_ key: String, _ label: String, section: String? = nil, footnote: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }) -> ToolOption {
        ToolOption(key: key, label: label, kind: .image, defaultValue: .data(nil), footnote: footnote, section: section, isVisible: visible)
    }

    /// Choices computed from the inputs. Hidden while the provider returns no choices.
    static func dynamicChoice(_ key: String, _ label: String, section: String? = nil, footnote: String? = nil, visible: @escaping (ToolOptionValues) -> Bool = { _ in true }, choices: @escaping ([ToolInputFile]) -> [ToolChoice]) -> ToolOption {
        ToolOption(key: key, label: label, kind: .dynamicChoice(choices), defaultValue: .string(""), footnote: footnote, section: section, isVisible: visible)
    }
}

struct ToolOptionValues: Hashable, Sendable {
    var storage: [String: OptionValue] = [:]

    init(defaults options: [ToolOption]) {
        for option in options { storage[option.key] = option.defaultValue }
    }

    init(_ storage: [String: OptionValue] = [:]) {
        self.storage = storage
    }

    subscript(key: String) -> OptionValue? {
        get { storage[key] }
        set { storage[key] = newValue }
    }

    func string(_ key: String) -> String {
        switch storage[key] {
        case .string(let value): value
        case .number(let value): CellValue.format(value)
        case .bool(let value): value ? "true" : "false"
        default: ""
        }
    }

    func bool(_ key: String) -> Bool {
        if case .bool(let value) = storage[key] { return value }
        return false
    }

    func double(_ key: String) -> Double {
        switch storage[key] {
        case .number(let value): value
        case .string(let value): Double(value) ?? 0
        default: 0
        }
    }

    func int(_ key: String) -> Int { Int(double(key).rounded()) }

    func hex(_ key: String) -> UInt32 { UInt32(clamping: Int(double(key))) }

    func data(_ key: String) -> Data? {
        if case .data(let value) = storage[key] { return value }
        return nil
    }

    func choice<T: RawRepresentable>(_ key: String, as type: T.Type, default fallback: T) -> T where T.RawValue == String {
        T(rawValue: string(key)) ?? fallback
    }
}

// MARK: - Editors & context

enum ToolEditorKind: Hashable, Sendable {
    /// Reorder, rotate, delete, duplicate and insert pages.
    case pageOrganizer
    /// Place text, signatures, shapes, highlights and redactions on pages.
    case pdfMarkup(signatureFirst: Bool)
    /// Pick a crop rectangle (with aspect presets) on an image.
    case imageCrop
    /// Choose a start/end range on a video or audio timeline.
    case mediaRange
    /// Text boxes placed, typed and styled directly on an image (memes, captions, watermarks).
    case textOverlay(TextOverlay.Preset)
}

enum ToolEditorState: Hashable, Sendable {
    case none
    case pages([PDFToolkit.PageEdit])
    case overlays([PDFOverlayItem])
    case crop(CGRect)
    case range(start: Double, end: Double)
    case texts([TextOverlay])

    var pageEdits: [PDFToolkit.PageEdit]? { if case .pages(let edits) = self { edits } else { nil } }
    var overlays: [PDFOverlayItem] { if case .overlays(let items) = self { items } else { [] } }
    var cropRect: CGRect? { if case .crop(let rect) = self { rect } else { nil } }
    var range: (start: Double, end: Double)? { if case .range(let start, let end) = self { (start, end) } else { nil } }
    var textOverlays: [TextOverlay]? { if case .texts(let overlays) = self { overlays } else { nil } }
}

final class ToolProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let handler: @Sendable (Double, String?) -> Void

    init(_ handler: @escaping @Sendable (Double, String?) -> Void = { _, _ in }) {
        self.handler = handler
    }

    func report(_ fraction: Double, _ message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        handler(min(max(fraction, 0), 1), message)
    }
}

struct ToolContext: Sendable {
    var inputs: [ToolInputFile]
    var options: ToolOptionValues
    var editor: ToolEditorState
    /// Password for encrypted PDF inputs.
    var password: String?
    var progress: ToolProgress
    let outputDirectory: URL

    init(inputs: [ToolInputFile], options: ToolOptionValues, editor: ToolEditorState = .none, password: String? = nil, progress: ToolProgress = ToolProgress(), outputDirectory: URL = ToolStorage.newRunDirectory()) {
        self.inputs = inputs
        self.options = options
        self.editor = editor
        self.password = password
        self.progress = progress
        self.outputDirectory = outputDirectory
    }

    var first: ToolInputFile {
        get throws {
            guard let first = inputs.first else { throw DocumentError.invalidOption("Add a file to continue.") }
            return first
        }
    }

    /// A unique, human-readable output path inside this run's folder.
    func outputURL(_ baseName: String, _ ext: String) -> URL {
        ToolStorage.uniqueURL(in: outputDirectory, baseName: baseName, ext: ext)
    }
}

// MARK: - Output

struct ToolOutputFile: Identifiable, Hashable, Sendable {
    var id: URL { url }
    let url: URL

    var name: String { url.lastPathComponent }
    var format: FileFormat? { FileFormat(url: url) }
    var byteCount: Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0 }
}

struct ToolOutput: Hashable, Sendable {
    var files: [ToolOutputFile]
    /// One-line summary shown on the result screen, e.g. "Saved 62% (4.1 MB → 1.6 MB)".
    var summary: String?
    /// Recognized/extracted text the user may want to copy directly.
    var text: String?

    init(files: [URL], summary: String? = nil, text: String? = nil) {
        self.files = files.map { ToolOutputFile(url: $0) }
        self.summary = summary
        self.text = text
    }

    var totalBytes: Int64 { files.map(\.byteCount).reduce(0, +) }
}

typealias ToolRunner = @MainActor @Sendable (ToolContext) async throws -> ToolOutput

struct ToolDefinition: Identifiable, @unchecked Sendable {
    let id: ToolID
    let title: String
    let summary: String
    let symbol: String
    let category: ToolCategory
    let input: InputSpec
    var options: [ToolOption] = []
    var editor: ToolEditorKind?
    var keywords: [String] = []
    /// Shown in "Popular" on the home screen.
    var isFeatured = false
    /// Hands off to the existing media conversion screen rather than running here.
    var opensMediaConverter = false
    var actionTitle = "Export"
    /// Why the tool can't run yet with these settings ("Choose pages to delete"), shown on the action
    /// button instead of failing after the tap. nil = ready.
    var validate: (@Sendable (ToolOptionValues, ToolEditorState, [ToolInputFile]) -> String?)?
    let run: ToolRunner

    /// Picking the file is the only decision: no editor, nothing to set, one file. Runs right away
    /// when a file is picked on the tool's screen.
    var runsOnPick: Bool {
        editor == nil && !opensMediaConverter && input.maxCount == 1 && input.acceptsFiles && options.allSatisfy(\.isAdvanced)
    }

    func matches(_ query: String) -> Bool {
        let tokens = query.lowercased().split(separator: " ").map(String.init)
        guard !tokens.isEmpty else { return true }
        let haystack = ([title, summary, category.title] + keywords).joined(separator: " ").lowercased()
        return tokens.allSatisfy { haystack.contains($0) }
    }
}

// MARK: - Storage

enum ToolStorage {
    static var root: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tool-output", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func newRunDirectory() -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func uniqueURL(in directory: URL, baseName: String, ext: String) -> URL {
        let safe = sanitize(baseName)
        var candidate = directory.appendingPathComponent(ext.isEmpty ? safe : "\(safe).\(ext)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(ext.isEmpty ? "\(safe) \(counter)" : "\(safe) \(counter).\(ext)")
            counter += 1
        }
        return candidate
    }

    static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r\t")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = String(cleaned.prefix(120))
        return trimmed.isEmpty || trimmed.hasPrefix(".") ? "file" + trimmed : trimmed
    }

    static func cleanAll() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Bundles outputs into a single ZIP for sharing.
    static func zip(_ files: [URL], named name: String, in directory: URL) throws -> URL {
        let writer = ZipPackageWriter()
        var used: Set<String> = []
        for file in files {
            var entry = file.lastPathComponent
            var counter = 2
            while used.contains(entry) {
                entry = "\((file.lastPathComponent as NSString).deletingPathExtension) \(counter).\(file.pathExtension)"
                counter += 1
            }
            used.insert(entry)
            writer.add(entry, data: try Data(contentsOf: file))
        }
        let url = uniqueURL(in: directory, baseName: name, ext: "zip")
        try writer.write(to: url)
        return url
    }
}

extension Int64 {
    var formattedBytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}

/// Runs CPU-heavy work off the main actor.
/// Runs blocking work (Vision, ImageMagick, PDF rendering, FFmpeg) on a GCD worker thread.
/// It must not occupy Swift's cooperative pool: that pool has one thread per core, and frameworks
/// that use Swift concurrency internally (Vision) deadlock once every pool thread is blocked.
func background<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(with: Result { try work() })
        }
    }
}

/// The user's preferred page size for document exports (Settings).
enum PageSizePreference {
    static let key = "defaultPageSize"

    static var current: PageSize {
        UserDefaults.standard.string(forKey: key).flatMap(PageSize.init(rawValue:)) ?? .regionalDefault
    }
}
