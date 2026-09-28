import AVFoundation
import Foundation

struct VideoTrimRange: Hashable {
    var start: Double
    var end: Double

    var duration: Double { end - start }
    var timeRange: CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                    end: CMTime(seconds: end, preferredTimescale: 600))
    }

    func isFullDuration(_ duration: Double) -> Bool {
        start == 0 && abs(end - duration) < 0.001
    }

    func clampedPlayhead(_ seconds: Double) -> Double {
        min(max(seconds, start), end)
    }

    func movingStart(to seconds: Double, totalDuration: Double) -> Self {
        Self(start: min(max(0, seconds), end - min(0.1, totalDuration)), end: end)
    }

    func movingEnd(to seconds: Double, totalDuration: Double) -> Self {
        Self(start: start, end: max(min(totalDuration, seconds), start + min(0.1, totalDuration)))
    }
}

enum VideoTrimmer {
    static func trimmedMedia(sourceURL: URL, range: VideoTrimRange) async throws -> MediaFile {
        let outputURL = try await export(sourceURL: sourceURL, range: range)
        do {
            try Task.checkCancellation()
            return try await ImportService().validatedMediaFile(at: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    /// Export directly into owned storage. No picker-owned paths or delegate callbacks
    /// survive a presentation change, and the caller only publishes a validated file.
    static func export(sourceURL: URL, range: VideoTrimRange) async throws -> URL {
        try Task.checkCancellation()
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, range.start.isFinite, range.end.isFinite,
              range.start >= 0, range.end <= duration + 0.001, range.duration > 0 else {
            throw ConversionError.invalidInput("Choose a valid start and end time for the trim.")
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw ConversionError.invalidInput("This video can't be trimmed on this device.")
        }
        let types = session.supportedFileTypes
        let fileType: AVFileType
        if types.contains(.mov) { fileType = .mov }
        else if types.contains(.mp4) { fileType = .mp4 }
        else { throw ConversionError.invalidInput("This video can't be trimmed on this device.") }

        let outputURL = ImportStorage.url(originalName: nil, fallbackExtension: fileType == .mov ? "mov" : "mp4")
        session.outputURL = outputURL
        session.outputFileType = fileType
        session.timeRange = range.timeRange
        do {
            await withTaskCancellationHandler {
                await session.export()
            } onCancel: {
                session.cancelExport()
            }
            try Task.checkCancellation()
            guard session.status == .completed else {
                throw session.error ?? ConversionError.invalidInput("The video trim could not be saved. Try again.")
            }
            TempStorage.allowAccessWhileLocked(at: outputURL)
            return outputURL
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }
}
