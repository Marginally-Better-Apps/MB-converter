import AVFoundation
import Foundation
import ImageIO

/// Retain this alongside AVPlayer. Cached files are only evicted after their last user releases them.
final class MediaPreviewResource: @unchecked Sendable {
    let url: URL
    private let release: (@Sendable () -> Void)?

    fileprivate init(url: URL, release: (@Sendable () -> Void)? = nil) {
        self.url = url
        self.release = release
    }

    deinit { release?() }
}

/// FFmpeg work runs through the cancellable bridge; original media is never modified.
enum MediaPreviewRenderer {
    private static let cache = MediaPreviewCache()

    static func isPlayable(_ url: URL) async -> Bool {
        guard !Task.isCancelled else { return false }
        let asset = AVURLAsset(url: url)
        return await withTaskCancellationHandler {
            (try? await asset.load(.isPlayable)) == true && !Task.isCancelled
        } onCancel: {
            asset.cancelLoading()
        }
    }

    /// Native ImageIO/AVAssetImageGenerator decoding should be tried before this fallback.
    static func firstFrame(sourceURL: URL, maximumDimension: Int = 1600) async throws -> Data {
        let source = try PreviewSource(sourceURL)
        let dimension = max(2, maximumDimension)
        let key = PreviewCacheKey(source: source, variant: "still-\(dimension)")
        let resource: MediaPreviewResource
        if let cached = await cache.acquire(key) {
            resource = cached
        } else {
            let output = try await renderFirstFrame(sourceURL: sourceURL, maximumDimension: dimension)
            do {
                try Task.checkCancellation()
                resource = await cache.insert(output, for: key)
            } catch {
                try? FileManager.default.removeItem(at: output)
                throw error
            }
        }
        try Task.checkCancellation()
        return try withExtendedLifetime(resource) { try Data(contentsOf: resource.url) }
    }

    /// Uncached full-resolution decoding for image conversion. The caller owns and removes the returned PNG.
    static func renderFirstFrame(
        sourceURL: URL,
        maximumDimension: Int? = nil,
        runner: FFmpegCommandRunner = FFmpegCommandRunner()
    ) async throws -> URL {
        try Task.checkCancellation()
        let output = await cache.newURL(extension: "png")
        do {
            try await runner.run(
                firstFrameCommand(sourceURL: sourceURL, outputURL: output, maximumDimension: maximumDimension),
                duration: nil,
                progress: { _ in }
            )
            try Task.checkCancellation()
            guard let image = CGImageSourceCreateWithURL(output as CFURL, nil),
                  CGImageSourceGetCount(image) > 0 else {
                throw ConversionError.engineFailed("The media did not contain a decodable preview frame.")
            }
            TempStorage.allowAccessWhileLocked(at: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// A bounded sample for clipboard waveforms. Avoid decoding an entire long recording for a small thumbnail.
    /// The caller owns this WAV and removes it after sampling. Stereo preserves opposite-phase channels.
    static func renderAudioThumbnailSample(sourceURL: URL) async throws -> URL {
        try Task.checkCancellation()
        let output = await cache.newURL(extension: "wav")
        do {
            let command = "-y -i \(FFmpegCommandRunner.quoted(sourceURL.path)) -vn -map 0:a:0 -af atrim=duration=12 -c:a pcm_s16le -ac 2 -ar 16000 -map_metadata -1 -map_chapters -1 \(FFmpegCommandRunner.quoted(output.path))"
            try await FFmpegCommandRunner().run(command, duration: nil, progress: { _ in })
            try Task.checkCancellation()
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    /// Creates a complete, seekable playback copy only when the native player cannot use the source.
    /// `forceFallback` also bypasses stream-copy after a native player reports a runtime decode failure.
    static func playablePreview(
        sourceURL: URL,
        category: MediaCategory,
        forceFallback: Bool = false,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MediaPreviewResource {
        guard category == .video || category == .audio else {
            throw ConversionError.engineFailed("Playback previews require an audio or video file.")
        }
        try Task.checkCancellation()
        let source = try PreviewSource(sourceURL)
        if forceFallback { await cache.requireDecodedPreview(for: source) }
        let requiresDecode = await cache.requiresDecodedPreview(for: source)
        if !requiresDecode, await isPlayable(sourceURL) {
            try Task.checkCancellation()
            progress(1)
            return MediaPreviewResource(url: sourceURL)
        }
        try Task.checkCancellation()
        let decodedKey = PreviewCacheKey(source: source, variant: "\(category.rawValue)-decoded")
        if let cached = await cache.acquire(decodedKey) {
            try Task.checkCancellation()
            progress(1)
            return cached
        }
        let remuxKey = PreviewCacheKey(source: source, variant: "\(category.rawValue)-remux")
        if !requiresDecode, let cached = await cache.acquire(remuxKey) {
            try Task.checkCancellation()
            progress(1)
            return cached
        }

        let probe = await Task.detached(priority: .userInitiated) {
            FFmpegMediaProbe.probe(at: sourceURL)
        }.value
        try Task.checkCancellation()
        let video = probe?.streams.first { $0.codecType == "video" }
        let audio = probe?.streams.first { $0.codecType == "audio" }
        if let probe, !probe.streams.contains(where: { $0.codecType == category.rawValue }) {
            throw ConversionError.engineFailed("The file does not contain a \(category.rawValue) stream to preview.")
        }
        let duration = (probe?.format?.duration ?? video?.duration ?? audio?.duration)
            .flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let canRemux = !requiresDecode && (category == .audio
            ? audio?.codecName == "aac"
            : ["h264", "hevc"].contains(video?.codecName ?? "") && (audio == nil || audio?.codecName == "aac"))
        let runner = FFmpegCommandRunner()
        if canRemux {
            let output = await cache.newURL(extension: category == .video ? "mp4" : "m4a")
            do {
                try await runner.run(
                    remuxCommand(sourceURL: sourceURL, outputURL: output, category: category,
                                 videoCodec: video?.codecName),
                    duration: duration, progress: { progress($0 * 0.15) }
                )
                try Task.checkCancellation()
                guard await isPlayable(output) else {
                    throw ConversionError.engineFailed("The repackaged preview is not playable on this device.")
                }
                try Task.checkCancellation()
                TempStorage.allowAccessWhileLocked(at: output)
                let resource = await cache.insert(output, for: remuxKey)
                progress(1)
                return resource
            } catch {
                try? FileManager.default.removeItem(at: output)
                try rethrowCancellation(error)
                // A compatible container alone may not fix a codec/profile limitation. Decode below.
            }
        }

        let output = await cache.newURL(extension: category == .video ? "mp4" : "m4a")
        let progressStart = canRemux ? 0.15 : 0
        do {
            let command = category == .video
                ? videoCommand(sourceURL: sourceURL, outputURL: output)
                : audioCommand(sourceURL: sourceURL, outputURL: output, pcm: false)
            try await runner.run(command, duration: duration,
                                 progress: { progress(progressStart + $0 * (0.99 - progressStart)) })
            try Task.checkCancellation()
            guard await isPlayable(output) else {
                throw ConversionError.engineFailed("The converted preview is not playable on this device.")
            }
            try Task.checkCancellation()
            TempStorage.allowAccessWhileLocked(at: output)
            let resource = await cache.insert(output, for: decodedKey)
            progress(1)
            return resource
        } catch {
            try? FileManager.default.removeItem(at: output)
            try rethrowCancellation(error)
            guard category == .audio else { throw error }
        }

        // PCM covers sources for which AAC encoding fails (for example unusual audio layouts).
        let pcmOutput = await cache.newURL(extension: "wav")
        do {
            try await runner.run(audioCommand(sourceURL: sourceURL, outputURL: pcmOutput, pcm: true),
                                 duration: duration, progress: { _ in })
            try Task.checkCancellation()
            guard await isPlayable(pcmOutput) else {
                throw ConversionError.engineFailed("The decoded audio preview is not playable on this device.")
            }
            try Task.checkCancellation()
            TempStorage.allowAccessWhileLocked(at: pcmOutput)
            let resource = await cache.insert(pcmOutput, for: decodedKey)
            progress(1)
            return resource
        } catch {
            try? FileManager.default.removeItem(at: pcmOutput)
            throw error
        }
    }

    // Only options accepted by MBFFmpegBridge's constrained command parser are used here.
    static func firstFrameCommand(sourceURL: URL, outputURL: URL, maximumDimension: Int?) -> String {
        // PNG's automatic format fallback prefers RGB24 for planar-alpha inputs, losing transparency.
        // Keep thumbnail memory bounded; conversion's uncapped decode also preserves >8-bit channel precision.
        let pixelFormat = maximumDimension == nil ? "rgba64be" : "rgba"
        let filter = maximumDimension.map { dimension in
            let edge = max(2, dimension)
            return " -vf \(FFmpegCommandRunner.quoted("scale=w='min(\(edge),iw*sar)':h='min(\(edge),ih)':force_original_aspect_ratio=decrease:reset_sar=1"))"
        } ?? ""
        return "-y -mb-acceleration auto -i \(FFmpegCommandRunner.quoted(sourceURL.path)) -map 0:v:0 -an -frames:v 1 -c:v png -pix_fmt \(pixelFormat)\(filter) -map_metadata -1 -map_chapters -1 \(FFmpegCommandRunner.quoted(outputURL.path))"
    }

    static func remuxCommand(sourceURL: URL, outputURL: URL, category: MediaCategory, videoCodec: String?) -> String {
        let streams = category == .video
            ? "-map 0:v:0 -map 0:a:0? -c:v copy -c:a copy\(videoCodec == "hevc" ? " -tag:v hvc1" : "")"
            : "-vn -map 0:a:0 -c:a copy"
        return "-y -i \(FFmpegCommandRunner.quoted(sourceURL.path)) \(streams) -map_metadata -1 -map_chapters -1 -movflags +faststart \(FFmpegCommandRunner.quoted(outputURL.path))"
    }

    static func videoCommand(sourceURL: URL, outputURL: URL) -> String {
        // Bound preview cost and use even dimensions required by 4:2:0 H.264.
        let filter = "scale=w='min(1280,iw*sar)':h='min(720,ih)':force_original_aspect_ratio=decrease:force_divisible_by=2:reset_sar=1"
        return "-y -mb-acceleration auto -i \(FFmpegCommandRunner.quoted(sourceURL.path)) -map 0:v:0 -map 0:a:0? -vf \(FFmpegCommandRunner.quoted(filter)) -r 30 -c:v h264_videotoolbox -pix_fmt yuv420p -b:v 2000k -c:a aac -b:a 128k -ac 2 -ar 48000 -map_metadata -1 -map_chapters -1 -movflags +faststart \(FFmpegCommandRunner.quoted(outputURL.path))"
    }

    static func audioCommand(sourceURL: URL, outputURL: URL, pcm: Bool) -> String {
        let codec = pcm ? "-c:a pcm_s16le" : "-c:a aac -b:a 160k -movflags +faststart"
        return "-y -i \(FFmpegCommandRunner.quoted(sourceURL.path)) -vn -map 0:a:0 \(codec) -ac 2 -ar 48000 -map_metadata -1 -map_chapters -1 \(FFmpegCommandRunner.quoted(outputURL.path))"
    }

    private static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError { throw error }
        if let conversionError = error as? ConversionError, case .cancelled = conversionError { throw error }
        try Task.checkCancellation()
    }
}

private struct PreviewSource: Hashable, Sendable {
    let url: URL
    let modified: Date?
    let created: Date?
    let bytes: Int?

    init(_ url: URL) throws {
        guard url.isFileURL else {
            throw ConversionError.engineFailed("Preview preparation requires a local media file.")
        }
        // URL caches resource values. Re-read attributes even when SwiftUI retains the same URL across a replacement.
        let freshURL = URL(fileURLWithPath: url.standardizedFileURL.path)
        self.url = freshURL
        let values = try freshURL.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        modified = values.contentModificationDate
        created = values.creationDate
        bytes = values.fileSize
    }
}

private struct PreviewCacheKey: Hashable, Sendable {
    let source: PreviewSource
    let variant: String
}

private actor MediaPreviewCache {
    private struct Entry {
        let key: PreviewCacheKey
        let url: URL
        let bytes: Int
        var accessed: Date
        var leases: Int
    }

    private let directory: URL
    private var entries: [UUID: Entry] = [:]
    private var identifiers: [PreviewCacheKey: UUID] = [:]
    private var decodeRequired: [PreviewSource] = []
    private let maximumBytes = 256 * 1024 * 1024
    private let maximumEntries = 24

    init() {
        // Separate from conversion results, whose cleanup can run while a preview is still open.
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("media-previews", isDirectory: true)
        // A fresh process has no active leases. Clear interrupted output and the previous session's cache.
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        TempStorage.allowAccessWhileLocked(at: directory)
    }

    func newURL(extension suffix: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(suffix)")
    }

    func requiresDecodedPreview(for source: PreviewSource) -> Bool {
        decodeRequired.contains(source)
    }

    func requireDecodedPreview(for source: PreviewSource) {
        decodeRequired.removeAll { $0 == source }
        decodeRequired.append(source)
        if decodeRequired.count > 64 { decodeRequired.removeFirst() }
        for (key, identifier) in identifiers where key.source == source && key.variant.hasSuffix("-remux") {
            identifiers.removeValue(forKey: key)
            if entries[identifier]?.leases == 0 { remove(identifier) }
        }
    }

    func acquire(_ key: PreviewCacheKey) -> MediaPreviewResource? {
        guard let identifier = identifiers[key], var entry = entries[identifier] else { return nil }
        guard FileManager.default.fileExists(atPath: entry.url.path) else {
            remove(identifier)
            return nil
        }
        entry.leases += 1
        entry.accessed = Date()
        entries[identifier] = entry
        return resource(entry.url, identifier: identifier)
    }

    func insert(_ url: URL, for key: PreviewCacheKey) -> MediaPreviewResource {
        if let previous = identifiers[key], entries[previous]?.leases == 0 { remove(previous) }
        let identifier = UUID()
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        entries[identifier] = Entry(key: key, url: url, bytes: bytes, accessed: Date(), leases: 1)
        identifiers[key] = identifier
        prune()
        return resource(url, identifier: identifier)
    }

    private func resource(_ url: URL, identifier: UUID) -> MediaPreviewResource {
        MediaPreviewResource(url: url) { [self] in
            Task { await release(identifier) }
        }
    }

    private func release(_ identifier: UUID) {
        guard var entry = entries[identifier] else { return }
        entry.leases -= 1
        entries[identifier] = entry
        if entry.leases == 0 && identifiers[entry.key] != identifier { remove(identifier) }
        prune()
    }

    private func prune() {
        var bytes = entries.values.reduce(0) { $0 + $1.bytes }
        for (identifier, entry) in entries.sorted(by: { $0.value.accessed < $1.value.accessed }) {
            guard entries.count > maximumEntries || bytes > maximumBytes else { break }
            guard entry.leases == 0 else { continue }
            bytes -= entry.bytes
            remove(identifier)
        }
        // Active playback is never interrupted to enforce a disk limit; its files become evictable on release.
    }

    private func remove(_ identifier: UUID) {
        guard let entry = entries.removeValue(forKey: identifier) else { return }
        if identifiers[entry.key] == identifier { identifiers.removeValue(forKey: entry.key) }
        try? FileManager.default.removeItem(at: entry.url)
    }
}
