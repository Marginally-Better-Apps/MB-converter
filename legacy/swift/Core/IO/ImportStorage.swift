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
