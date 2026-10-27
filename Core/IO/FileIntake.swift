import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Imports files for the tools layer, keeping original filenames so outputs read naturally
/// ("Report-compressed.pdf", not "4F2A….pdf").
enum FileIntake {
    static let maxBytes: Int64 = 1_024 * 1_024 * 1_024

    static var directory: URL {
        ImportStorage.directory.appendingPathComponent("tools", isDirectory: true)
    }

    private static func freshFolder() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func importFile(at source: URL) throws -> ToolInputFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        guard let format = FileFormat(url: source) ?? sniffFormat(source) else {
            throw DocumentError.unsupportedFormat(source.pathExtension.isEmpty ? source.lastPathComponent : ".\(source.pathExtension.lowercased())")
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? Int64) ?? 0
        guard size <= maxBytes else { throw ImportError.fileTooLarge(limitBytes: maxBytes) }
        let name = source.pathExtension.isEmpty ? "\(source.lastPathComponent).\(format.fileExtension)" : source.lastPathComponent
        let destination = try freshFolder().appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        return try ToolInputFile(url: destination, displayName: name, format: format)
    }

    static func importData(_ data: Data, suggestedName: String) throws -> ToolInputFile {
        let destination = try freshFolder().appendingPathComponent(ToolStorage.sanitize(suggestedName))
        try data.write(to: destination)
        return try ToolInputFile(url: destination)
    }

    /// Content sniffing for extensionless files (e.g. shared from other apps).
    static func sniffFormat(_ url: URL) -> FileFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 16)) ?? Data()
        if head.starts(with: Array("%PDF".utf8)) { return .pdf }
        if let mime = ImageBlock.sniffMimeType(head) {
            return FileFormat(fileExtension: ImageBlock(data: Data(), mimeType: mime).fileExtension)
        }
        if head.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        return nil
    }

    // MARK: Photos

    struct PickedMovie: Transferable {
        let url: URL

        static var transferRepresentation: some TransferRepresentation {
            FileRepresentation(contentType: .movie) { movie in
                SentTransferredFile(movie.url)
            } importing: { received in
                let folder = FileIntake.directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let destination = folder.appendingPathComponent(received.file.lastPathComponent)
                try FileManager.default.copyItem(at: received.file, to: destination)
                return PickedMovie(url: destination)
            }
        }
    }

    static func importPhotos(_ items: [PhotosPickerItem]) async throws -> [ToolInputFile] {
        var files: [ToolInputFile] = []
        for (index, item) in items.enumerated() {
            let type = item.supportedContentTypes.first
            if type?.conforms(to: .movie) == true {
                guard let movie = try await item.loadTransferable(type: PickedMovie.self) else { continue }
                files.append(try ToolInputFile(url: movie.url))
                continue
            }
            guard let data = try await item.loadTransferable(type: Data.self) else { continue }
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let name = items.count == 1 ? "Photo.\(ext)" : "Photo \(index + 1).\(ext)"
            files.append(try importData(data, suggestedName: name))
        }
        guard !files.isEmpty else { throw ImportError.unsupportedType }
        return files
    }

    // MARK: Pasteboard

    /// Short description of importable pasteboard content, or nil.
    static func pasteboardSummary() -> String? {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasURLs, pasteboard.urls?.contains(where: \.isFileURL) == true { return "File" }
        if pasteboard.hasImages { return pasteboard.numberOfItems > 1 ? "Images" : "Image" }
        if pasteboard.types.contains(where: { UTType($0)?.conforms(to: .pdf) == true }) { return "PDF" }
        return nil
    }

    static func importPasteboard() throws -> [ToolInputFile] {
        let pasteboard = UIPasteboard.general
        var files: [ToolInputFile] = []
        for url in pasteboard.urls ?? [] where url.isFileURL {
            if let file = try? importFile(at: url) { files.append(file) }
        }
        if files.isEmpty {
            // A PDF or Office file copied as data, named after its source when the provider says.
            for type in pasteboard.types {
                guard let format = documentFormat(forPasteboardType: type),
                      let data = pasteboard.data(forPasteboardType: type), !data.isEmpty else { continue }
                let base = pasteboard.itemProviders.first?.suggestedName.map { ($0 as NSString).deletingPathExtension } ?? ""
                files.append(try importData(data, suggestedName: "\(base.isEmpty ? "Pasted" : base).\(format.fileExtension)"))
                break
            }
        }
        if files.isEmpty {
            for (index, item) in pasteboard.items.enumerated() {
                for (type, value) in item {
                    guard let utType = UTType(type), utType.conforms(to: .image), let data = value as? Data ?? (value as? UIImage)?.pngData() else { continue }
                    let ext = utType.preferredFilenameExtension ?? "png"
                    files.append(try importData(data, suggestedName: pasteboard.items.count > 1 ? "Pasted \(index + 1).\(ext)" : "Pasted.\(ext)"))
                    break
                }
            }
        }
        if files.isEmpty, let images = pasteboard.images {
            for (index, image) in images.enumerated() {
                guard let data = image.pngData() else { continue }
                files.append(try importData(data, suggestedName: images.count > 1 ? "Pasted \(index + 1).png" : "Pasted.png"))
            }
        }
        guard !files.isEmpty else { throw ImportError.noSupportedMediaInPasteboard }
        return files
    }

    /// Documents that arrive on the clipboard as files, not as text to paste into a field.
    static let pasteboardDocumentFormats: [FileFormat] = [.pdf, .docx, .odt, .epub, .xlsx, .ods, .pptx, .zip]

    /// The kind of document on the clipboard (a copied PDF, Word file, PSD…), or nil.
    /// Photos, videos and audio are left to the media importer; copied text isn't a document.
    static func pasteboardDocumentFormat(_ pasteboard: UIPasteboard = .general) -> FileFormat? {
        if pasteboard.hasURLs {
            for url in pasteboard.urls ?? [] where url.isFileURL {
                if let format = FileFormat(url: url), !opensInMediaConverter(format) { return format }
            }
        }
        return pasteboard.types.lazy.compactMap(documentFormat(forPasteboardType:)).first
    }

    static func documentFormat(forPasteboardType identifier: String) -> FileFormat? {
        guard let type = UTType(identifier) else { return nil }
        // Formats without a registered type fall back to `.data`, which everything conforms to.
        return pasteboardDocumentFormats.first { $0.utType != .data && type.conforms(to: $0.utType) }
    }

    // MARK: Routing

    /// Media formats open the full-featured media converter rather than the file hub.
    static func opensInMediaConverter(_ format: FileFormat) -> Bool {
        switch format.family {
        case .video, .audio: true
        // Formats ImageIO decodes go to the full converter; the rest (PSD layers, TGA, PCX,
        // QOI, DDS, JPEG 2000…) open the file hub, where ImageMagick-backed tools handle them.
        case .image: [.jpeg, .png, .heic, .webp, .tiff, .gif, .bmp, .avif].contains(format)
        default: false
        }
    }

    /// Every type the "Open a file" picker accepts.
    static var allContentTypes: [UTType] {
        var types: [UTType] = [.image, .movie, .audio, .pdf, .plainText, .rtf, .html, .commaSeparatedText, .tabSeparatedText, .json, .xml, .zip, .epub, .svg]
        types += FileFormat.allCases.map(\.utType)
        return Array(Set(types)).filter { $0 != .data }
    }
}
