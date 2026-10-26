import Foundation
import Photos

/// Saves finished photos and videos to the Photos app (add-only access: the app never reads it).
enum PhotoLibrarySaver {
    /// Formats the Photos app can store and show.
    static let photoFormats: Set<FileFormat> = [.jpeg, .png, .heic, .gif, .tiff, .webp]
    static let videoFormats: Set<FileFormat> = [.mp4, .mov, .m4v]

    static func canSave(_ files: [ToolOutputFile]) -> Bool {
        !files.isEmpty && files.allSatisfy { file in
            file.format.map { photoFormats.contains($0) || videoFormats.contains($0) } ?? false
        }
    }

    enum Failure: LocalizedError {
        case notAllowed

        var errorDescription: String? {
            "MB Converter isn't allowed to add to your photos. You can allow it in Settings → Privacy & Security → Photos."
        }
    }

    static func save(_ urls: [URL]) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.notAllowed }
        try await PHPhotoLibrary.shared().performChanges {
            for url in urls {
                let isVideo = FileFormat(url: url).map { videoFormats.contains($0) } ?? false
                PHAssetCreationRequest.forAsset().addResource(with: isVideo ? .video : .photo, fileURL: url, options: nil)
            }
        }
    }
}
