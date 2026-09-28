import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit

@MainActor
@Observable
final class HomeViewModel {
    var isImporting = false
    var errorMessage: String?
    var remoteDownloadProgress: RemoteDownloadProgress?

    private let importService = ImportService()

    /// Short label (e.g. "JPEG", "M4A") for supported clipboard content; `nil` disables the paste control.
    var pasteboardImportLabel: String?
    var pasteboardImportFileExtension: String?
    var pasteboardPreviewThumbnail: UIImage?
    var pasteboardFileSizeBytes: Int64?
    var pasteboardDuration: TimeInterval?
    private var lastSeenPasteboardChangeCount: Int
    private var lastPreviewPasteboardChangeCount: Int?
    private var pasteboardPreviewTask: Task<Void, Never>?

    init() {
        lastSeenPasteboardChangeCount = UIPasteboard.general.changeCount
        refreshPasteboard()
    }

    func refreshPasteboard() {
        let changeCount = UIPasteboard.general.changeCount
        lastSeenPasteboardChangeCount = changeCount
        guard lastPreviewPasteboardChangeCount != changeCount else { return }
        let candidateLabel = importService.pasteboardImportLabel()
        // Advertised types are only candidates. Keep paste disabled until the
        // provider actually supplies a readable representation.
        pasteboardImportLabel = nil
        pasteboardImportFileExtension = nil
        lastPreviewPasteboardChangeCount = changeCount
        pasteboardPreviewTask?.cancel()
        pasteboardPreviewThumbnail = nil
        pasteboardFileSizeBytes = nil
        pasteboardDuration = nil
        guard candidateLabel != nil else { return }

        pasteboardPreviewTask = Task { [weak self] in
            guard let self else { return }
            let preview = await self.importService.pasteboardPreview(forChangeCount: changeCount)
            guard !Task.isCancelled,
                  UIPasteboard.general.changeCount == changeCount else { return }
            if let fileExtension = preview.readableFileExtension {
                self.pasteboardImportLabel = fileExtension.uppercased()
                self.pasteboardImportFileExtension = fileExtension
            }
            self.pasteboardPreviewThumbnail = preview.thumbnail
            self.pasteboardFileSizeBytes = preview.fileSizeBytes
            self.pasteboardDuration = preview.duration
        }
    }

    /// `UIPasteboard.changedNotification` can occasionally be delayed/missed until user interaction.
    /// Polling `changeCount` gives us immediate UI updates while Home is visible.
    func refreshPasteboardIfNeeded() {
        let current = UIPasteboard.general.changeCount
        guard current != lastSeenPasteboardChangeCount else { return }
        refreshPasteboard()
    }

    func importFromPhotos(_ item: PhotosPickerItem) async -> MediaFile? {
        await importFile(context: "Import from Photos") {
            try await importService.importFromPhotos(item)
        }
    }

    func importFromFiles(_ url: URL) async -> MediaFile? {
        await importFile(
            context: "Import from Files",
            metadata: ["Selected file": url.lastPathComponent]
        ) {
            try await importService.importFromFiles(at: url)
        }
    }

    func importFromPasteboard() async -> MediaFile? {
        let changeCount = UIPasteboard.general.changeCount
        let media = await importFile(context: "Import from clipboard") {
            try await importService.importFromPasteboard()
        }
        if media == nil, UIPasteboard.general.changeCount == changeCount {
            // A provider can become unavailable after the preview. Don't keep
            // offering the same failed clipboard item until it is copied again.
            pasteboardPreviewTask?.cancel()
            pasteboardImportLabel = nil
            pasteboardImportFileExtension = nil
            pasteboardPreviewThumbnail = nil
            pasteboardFileSizeBytes = nil
            pasteboardDuration = nil
        }
        return media
    }

    func importFromRemoteLink(_ linkString: String) async -> MediaFile? {
        remoteDownloadProgress = RemoteDownloadProgress(bytesReceived: 0, totalBytes: nil)
        let parsedURL = URL(string: linkString.trimmingCharacters(in: .whitespacesAndNewlines))
        let source = [parsedURL?.scheme, parsedURL?.host]
            .compactMap { $0 }
            .joined(separator: "://")
        return await importFile(
            context: "Import from link",
            metadata: source.isEmpty ? [:] : ["Remote source": source]
        ) {
            try await importService.importFromRemoteURL(linkString) { [weak self] progress in
                await MainActor.run {
                    self?.remoteDownloadProgress = progress
                }
            }
        }
    }

    private func importFile(
        context: String,
        metadata: [String: String] = [:],
        _ operation: () async throws -> URL
    ) async -> MediaFile? {
        isImporting = true
        errorMessage = nil
        defer {
            isImporting = false
            remoteDownloadProgress = nil
        }

        do {
            let url = try await operation()
            do {
                let media = try await importService.validatedMediaFile(at: url)
                Haptics.success()
                return media
            } catch {
                // Imported picker/provider files are app-owned copies. Remove a
                // potentially very large copy when validation cannot use it.
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        } catch {
            errorMessage = error.localizedDescription
            DiagnosticsLog.shared.record(error: error, context: context, metadata: metadata)
            Haptics.error()
            return nil
        }
    }
}
