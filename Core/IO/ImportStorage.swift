import Foundation

/// Temporary storage for imported source files, kept separate from conversion outputs.
enum ImportStorage {
    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("imports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func url(originalName: String?, fallbackExtension: String) -> URL {
        let ext = originalName.flatMap { URL(fileURLWithPath: $0).pathExtension }
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? fallbackExtension
        return directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Copies an imported file into app-owned temporary storage without loading
    /// the file contents into memory. The source URL may only be valid for the
    /// duration of a picker or item-provider callback, so callers must copy it
    /// before returning from that callback.
    static func copyFile(
        at sourceURL: URL,
        originalName: String? = nil,
        fallbackExtension: String = "dat"
    ) throws -> URL {
        let outputURL = url(
            originalName: originalName ?? sourceURL.lastPathComponent,
            fallbackExtension: fallbackExtension
        )

        do {
            try FileManager.default.copyItem(at: sourceURL, to: outputURL)
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
