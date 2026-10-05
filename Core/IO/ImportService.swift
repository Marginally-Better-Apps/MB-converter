import AVFoundation
import CoreTransferable
import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A file-backed Photos transfer. `ReceivedTransferredFile.file` is temporary,
/// so each representation copies it into app-owned storage inside the import
/// callback instead of materializing the whole asset as `Data`.
private struct ImportedPhotoLibraryFile: Transferable {
    let url: URL
    let usedFallbackExtension: Bool

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            try copy(received.file, fallbackExtension: "heic")
        }
        FileRepresentation(importedContentType: .movie) { received in
            try copy(received.file, fallbackExtension: "mov")
        }
    }

    private static func copy(_ sourceURL: URL, fallbackExtension: String) throws -> Self {
        let sourceExtension = sourceURL.pathExtension
        let outputURL = try ImportStorage.copyFile(
            at: sourceURL,
            fallbackExtension: fallbackExtension
        )
        return Self(url: outputURL, usedFallbackExtension: sourceExtension.isEmpty)
    }
}

struct PasteboardPreview {
    var thumbnail: UIImage?
    var fileSizeBytes: Int64?
    var duration: TimeInterval? = nil
    /// Set only after loading readable media, never from advertised types or a provider thumbnail.
    var readableFileExtension: String? = nil
}

/// Provider callbacks aren't Swift tasks, so cancellation must cross the callback boundary.
private final class PasteboardPreviewCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

struct ImportService {
    /// Maximum size for a file downloaded from a remote link (bytes).
    static let maxRemoteImportBytes = RemoteFileDownloader.maxBytes

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

    /// Returns a label from advertised types without loading media data. `nil` when no supported media is available.
    func pasteboardImportLabel() -> String? {
        let pasteboard = UIPasteboard.general
        if let fileURL = Self.firstSupportedMediaFileURL(in: pasteboard) {
            return Self.displayLabelForFileURL(fileURL)
        }
        if let representation = Self.pasteboardFileRepresentations(in: pasteboard).first {
            return Self.labelForMediaFileExtension(representation.fallbackExtension)
        }
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

    func pasteboardImportFileExtension() -> String? {
        let pasteboard = UIPasteboard.general
        if let fileURL = Self.firstSupportedMediaFileURL(in: pasteboard),
           !fileURL.pathExtension.isEmpty {
            return fileURL.pathExtension
        }
        if let suggestedName = Self.pasteboardFileRepresentations(in: pasteboard).first?.suggestedName {
            let fileExtension = URL(fileURLWithPath: suggestedName).pathExtension
            if !fileExtension.isEmpty { return fileExtension }
        }
        if let binary = Self.preferredPasteboardBinaryMediaType(in: pasteboard) {
            return binary.fileExtension
        }
        if let image = Self.preferredPasteboardImageType(in: pasteboard) {
            return image.fileExtension
        }
        if pasteboard.hasImages {
            return "png"
        }
        return nil
    }

    /// Loads a small preview and file size without buffering full media files in memory.
    @MainActor
    func pasteboardPreview(
        forChangeCount expectedChangeCount: Int,
        maxPixelSize: Int = 144
    ) async -> PasteboardPreview {
        let pasteboard = UIPasteboard.general
        guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else {
            return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
        }

        if let fileURL = Self.firstSupportedMediaFileURL(in: pasteboard) {
            let hasAccess = fileURL.startAccessingSecurityScopedResource()
            defer { if hasAccess { fileURL.stopAccessingSecurityScopedResource() } }
            let preview = await Self.filePreview(
                at: fileURL, fileExtension: fileURL.pathExtension, maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else {
                return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
            }
            // Import gives a direct file URL precedence over provider data too.
            return preview
        }

        for representation in Self.pasteboardFileRepresentations(in: pasteboard) {
            guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else { break }
            let preview = await Self.loadFilePreview(from: representation, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else {
                return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
            }
            if preview.readableFileExtension != nil { return preview }
        }

        guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else {
            return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
        }

        // Some providers advertise HEIC but cannot vend a file. Check the same
        // data/image fallbacks used by import, not their independent preview image.
        let preview: PasteboardPreview
        if let binary = Self.preferredPasteboardBinaryMediaRepresentation(in: pasteboard) {
            preview = await Self.dataPreview(
                binary.data, fileExtension: binary.fileExtension, maxPixelSize: maxPixelSize
            )
        } else if let representation = Self.preferredPasteboardImageRepresentation(in: pasteboard) {
            preview = await Self.dataPreview(
                representation.data, fileExtension: representation.fileExtension, maxPixelSize: maxPixelSize
            )
        } else {
            return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
        }
        guard !Task.isCancelled, pasteboard.changeCount == expectedChangeCount else {
            return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
        }
        return preview
    }

    private static func loadFilePreview(
        from representation: PasteboardFileRepresentation,
        maxPixelSize: Int
    ) async -> PasteboardPreview {
        let cancellation = PasteboardPreviewCancellation()
        let fallbackExtension = representation.fallbackExtension
        let ownedURL: URL? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !cancellation.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                // Use the same loading API as import. An in-place file or a
                // provider thumbnail alone doesn't prove this request will work.
                representation.provider.loadFileRepresentation(
                    forTypeIdentifier: representation.typeIdentifier
                ) { fileURL, _ in
                    guard let fileURL, !cancellation.isCancelled else {
                        continuation.resume(returning: nil)
                        return
                    }
                    // Provider URLs expire on returning from this callback. Copy before any async decoding.
                    var copy: URL?
                    NSFileCoordinator().coordinate(readingItemAt: fileURL, options: [], error: nil) { readableURL in
                        guard !cancellation.isCancelled else { return }
                        copy = try? ImportStorage.copyFile(
                            at: readableURL, originalName: "clipboard.\(fallbackExtension)",
                            fallbackExtension: fallbackExtension
                        )
                    }
                    continuation.resume(returning: copy)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        guard let ownedURL else { return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil) }
        defer { try? FileManager.default.removeItem(at: ownedURL) }
        guard !Task.isCancelled else { return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil) }
        return await filePreview(at: ownedURL, fileExtension: fallbackExtension,
                                 maxPixelSize: maxPixelSize, ownsFile: true)
    }

    private static func dataPreview(_ data: Data, fileExtension: String, maxPixelSize: Int) async -> PasteboardPreview {
        let url = ImportStorage.url(originalName: nil, fallbackExtension: fileExtension)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try Task.checkCancellation()
            try await Task.detached(priority: .userInitiated) { try data.write(to: url, options: .atomic) }.value
            try Task.checkCancellation()
            return await filePreview(at: url, fileExtension: fileExtension, maxPixelSize: maxPixelSize, ownsFile: true)
        } catch {
            return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
        }
    }

    private static func needsDuration(fileExtension: String) -> Bool {
        let category = FormatMatrix.detectCategory(from: URL(fileURLWithPath: "clipboard.\(fileExtension)"))
        return category == .audio || category == .video
    }

    private static func filePreview(
        at url: URL, fileExtension: String, maxPixelSize: Int, ownsFile: Bool = false
    ) async -> PasteboardPreview {
        let cancellation = PasteboardPreviewCancellation()
        let (native, fallbackURL) = await withTaskCancellationHandler {
            await Task.detached(priority: .userInitiated) {
                nativeFilePreview(at: url, fileExtension: fileExtension, maxPixelSize: maxPixelSize,
                                  ownsFile: ownsFile, isCancelled: { cancellation.isCancelled })
            }.value
        } onCancel: { cancellation.cancel() }
        defer {
            if !ownsFile, let fallbackURL { try? FileManager.default.removeItem(at: fallbackURL) }
        }
        guard !Task.isCancelled else { return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil) }
        var preview = native
        let category = FormatMatrix.detectCategory(from: URL(fileURLWithPath: "clipboard.\(fileExtension)"))
        if preview.thumbnail == nil, let fallbackURL {
            do {
                if category == .audio {
                    let sample = try await MediaPreviewRenderer.renderAudioThumbnailSample(sourceURL: fallbackURL)
                    defer { try? FileManager.default.removeItem(at: sample) }
                    preview.thumbnail = await withTaskCancellationHandler {
                        await Task.detached(priority: .userInitiated) {
                            AudioWaveformThumbnail.image(from: sample, maxPixelSize: maxPixelSize,
                                                         isCancelled: { cancellation.isCancelled })
                                .map { UIImage(cgImage: $0) }
                        }.value
                    } onCancel: { cancellation.cancel() }
                } else {
                    let data = try await MediaPreviewRenderer.firstFrame(sourceURL: fallbackURL, maximumDimension: maxPixelSize)
                    preview.thumbnail = UIImage(data: data)
                }
                if preview.thumbnail != nil { preview.readableFileExtension = fileExtension }
            } catch {
                // An unreadable thumbnail must not hide an otherwise importable audio/video file.
            }
        }
        guard !Task.isCancelled else { return PasteboardPreview(thumbnail: nil, fileSizeBytes: nil) }
        if preview.readableFileExtension != nil, needsDuration(fileExtension: fileExtension) {
            preview.duration = await mediaDuration(from: fallbackURL ?? url)
        }
        return Task.isCancelled ? PasteboardPreview(thumbnail: nil, fileSizeBytes: nil) : preview
    }

    private static func nativeFilePreview(
        at url: URL,
        fileExtension: String,
        maxPixelSize: Int,
        ownsFile: Bool,
        isCancelled: () -> Bool
    ) -> (PasteboardPreview, URL?) {
        var preview = PasteboardPreview(thumbnail: nil, fileSizeBytes: nil)
        var fallbackURL: URL?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: nil) { readableURL in
            guard !isCancelled(),
                  let handle = try? FileHandle(forReadingFrom: readableURL) else { return }
            defer { try? handle.close() }
            guard let firstByte = try? handle.read(upToCount: 1), !firstByte.isEmpty else { return }
            let attributes = try? FileManager.default.attributesOfItem(atPath: readableURL.path)
            preview.fileSizeBytes = (attributes?[.size] as? NSNumber)?.int64Value
            let category = FormatMatrix.detectCategory(
                from: URL(fileURLWithPath: "clipboard.\(fileExtension)")
            )
            switch category {
            case .some(.image), .some(.animatedImage):
                preview.thumbnail = Self.imageThumbnail(from: readableURL, maxPixelSize: maxPixelSize)
            case .some(.video):
                preview.thumbnail = Self.videoThumbnail(from: readableURL, maxPixelSize: maxPixelSize, isCancelled: isCancelled)
            case .some(.audio):
                preview.thumbnail = AudioWaveformThumbnail.image(
                    from: readableURL, maxPixelSize: maxPixelSize, isCancelled: isCancelled
                ).map { UIImage(cgImage: $0) }
            case .none:
                return
            }
            guard !isCancelled() else { return }
            if preview.thumbnail == nil {
                // Keep coordinated source access valid while asynchronous FFmpeg work runs.
                fallbackURL = ownsFile ? url : (try? ImportStorage.copyFile(
                    at: readableURL, originalName: "clipboard.\(fileExtension)", fallbackExtension: fileExtension
                ))
            }
            if preview.thumbnail != nil || category == .audio || category == .video {
                preview.readableFileExtension = fileExtension
            }
        }
        return (preview, fallbackURL)
    }

    private static func mediaDuration(from url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 { return seconds }
        }
        guard !Task.isCancelled else { return nil }
        let probe = await Task.detached(priority: .userInitiated) {
            FFmpegMediaProbe.probe(at: url, timeoutMilliseconds: 3_000)
        }.value
        return ([probe?.format?.duration] + (probe?.streams.map { $0.duration } ?? []))
            .compactMap { $0 }.first { $0.isFinite && $0 > 0 }
    }

    private static func imageThumbnail(from fileURL: URL, maxPixelSize: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
                ] as CFDictionary
              ) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    private static func videoThumbnail(from fileURL: URL, maxPixelSize: Int, isCancelled: () -> Bool) -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        for seconds in [0.0, 0.1, 0.5] {
            guard !isCancelled() else { return nil }
            do {
                let frame = try generator.copyCGImage(
                    at: CMTime(seconds: seconds, preferredTimescale: 600),
                    actualTime: nil
                )
                return UIImage(cgImage: frame)
            } catch {
                continue
            }
        }
        return nil
    }

    func importFromPhotos(_ item: PhotosPickerItem) async throws -> URL {
        guard let imported = try await item.loadTransferable(type: ImportedPhotoLibraryFile.self) else {
            throw ImportError.unsupportedType
        }
        if imported.usedFallbackExtension,
           let preferredExtension = item.supportedContentTypes.lazy.compactMap(\.preferredFilenameExtension).first {
            return try replaceFilenameExtension(of: imported.url, with: preferredExtension)
        }
        return imported.url
    }

    /// Live Photos also carry a short movie. Copy it beside the still so video
    /// outputs and key photo choices can use it. Regular photos return nil.
    func importLivePhotoMovie(from item: PhotosPickerItem) async -> URL? {
        #if os(iOS)
        // Only Live Photos provide this representation; a still fails immediately.
        guard let livePhoto = try? await item.loadTransferable(type: PHLivePhoto.self) else { return nil }
        let resources = PHAssetResource.assetResources(for: livePhoto)
        // An edited Live Photo's full-size movie matches the edited still.
        guard let movie = resources.first(where: { $0.type == .fullSizePairedVideo })
                ?? resources.first(where: { $0.type == .pairedVideo }) else { return nil }
        let outputURL = ImportStorage.url(originalName: movie.originalFilename, fallbackExtension: "mov")
        do {
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            try await PHAssetResourceManager.default().writeData(for: movie, toFile: outputURL, options: options)
            TempStorage.allowAccessWhileLocked(at: outputURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            // The still still imports; only the video options are unavailable.
            DiagnosticsLog.shared.record(error: error, context: "Import Live Photo movie",
                                         metadata: ["Filename": movie.originalFilename])
            return nil
        }
        #else
        return nil
        #endif
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

        return try ImportStorage.copyFile(
            at: url,
            originalName: url.lastPathComponent,
            fallbackExtension: url.pathExtension.isEmpty ? "dat" : url.pathExtension
        )
    }

    func importFromPasteboard() async throws -> URL {
        let pasteboard = UIPasteboard.general
        if let fileURL = Self.firstSupportedMediaFileURL(in: pasteboard) {
            return try await importFromFiles(at: fileURL)
        }
        let changeCount = pasteboard.changeCount
        var providerError: Error?
        for representation in Self.pasteboardFileRepresentations(in: pasteboard) {
            try Task.checkCancellation()
            guard pasteboard.changeCount == changeCount else {
                throw ImportError.noSupportedMediaInPasteboard
            }
            do {
                return try await importPasteboardFileRepresentation(representation)
            } catch let error as PasteboardRepresentationUnavailable {
                providerError = error.underlying
            }
        }
        try Task.checkCancellation()
        guard pasteboard.changeCount == changeCount else {
            throw ImportError.noSupportedMediaInPasteboard
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
            if let providerError { throw ImportError.copyFailed(providerError.localizedDescription) }
            throw ImportError.noSupportedMediaInPasteboard
        }

        let outputURL = ImportStorage.url(
            originalName: "clipboard.\(representation.fileExtension)",
            fallbackExtension: representation.fileExtension
        )
        try write(representation.data, to: outputURL)
        return outputURL
    }

    /// Downloads a supported media candidate; `validatedMediaFile` inspects its contents before navigation.
    func importFromRemoteURL(
        _ string: String,
        progress: ((RemoteDownloadProgress) async -> Void)? = nil
    ) async throws -> URL {
        try await RemoteFileDownloader().download(string, progress: progress)
    }

    func validatedMediaFile(at url: URL) async throws -> MediaFile {
        let media = try await MediaInspector.inspect(url: url)
        if let issue = CodecCapability.decodeIssue(for: media) {
            throw ImportError.codecNotDecodable(
                codecLabel: issue.codecLabel,
                reason: issue.reason
            )
        }
        return media
    }

    private static func preferredPasteboardImageRepresentation(in pasteboard: UIPasteboard) -> PasteboardImageRepresentation? {
        var fallback: PasteboardImageRepresentation?
        for type in preferredConcreteImageTypes(in: pasteboard) {
            guard let data = pasteboard.data(forPasteboardType: type.identifier),
                  !data.isEmpty else { continue }
            let representation = PasteboardImageRepresentation(
                data: data,
                fileExtension: type.fileExtension,
                displayName: type.displayName
            )
            if CGImageSourceCreateWithData(data as CFData, nil) != nil { return representation }
            // Keep the native representation preference while allowing FFmpeg-only still images.
            if fallback == nil { fallback = representation }
        }

        guard let image = pasteboard.image,
              let data = image.pngData() else {
            return fallback
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

    private struct PasteboardFileRepresentation {
        let provider: NSItemProvider
        let typeIdentifier: String
        let fallbackExtension: String
        let suggestedName: String?
    }

    /// Requests a temporary file from the item provider. Even data-backed
    /// pasteboard entries are written to a file by the provider, keeping the
    /// app from receiving the full payload as one `Data` allocation.
    private static func pasteboardFileRepresentations(
        in pasteboard: UIPasteboard
    ) -> [PasteboardFileRepresentation] {
        var representations: [PasteboardFileRepresentation] = []
        for provider in pasteboard.itemProviders {
            for identifier in provider.registeredTypeIdentifiers {
                guard let ext = mediaFileExtension(forPasteboardTypeIdentifier: identifier),
                      FormatMatrix.detectCategory(
                          from: URL(fileURLWithPath: "clipboard.\(ext)")
                      ) != nil else {
                    continue
                }
                representations.append(PasteboardFileRepresentation(
                    provider: provider,
                    typeIdentifier: identifier,
                    fallbackExtension: ext,
                    suggestedName: provider.suggestedName
                ))
            }
        }
        return representations
    }

    private struct PasteboardRepresentationUnavailable: Error {
        let underlying: Error
    }

    private func importPasteboardFileRepresentation(
        _ representation: PasteboardFileRepresentation
    ) async throws -> URL {
        let suggestedName = representation.suggestedName
        let fallbackExtension = representation.fallbackExtension
        return try await withCheckedThrowingContinuation { continuation in
            representation.provider.loadFileRepresentation(
                forTypeIdentifier: representation.typeIdentifier
            ) { sourceURL, error in
                guard let sourceURL else {
                    continuation.resume(
                        throwing: PasteboardRepresentationUnavailable(
                            underlying: error ?? ImportError.noSupportedMediaInPasteboard
                        )
                    )
                    return
                }

                do {
                    let outputURL = try ImportStorage.copyFile(
                        at: sourceURL,
                        originalName: suggestedName.map {
                            URL(fileURLWithPath: $0).deletingPathExtension()
                                .appendingPathExtension(fallbackExtension).lastPathComponent
                        } ?? "clipboard.\(fallbackExtension)",
                        fallbackExtension: fallbackExtension
                    )
                    continuation.resume(returning: outputURL)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
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
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
    }

    private func replaceFilenameExtension(of url: URL, with fileExtension: String) throws -> URL {
        let outputURL = ImportStorage.url(
            originalName: nil,
            fallbackExtension: fileExtension
        )
        do {
            try FileManager.default.moveItem(at: url, to: outputURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw ImportError.copyFailed(error.localizedDescription)
        }
    }

}
