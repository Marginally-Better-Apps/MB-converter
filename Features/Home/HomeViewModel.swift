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
    private var lastSeenPasteboardChangeCount: Int

    init() {
        lastSeenPasteboardChangeCount = UIPasteboard.general.changeCount
        refreshPasteboard()
    }

    func refreshPasteboard() {
        lastSeenPasteboardChangeCount = UIPasteboard.general.changeCount
        pasteboardImportLabel = importService.pasteboardImportLabel()
    }

    /// `UIPasteboard.changedNotification` can occasionally be delayed/missed until user interaction.
    /// Polling `changeCount` gives us immediate UI updates while Home is visible.
    func refreshPasteboardIfNeeded() {
        let current = UIPasteboard.general.changeCount
        guard current != lastSeenPasteboardChangeCount else { return }
        refreshPasteboard()
    }

    func importFromPhotos(_ item: PhotosPickerItem) async -> MediaFile? {
        await importFile {
            try await importService.importFromPhotos(item)
        }
    }

    func importFromFiles(_ url: URL) async -> MediaFile? {
        await importFile {
            try await importService.importFromFiles(at: url)
        }
    }

    func importFromPasteboard() async -> MediaFile? {
        await importFile {
            try await importService.importFromPasteboard()
        }
    }

    func importFromRemoteLink(_ linkString: String) async -> MediaFile? {
        remoteDownloadProgress = RemoteDownloadProgress(bytesReceived: 0, totalBytes: nil)
        return await importFile {
            try await importService.importFromRemoteURL(linkString) { [weak self] progress in
                await MainActor.run {
                    self?.remoteDownloadProgress = progress
                }
            }
        }
    }

    private func importFile(_ operation: () async throws -> URL) async -> MediaFile? {
        isImporting = true
        errorMessage = nil
        defer {
            isImporting = false
            remoteDownloadProgress = nil
        }

        do {
            let url = try await operation()
            let media = try await importService.validatedMediaFile(at: url)
            Haptics.success()
            return media
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return nil
        }
    }
}
