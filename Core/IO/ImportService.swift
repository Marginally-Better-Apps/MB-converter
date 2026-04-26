import Foundation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct RemoteDownloadProgress: Equatable {
    let bytesReceived: Int64
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(bytesReceived) / Double(totalBytes), 1)
    }

    /// Value for a determinate `ProgressView` when the server omits a total size: monotonic in `bytesReceived`, capped so completion can set the bar near full in the last update.
    var displayFraction: Double {
        if let t = totalBytes, t > 0 {
            return min(1, Double(bytesReceived) / Double(t))
        }
        // No Content-Length (chunked, etc.): show a monotonic 0...<1 curve vs the import cap so the bar still advances.
        let b = max(0, Double(bytesReceived))
        let cap = Double(ImportService.maxImportBytes)
        guard cap > 0 else { return 0 }
        return min(0.99, log(1 + b) / log(1 + cap))
    }
}

struct ImportService {
    /// Maximum size for any single import (bytes).
    static let maxImportBytes: Int64 = 150 * 1024 * 1024

    private static let mimeToExtension: [String: String] = [
        "video/mp4": "mp4",
        "video/x-m4v": "m4v",
        "video/quicktime": "mov",
        "video/webm": "webm",
        "video/x-matroska": "mkv",
        "video/ogg": "ogv",
        "video/3gpp": "3gp",
        "video/mpeg": "mpeg",
        "video/x-msvideo": "avi",
        "video/x-flv": "flv",
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/aac": "aac",
        "audio/flac": "flac",
        "audio/ogg": "ogg",
        "audio/opus": "opus",
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/gif": "gif",
        "image/webp": "webp",
        "image/heic": "heic",
        "image/heif": "heic",
        "image/tiff": "tiff",
        "image/avif": "avif"
    ]

    private struct PasteboardImageType {
        let identifier: String
        let fileExtension: String
        let displayName: String
    }

    private struct PasteboardImageRepresentation {
        let data: Data
        let fileExtension: String
        let displayName: String
    }

    private struct PasteboardBinaryMediaRepresentation {
        let data: Data
        let fileExtension: String
        let displayName: String
        let typeIdentifier: String
    }

    private static let pasteboardImageTypeOverrides: [String: (fileExtension: String, displayName: String)] = {
        var overrides: [String: (fileExtension: String, displayName: String)] = [:]
        overrides[UTType.heic.identifier] = ("heic", "HEIC")
        overrides[UTType.heif.identifier] = ("heif", "HEIF")
        overrides[UTType.jpeg.identifier] = ("jpg", "JPEG")
        overrides[UTType.png.identifier] = ("png", "PNG")
        overrides[UTType.gif.identifier] = ("gif", "GIF")
        overrides[UTType.webP.identifier] = ("webp", "WebP")
        overrides[UTType.tiff.identifier] = ("tiff", "TIFF")
        overrides[UTType.bmp.identifier] = ("bmp", "BMP")
        overrides["com.microsoft.bmp"] = ("bmp", "BMP")
        return overrides
    }()

    /// `nil` when the pasteboard advertises no importable media. This intentionally avoids reading item data until the user taps Paste.
    func pasteboardImportLabel() -> String? {
        let pasteboard = UIPasteboard.general
        if let binary = Self.preferredPasteboardBinaryMediaType(in: pasteboard) {
            return binary.displayName
        }
        if let type = Self.preferredPasteboardImageType(in: pasteboard) {
            return type.displayName
        }
        if pasteboard.hasImages {
            return "PNG"
        }
        return nil
    }

    func importFromPhotos(_ item: PhotosPickerItem) async throws -> URL {
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw ImportError.unsupportedType
        }

        let preferredType = item.supportedContentTypes.first
        let fallbackExtension = preferredType?.preferredFilenameExtension ?? "dat"
        let outputURL = ImportStorage.url(originalName: nil, fallbackExtension: fallbackExtension)
        try write(data, to: outputURL)
        return outputURL
    }

    func importFromFiles(at url: URL) async throws -> URL {
        let hasAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let detectedCategory = FormatMatrix.detectCategory(from: url)

        guard detectedCategory != nil else {
            throw ImportError.unsupportedType
        }

        try enforceImportSizeLimit(for: url)

        let outputURL = ImportStorage.url(
            originalName: url.lastPathComponent,
            fallbackExtension: url.pathExtension.isEmpty ? "dat" : url.pathExtension
        )

        do {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: url, to: outputURL)
            try enforceImportSizeLimit(for: outputURL)
            return outputURL
        } catch let error as ImportError {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try? FileManager.default.removeItem(at: outputURL)
            }
            throw error
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
    }

    func importFromPasteboard() async throws -> URL {
        let pasteboard = UIPasteboard.general
        if let fileURL = Self.firstSupportedMediaFileURL(in: pasteboard) {
            return try await importFromFiles(at: fileURL)
        }
        if let binary = Self.preferredPasteboardBinaryMediaRepresentation(in: pasteboard) {
            let outputURL = ImportStorage.url(
                originalName: "clipboard.\(binary.fileExtension)",
                fallbackExtension: binary.fileExtension
            )
            try write(binary.data, to: outputURL)
            return outputURL
        }
        guard let representation = Self.preferredPasteboardImageRepresentation(in: pasteboard) else {
            throw ImportError.noSupportedMediaInPasteboard
        }

        let outputURL = ImportStorage.url(
            originalName: "clipboard.\(representation.fileExtension)",
            fallbackExtension: representation.fileExtension
        )
        try write(representation.data, to: outputURL)
        return outputURL
    }

    /// Downloads a file from an http(s) URL into ``ImportStorage``, enforcing ``maxImportBytes`` and ``FormatMatrix`` support.
    func importFromRemoteURL(
        _ string: String,
        progress: ((RemoteDownloadProgress) async -> Void)? = nil
    ) async throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.invalidRemoteURL }

        guard let url = Self.normalizedRemoteURL(from: trimmed) else {
            throw ImportError.invalidRemoteURL
        }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ImportError.invalidRemoteURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch {
            throw ImportError.networkFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ImportError.networkFailed("Not an HTTP response.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ImportError.networkFailed("Server returned status \(http.statusCode).")
        }

        let declaredContentLength = Self.declaredContentLength(from: http)
        if let declared = declaredContentLength, declared > Self.maxImportBytes {
            throw ImportError.fileTooLarge(limitBytes: Self.maxImportBytes)
        }

        guard let ext = Self.inferredFileExtension(remoteURL: url, response: http) else {
            throw ImportError.couldNotDetermineRemoteFileType
        }

        let tempName = "download.\(ext)"
        let outputURL = ImportStorage.url(originalName: tempName, fallbackExtension: ext)

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ImportError.copyFailed("Could not create a temporary file.")
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        func reportProgress(_ byteCount: Int64) async {
            await progress?(RemoteDownloadProgress(bytesReceived: byteCount, totalBytes: declaredContentLength))
        }

        await reportProgress(0)

        var total: Int64 = 0
        let chunkCapacity = 256 * 1024
        var scratch = [UInt8](repeating: 0, count: chunkCapacity)
        var scratchCount = 0
        do {
            for try await byte in bytes {
                scratch[scratchCount] = byte
                scratchCount += 1
                total += 1
                if total > Self.maxImportBytes {
                    try? FileManager.default.removeItem(at: outputURL)
                    throw ImportError.fileTooLarge(limitBytes: Self.maxImportBytes)
                }
                if scratchCount == chunkCapacity {
                    try handle.write(contentsOf: scratch)
                    scratchCount = 0
                    await reportProgress(total)
                }
            }
            if scratchCount > 0 {
                try handle.write(contentsOf: scratch[0 ..< scratchCount])
            }
            if declaredContentLength == nil, total > 0 {
                // No Content-Length while downloading; use actual size for the last tick so the bar can reach 100%.
                await progress?(RemoteDownloadProgress(bytesReceived: total, totalBytes: total))
            } else {
                await reportProgress(total)
            }
        } catch let error as ImportError {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.networkFailed(error.localizedDescription)
        }

        guard FormatMatrix.detectCategory(from: outputURL) != nil else {
            try? FileManager.default.removeItem(at: outputURL)
            throw ImportError.unsupportedType
        }

        return outputURL
    }

    private static func declaredContentLength(from response: HTTPURLResponse) -> Int64? {
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        if let lengthHeader = response.value(forHTTPHeaderField: "Content-Length") {
            let firstToken = lengthHeader
                .split(separator: ",")
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? lengthHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if let declared = Int64(firstToken), declared > 0 {
                return declared
            }
        }
        return nil
    }

    private static func normalizedRemoteURL(from string: String) -> URL? {
        if let u = URL(string: string), u.scheme != nil { return u }
        if let u = URL(string: "https://\(string)"), u.host != nil { return u }
        return nil
    }

    private static func inferredFileExtension(remoteURL: URL, response: HTTPURLResponse) -> String? {
        if let cd = response.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filenameFromContentDisposition(cd) {
            let ext = URL(fileURLWithPath: name).pathExtension.lowercased()
            if !ext.isEmpty { return ext }
        }

        let pathExt = remoteURL.pathExtension.lowercased()
        if !pathExt.isEmpty { return pathExt }

        guard let rawType = response.value(forHTTPHeaderField: "Content-Type") else { return nil }
        let mime = rawType.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let mime else { return nil }
        return mimeToExtension[mime]
    }

    private static func filenameFromContentDisposition(_ value: String) -> String? {
        let segments = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments where segment.lowercased().hasPrefix("filename*=") {
            var rest = String(segment.dropFirst("filename*=".count)).trimmingCharacters(in: .whitespaces)
            if let sep = rest.range(of: "''", options: .literal) {
                rest = String(rest[sep.upperBound...])
            }
            let token = rest.split(separator: ";").first.map(String.init) ?? rest
            let decoded = token.removingPercentEncoding ?? token
            if !decoded.isEmpty { return decoded }
        }
        for segment in segments where segment.lowercased().hasPrefix("filename=") {
            var name = String(segment.dropFirst("filename=".count)).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            } else {
                name = String(name.split(separator: ";").first ?? Substring(name))
            }
            if !name.isEmpty { return name }
        }
        return nil
    }

    private static func preferredPasteboardImageRepresentation(in pasteboard: UIPasteboard) -> PasteboardImageRepresentation? {
        for type in preferredConcreteImageTypes(in: pasteboard) {
            guard let data = pasteboard.data(forPasteboardType: type.identifier),
                  !data.isEmpty else { continue }
            return PasteboardImageRepresentation(
                data: data,
                fileExtension: type.fileExtension,
                displayName: type.displayName
            )
        }

        guard let image = pasteboard.image,
              let data = image.pngData() else {
            return nil
        }
        return PasteboardImageRepresentation(
            data: data,
            fileExtension: "png",
            displayName: "PNG"
        )
    }

    private static func preferredPasteboardImageType(in pasteboard: UIPasteboard) -> PasteboardImageType? {
        preferredConcreteImageTypes(in: pasteboard).first
    }

    private static func preferredPasteboardBinaryMediaRepresentation(in pasteboard: UIPasteboard) -> PasteboardBinaryMediaRepresentation? {
        guard let mediaType = preferredPasteboardBinaryMediaType(in: pasteboard) else {
            return nil
        }
        let identifier = mediaType.identifier
        let ext = mediaType.fileExtension
        guard let data = pasteboard.data(forPasteboardType: identifier), !data.isEmpty else {
            return nil
        }
        return PasteboardBinaryMediaRepresentation(
            data: data,
            fileExtension: ext,
            displayName: mediaType.displayName,
            typeIdentifier: identifier
        )
    }

    private static func preferredPasteboardBinaryMediaType(in pasteboard: UIPasteboard) -> (identifier: String, fileExtension: String, displayName: String)? {
        for identifier in pasteboard.types {
            guard let ext = mediaFileExtension(forPasteboardTypeIdentifier: identifier),
                  let category = FormatMatrix.detectCategory(from: URL(fileURLWithPath: "clipboard.\(ext)")),
                  category == .audio || category == .video || category == .animatedImage else {
                continue
            }
            return (identifier, ext, labelForMediaFileExtension(ext))
        }
        return nil
    }

    private static func mediaFileExtension(forPasteboardTypeIdentifier identifier: String) -> String? {
        let identifierOverrides: [String: String] = [
            "com.apple.m4a-audio": "m4a",
            "public.mpeg-4-audio": "m4a"
        ]
        if let override = identifierOverrides[identifier] {
            return override
        }
        guard let type = UTType(identifier),
              let preferredExt = type.preferredFilenameExtension?.lowercased(),
              !preferredExt.isEmpty else {
            return nil
        }
        return preferredExt
    }

    private static func preferredConcreteImageTypes(in pasteboard: UIPasteboard) -> [PasteboardImageType] {
        pasteboard.types.compactMap(concreteImageType(for:))
    }

    private static func concreteImageType(for identifier: String) -> PasteboardImageType? {
        if let override = pasteboardImageTypeOverrides[identifier] {
            return PasteboardImageType(
                identifier: identifier,
                fileExtension: override.fileExtension,
                displayName: override.displayName
            )
        }

        guard let type = UTType(identifier),
              type.conforms(to: .image),
              type != .image,
              let fileExtension = type.preferredFilenameExtension?.lowercased(),
              !fileExtension.isEmpty else {
            return nil
        }

        return PasteboardImageType(
            identifier: identifier,
            fileExtension: fileExtension,
            displayName: imageDisplayName(forExtension: fileExtension)
        )
    }

    private static func imageDisplayName(forExtension fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg":
            "JPEG"
        case "heic":
            "HEIC"
        case "heif":
            "HEIF"
        case "png":
            "PNG"
        case "gif":
            "GIF"
        case "webp":
            "WebP"
        case "tif", "tiff":
            "TIFF"
        case "bmp":
            "BMP"
        default:
            fileExtension.uppercased()
        }
    }

    /// File-backed clipboard entries (e.g. from Files) — checked before image data.
    private static func allFileURLs(in pasteboard: UIPasteboard) -> [URL] {
        var seen = Set<String>()
        var ordered: [URL] = []
        func add(_ u: URL) {
            guard u.isFileURL else { return }
            let key = u.standardizedFileURL.path
            guard !key.isEmpty, !seen.contains(key) else { return }
            seen.insert(key)
            ordered.append(u)
        }
        if let u = pasteboard.url {
            add(u)
        }
        for u in pasteboard.urls ?? [] {
            add(u)
        }
        for item in pasteboard.items {
            for (_, any) in item {
                if let u = any as? URL {
                    add(u)
                } else if let s = any as? String, let u = URL(string: s) {
                    add(u)
                } else if let data = any as? Data, let s = String(data: data, encoding: .utf8) {
                    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                    if let u = URL(string: t) {
                        add(u)
                    }
                }
            }
        }
        return ordered
    }

    private static func firstSupportedMediaFileURL(in pasteboard: UIPasteboard) -> URL? {
        let fileURLs = allFileURLs(in: pasteboard)
        for url in fileURLs {
            if FormatMatrix.detectCategory(from: url) != nil {
                return url
            }
        }
        return nil
    }

    private static func displayLabelForFileURL(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext.isEmpty { return "File" }
        return labelForMediaFileExtension(ext)
    }

    private static func labelForMediaFileExtension(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "JPEG"
        case "m4a": return "M4A"
        case "mp3": return "MP3"
        case "mp4", "m4v": return "MP4"
        case "mov": return "MOV"
        case "webm": return "WebM"
        case "mkv": return "MKV"
        case "wav": return "WAV"
        case "aac": return "AAC"
        case "flac": return "FLAC"
        case "ogg": return "OGG"
        case "opus": return "OPUS"
        case "heic", "heif": return "HEIC"
        case "alac": return "ALAC"
        case "avif": return "AVIF"
        default: return ext.uppercased()
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        try enforceImportSizeLimit(byteCount: Int64(data.count))
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
    }

    private func enforceImportSizeLimit(for url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        try enforceImportSizeLimit(byteCount: size)
    }

    private func enforceImportSizeLimit(byteCount: Int64) throws {
        guard byteCount <= Self.maxImportBytes else {
            throw ImportError.fileTooLarge(limitBytes: Self.maxImportBytes)
        }
    }

}
