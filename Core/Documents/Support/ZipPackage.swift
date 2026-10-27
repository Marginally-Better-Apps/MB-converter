import Foundation
import ZIPFoundation

/// Read-only view over a ZIP container (DOCX, ODT, EPUB, XLSX, ODS, PPTX).
struct ZipPackageReader {
    private let archive: Archive

    init(url: URL) throws {
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw DocumentError.unreadable("The file isn't a valid package (\(url.pathExtension.uppercased())).")
        }
    }

    init(data: Data) throws {
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw DocumentError.unreadable("The file isn't a valid ZIP package.")
        }
    }

    var entryPaths: [String] {
        archive.map(\.path)
    }

    func contains(_ path: String) -> Bool {
        archive[Self.normalized(path)] != nil
    }

    func data(at path: String) throws -> Data {
        guard let entry = archive[Self.normalized(path)] else {
            throw DocumentError.unreadable("Missing part \(path).")
        }
        var output = Data()
        _ = try archive.extract(entry, skipCRC32: true) { output.append($0) }
        return output
    }

    func dataIfPresent(at path: String) -> Data? {
        try? data(at: path)
    }

    func xml(at path: String) throws -> XElement {
        try XMLDocumentParser.parse(data(at: path))
    }

    func xmlIfPresent(at path: String) -> XElement? {
        guard let data = dataIfPresent(at: path) else { return nil }
        return try? XMLDocumentParser.parse(data)
    }

    /// Resolves `relative` against the directory containing `base` (both package paths), handling `..`.
    static func resolve(_ relative: String, against base: String) -> String {
        if relative.hasPrefix("/") { return normalized(relative) }
        var components = base.split(separator: "/").map(String.init)
        if !components.isEmpty { components.removeLast() }
        for part in relative.split(separator: "/").map(String.init) {
            switch part {
            case ".", "": continue
            case "..": if !components.isEmpty { components.removeLast() }
            default: components.append(part)
            }
        }
        return components.joined(separator: "/")
    }

    static func normalized(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        return decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
    }
}

/// Builds a ZIP container in memory, preserving insertion order.
final class ZipPackageWriter {
    private struct Item {
        let path: String
        let data: Data
        let compressed: Bool
    }

    private var items: [Item] = []

    func add(_ path: String, data: Data, compressed: Bool = true) {
        items.append(Item(path: path, data: data, compressed: compressed))
    }

    func add(_ path: String, string: String, compressed: Bool = true) {
        add(path, data: Data(string.utf8), compressed: compressed)
    }

    func write(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .create)
        } catch {
            throw DocumentError.writeFailed("Couldn't create the output package.")
        }
        for item in items {
            let data = item.data
            try archive.addEntry(
                with: item.path,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: Date(timeIntervalSince1970: 1_700_000_000),
                compressionMethod: item.compressed ? .deflate : .none,
                provider: { position, size in
                    data.subdata(in: Int(position) ..< Int(position) + size)
                }
            )
        }
    }
}
