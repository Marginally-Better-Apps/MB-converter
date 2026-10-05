import Foundation
import CoreGraphics

/// Live Photo source switching and video speed planning in the convert model.
@MainActor
enum LivePhotoViewModelTests {
    static func run(still stillURL: URL) async throws {
        let directory = FileManager.default.temporaryDirectory
        let movieURL = directory.appendingPathComponent(UUID().uuidString + ".mov")
        let keyPhotoURL = directory.appendingPathComponent(UUID().uuidString + ".heic")
        try Data().write(to: keyPhotoURL)
        defer { try? FileManager.default.removeItem(at: keyPhotoURL) }

        let still = try await MediaInspector.inspect(url: stillURL).attachingLivePhoto(movieURL: movieURL)
        let model = OutputConfigViewModel(input: still)
        try require(model.isLivePhoto && model.livePhotoMovie == nil, "The movie is inspected after import")
        try require(!model.formats.contains { $0.category == .video }, "Video needs a readable movie")

        // A movie with half the still's resolution, like a Live Photo.
        let size = still.dimensions!
        model.attachLivePhotoMovie(MediaFile(
            url: movieURL, originalFilename: "IMG_0001.MOV", category: .video, sizeOnDisk: 1_000_000,
            dimensions: CGSize(width: size.width / 2, height: size.height / 2), duration: 3, fps: 30,
            bitrate: 2_000_000, audioBitrate: 64_000, videoCodec: "hvc1", audioCodec: "aac", containerFormat: "mov"
        ), originalKeyPhotoTime: 1.5)
        try require(model.formats.filter { $0.category == .video } == FormatMatrix.livePhotoVideoOutputs,
                    "Encodable video formats follow the still formats")
        await model.loadDiscoveredMetadataIfNeeded()
        let stillRows = model.metadataFieldRows

        model.cropRegion = CropRegion(x: 0, y: 0, width: size.width / 2, height: size.height / 2)
        model.selectedFormat = .mp4_h264
        try require(model.input.url == movieURL && model.input.id == still.id
                    && model.input.originalFilename == still.originalFilename,
                    "Video formats encode the movie as the same conversion")
        try require(model.cropRegion == CropRegion(x: 0, y: 0, width: size.width / 4, height: size.height / 4),
                    "Crop keeps the same region at the movie's size")
        try require(!model.canConvert, "Movie metadata must load before converting")
        await model.loadDiscoveredMetadataIfNeeded()
        model.selectedFormat = .mov
        try require(model.canConvert, "An unedited Live Photo movie can still be exported")

        model.videoSpeed = 2
        try require(model.makeConfig().videoSpeed == 2 && model.videoOutputDuration == 1.5,
                    "Speed shortens the planned output")
        let planned = model.makeConfig()
        model.videoSpeed = 1
        try require(planned != model.makeConfig(), "Speed changes invalidate cached results")

        model.selectedFormat = .jpg
        try require(model.input.url == stillURL && model.makeConfig().videoSpeed == 1,
                    "Still formats encode the photo without video speed")
        try require(model.cropRegion == CropRegion(x: 0, y: 0, width: size.width / 2, height: size.height / 2),
                    "Crop returns to the still's size")
        try require(model.metadataFieldRows == stillRows && model.canConvert, "Still metadata choices are kept")

        let keyPhoto = MediaFile(url: keyPhotoURL, originalFilename: "frame.heic", category: .image,
                                 sizeOnDisk: 1, dimensions: CGSize(width: size.width / 2, height: size.height / 2),
                                 containerFormat: "heic")
        model.useLivePhotoKeyPhoto(keyPhoto, at: 0.5)
        try require(model.input.url == keyPhotoURL && model.livePhotoKeyPhotoTime == 0.5
                    && model.input.originalFilename == still.originalFilename,
                    "A chosen key photo replaces the exported still")
        try require(model.livePhotoOwnedFileURLs.contains(keyPhotoURL) && model.livePhotoOwnedFileURLs.contains(movieURL),
                    "Rendered key photos and the movie are cleaned up with the conversion")
        try require(model.metadataFieldRows == stillRows, "The photo's metadata applies to its key frame")
        model.useLivePhotoKeyPhoto(nil, at: nil)
        try require(model.input.url == stillURL && model.livePhotoKeyPhotoTime == nil,
                    "The original key photo can be restored")
        try require(!FileManager.default.fileExists(atPath: keyPhotoURL.path), "A replaced key photo is deleted")
        print("Live Photo source switching, crop scaling, key photo and video speed planning passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
