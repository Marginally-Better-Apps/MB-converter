import Foundation

/// Temporary storage for imported source files, kept separate from conversion outputs.
enum ImportStorage {
    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        TempStorage.allowAccessWhileLocked(at: dir)
        return dir
    }

    /// A fresh location for an imported file that keeps its name, since that name is what people
    /// see on the settings, result and History screens. Each import gets its own folder.
    static func url(originalName: String?, fallbackExtension: String, kind: String = "File") -> URL {
        let ext = originalName.flatMap { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackExtension
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(displayBaseName(originalName, kind: kind)).\(ext)")
    }

    /// The original name without its extension, or "Photo Oct 24 at 7.23 PM"-style text when the
    /// source only offers a machine-generated name (Photos picker files are often UUIDs).
    static func displayBaseName(_ originalName: String?, kind: String, now: Date = Date()) -> String {
        let base = originalName.map { ($0 as NSString).deletingPathExtension }?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let looksGenerated = base.isEmpty
            || base.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#, options: .regularExpression) != nil
            || base.hasPrefix("version=")
        guard looksGenerated else {
            return base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        }
        let date = now.formatted(.dateTime.month(.abbreviated).day())
        let time = now.formatted(.dateTime.hour().minute()).replacingOccurrences(of: ":", with: ".")
        return "\(kind) \(date) at \(time)"
    }

    /// Copies an imported file into app-owned temporary storage without loading
    /// the file contents into memory. The source URL may only be valid for the
    /// duration of a picker or item-provider callback, so callers must copy it
    /// before returning from that callback.
    static func copyFile(
        at sourceURL: URL,
        originalName: String? = nil,
        fallbackExtension: String = "dat",
        kind: String = "File"
    ) throws -> URL {
        let outputURL = url(
            originalName: originalName ?? sourceURL.lastPathComponent,
            fallbackExtension: fallbackExtension,
            kind: kind
        )

        do {
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
            TempStorage.allowAccessWhileLocked(at: outputURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.copyFailed(error.localizedDescription)
        }
    }

    static func cleanAll() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return }

        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
