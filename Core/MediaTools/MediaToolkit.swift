import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Video and audio editing for the tools layer.
///
/// Video operations use AVFoundation compositions (multi-input work such as merging and
/// soundtracks isn't part of the FFmpeg adapter's single-input command subset). Audio
/// effects use the adapter's `-af` filter graphs, which are sample-accurate and support
/// gain with limiting, fades and loudness normalization.
enum MediaToolkit {
    struct Probe: Sendable {
        var duration: Double
        var hasVideo: Bool
        var hasAudio: Bool
        /// Display size (preferred transform applied).
        var size: CGSize?
    }

    static func probe(_ url: URL) async throws -> Probe {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var size: CGSize?
        if let track = videoTracks.first {
            let natural = (try? await track.load(.naturalSize)) ?? .zero
            let transform = (try? await track.load(.preferredTransform)) ?? .identity
            let rect = CGRect(origin: .zero, size: natural).applying(transform)
            size = CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
        }
        if videoTracks.isEmpty, audioTracks.isEmpty {
            // AVFoundation can't open MKV/WebM/Ogg; fall back to the FFmpeg-backed inspector.
            let media = try await MediaInspector.inspect(url: url)
            return Probe(
                duration: media.duration ?? 0,
                hasVideo: media.category == .video,
                hasAudio: media.audioCodec != nil || media.category == .audio,
                size: media.dimensions
            )
        }
        return Probe(duration: duration.isFinite ? duration : 0, hasVideo: !videoTracks.isEmpty, hasAudio: !audioTracks.isEmpty, size: size)
    }

    /// Returns a URL AVFoundation can decode, converting exotic containers (MKV, WebM, Ogg…) with the app's converter first.
    static func decodableURL(_ input: URL) async throws -> URL {
        let asset = AVURLAsset(url: input)
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if !video.isEmpty || !audio.isEmpty { return input }
        let media = try await MediaInspector.inspect(url: input)
        let config = ConversionConfig(outputFormat: media.category == .audio ? .m4a : .mp4_h264)
        let converter = try ConversionRouter.converter(for: media, config: config)
        let result = try await converter.convert(input: media, config: config, progress: { _ in }, encodingStats: nil)
        return result.url
    }

    // MARK: - Export

    static func fileType(for url: URL) -> AVFileType {
        switch url.pathExtension.lowercased() {
        case "mov": .mov
        case "m4v": .m4v
        case "m4a": .m4a
        default: .mp4
        }
    }

    /// Exports an asset, reporting progress, and removes partial output on failure.
    static func export(
        _ asset: AVAsset,
        preset: String = AVAssetExportPresetHighestQuality,
        to output: URL,
        timeRange: CMTimeRange? = nil,
        videoComposition: AVVideoComposition? = nil,
        audioMix: AVAudioMix? = nil,
        preservesPitch: Bool = false,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ConversionError.engineFailed("This video can't be exported with the requested settings.")
        }
        var fileType = fileType(for: output)
        if !session.supportedFileTypes.contains(fileType) {
            fileType = session.supportedFileTypes.contains(.mp4) ? .mp4 : (session.supportedFileTypes.first ?? .mov)
        }
        session.outputURL = output
        session.outputFileType = fileType
        session.shouldOptimizeForNetworkUse = true
        if let timeRange { session.timeRange = timeRange }
        if let videoComposition { session.videoComposition = videoComposition }
        if let audioMix { session.audioMix = audioMix }
        if preservesPitch { session.audioTimePitchAlgorithm = .spectral }

        let box = ExportSessionBox(session)
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(box.session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poller.cancel() }
        try await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.session.exportAsynchronously { continuation.resume() }
            }
        } onCancel: {
            box.session.cancelExport()
        }
        switch session.status {
        case .completed:
            progress(1)
        case .cancelled:
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.cancelled
        default:
            try? FileManager.default.removeItem(at: output)
            throw ConversionError.engineFailed(session.error?.localizedDescription ?? "The export failed.")
        }
    }

    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession
        init(_ session: AVAssetExportSession) { self.session = session }
    }

    // MARK: - Video operations

    static func trim(_ input: URL, start: Double, end: Double, precise: Bool, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: try await decodableURL(input))
        let duration = try await asset.load(.duration).seconds
        let lower = max(0, min(start, duration))
        let upper = max(lower + 0.05, min(end, duration))
        let range = CMTimeRange(start: CMTime(seconds: lower, preferredTimescale: 600), end: CMTime(seconds: upper, preferredTimescale: 600))
        let isAudioOnly = (try await asset.loadTracks(withMediaType: .video)).isEmpty
        let preset = isAudioOnly ? AVAssetExportPresetAppleM4A : (precise ? AVAssetExportPresetHighestQuality : AVAssetExportPresetPassthrough)
        try await export(asset, preset: preset, to: output, timeRange: range, progress: progress)
    }

    static func mute(_ input: URL, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: try await decodableURL(input))
        guard let source = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.invalidInput("This file has no video track.")
        }
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.engineFailed("Couldn't prepare the video track.")
        }
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        track.preferredTransform = try await source.load(.preferredTransform)
        try await export(composition, preset: AVAssetExportPresetPassthrough, to: output, progress: progress)
    }

    enum Orientation: String, CaseIterable, Identifiable, Hashable, Sendable {
        case clockwise, counterClockwise, upsideDown, mirror, flipVertical

        var id: String { rawValue }
        var label: String {
            switch self {
            case .clockwise: "Rotate right"
            case .counterClockwise: "Rotate left"
            case .upsideDown: "Rotate 180°"
            case .mirror: "Flip horizontal"
            case .flipVertical: "Flip vertical"
            }
        }

        /// Transform applied after the source's own display transform, plus the resulting render size.
        func transform(for size: CGSize) -> (CGAffineTransform, CGSize) {
            switch self {
            case .clockwise: (CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0), CGSize(width: size.height, height: size.width))
            case .counterClockwise: (CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width), CGSize(width: size.height, height: size.width))
            case .upsideDown: (CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height), size)
            case .mirror: (CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: size.width, ty: 0), size)
            case .flipVertical: (CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height), size)
            }
        }
    }

    /// The display transform of a track, normalized so content starts at the origin.
    static func displayTransform(_ track: AVAssetTrack) async throws -> (CGAffineTransform, CGSize) {
        let natural = try await track.load(.naturalSize)
        let preferred = try await track.load(.preferredTransform)
        let rect = CGRect(origin: .zero, size: natural).applying(preferred)
        let normalized = preferred.concatenating(CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        return (normalized, CGSize(width: abs(rect.width), height: abs(rect.height)))
    }

    static func reorient(_ input: URL, _ orientation: Orientation, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: try await decodableURL(input))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.invalidInput("This file has no video track.")
        }
        let duration = try await asset.load(.duration)
        let (base, size) = try await displayTransform(track)
        let (operation, renderSize) = orientation.transform(for: size)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(base.concatenating(operation), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.renderSize = CGSize(width: evenPixels(renderSize.width), height: evenPixels(renderSize.height))
        composition.frameDuration = try await frameDuration(track)
        composition.instructions = [instruction]
        try await export(asset, to: output, videoComposition: composition, progress: progress)
    }

    static func evenPixels(_ value: CGFloat) -> CGFloat {
        max(2, (value / 2).rounded() * 2)
    }

    static func frameDuration(_ track: AVAssetTrack) async throws -> CMTime {
        let rate = try await track.load(.nominalFrameRate)
        return CMTime(value: 1, timescale: CMTimeScale(rate > 1 ? min(rate.rounded(), 120) : 30))
    }

    static func speed(_ input: URL, factor: Double, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard factor > 0 else { throw ConversionError.invalidInput("Choose a speed above zero.") }
        let asset = AVURLAsset(url: try await decodableURL(input))
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        let fullRange = CMTimeRange(start: .zero, duration: duration)
        var isAudioOnly = true
        for track in try await asset.loadTracks(withMediaType: .video) {
            isAudioOnly = false
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(fullRange, of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(fullRange, of: track, at: .zero)
        }
        let scaled = CMTime(seconds: duration.seconds / factor, preferredTimescale: 600)
        composition.scaleTimeRange(fullRange, toDuration: scaled)
        try await export(composition, preset: isAudioOnly ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality, to: output, preservesPitch: true, progress: progress)
    }

    static func loop(_ input: URL, times: Int, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let asset = AVURLAsset(url: try await decodableURL(input))
        let duration = try await asset.load(.duration)
        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: duration)
        for index in 0 ..< max(1, times) {
            try await composition.insertTimeRange(range, of: asset, at: CMTimeMultiply(duration, multiplier: Int32(index)))
        }
        if let track = try await asset.loadTracks(withMediaType: .video).first,
           let target = try await composition.loadTracks(withMediaType: .video).first {
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        try await export(composition, preset: AVAssetExportPresetPassthrough, to: output, progress: progress)
    }

    /// Joins clips end to end, letterboxing each into the first clip's frame.
    static func concatenateVideos(_ inputs: [URL], output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        guard inputs.count >= 2 else { throw ConversionError.invalidInput("Add at least two videos.") }
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ConversionError.engineFailed("Couldn't prepare the composition.") }
        var cursor = CMTime.zero
        var renderSize: CGSize?
        var frameRate = CMTime(value: 1, timescale: 30)
        var segments: [(range: CMTimeRange, transform: CGAffineTransform, size: CGSize)] = []
        var hasAudio = false
        for url in inputs {
            let asset = AVURLAsset(url: try await decodableURL(url))
            let duration = try await asset.load(.duration)
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                throw ConversionError.invalidInput("“\(url.lastPathComponent)” has no video.")
            }
            let range = CMTimeRange(start: .zero, duration: duration)
            try videoTrack.insertTimeRange(range, of: track, at: cursor)
            if let audio = try await asset.loadTracks(withMediaType: .audio).first {
                try audioTrack.insertTimeRange(range, of: audio, at: cursor)
                hasAudio = true
            }
            let (transform, size) = try await displayTransform(track)
            if renderSize == nil {
                renderSize = size
                frameRate = try await frameDuration(track)
            }
            segments.append((CMTimeRange(start: cursor, duration: duration), transform, size))
            cursor = cursor + duration
        }
        if !hasAudio { composition.removeTrack(audioTrack) }
        let target = renderSize ?? CGSize(width: 1280, height: 720)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        for segment in segments {
            let scale = min(target.width / segment.size.width, target.height / segment.size.height)
            let offset = CGPoint(x: (target.width - segment.size.width * scale) / 2, y: (target.height - segment.size.height * scale) / 2)
            let fit = segment.transform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: offset.x, y: offset.y))
            layer.setTransform(fit, at: segment.range.start)
        }
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: cursor)
        instruction.layerInstructions = [layer]
        instruction.backgroundColor = UIColor.black.cgColor
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: evenPixels(target.width), height: evenPixels(target.height))
        videoComposition.frameDuration = frameRate
        videoComposition.instructions = [instruction]
        try await export(composition, to: output, videoComposition: videoComposition, progress: progress)
    }

    /// Replaces a video's soundtrack, optionally repeating short audio to fill the video.
    static func replaceAudio(video: URL, audio: URL, loopAudio: Bool, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let videoAsset = AVURLAsset(url: try await decodableURL(video))
        let audioAsset = AVURLAsset(url: try await decodableURL(audio))
        guard let videoSource = try await videoAsset.loadTracks(withMediaType: .video).first else {
            throw ConversionError.invalidInput("The video has no video track.")
        }
        guard let audioSource = try await audioAsset.loadTracks(withMediaType: .audio).first else {
            throw ConversionError.invalidInput("The audio file has no audio track.")
        }
        let videoDuration = try await videoAsset.load(.duration)
        let audioDuration = try await audioAsset.load(.duration)
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ConversionError.engineFailed("Couldn't prepare the composition.") }
        try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: videoDuration), of: videoSource, at: .zero)
        videoTrack.preferredTransform = try await videoSource.load(.preferredTransform)
        var cursor = CMTime.zero
        repeat {
            let remaining = videoDuration - cursor
            let chunk = CMTimeMinimum(audioDuration, remaining)
            guard chunk.seconds > 0.01 else { break }
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: chunk), of: audioSource, at: cursor)
            cursor = cursor + chunk
        } while loopAudio && cursor < videoDuration
        try await export(composition, to: output, progress: progress)
    }

    /// Joins audio tracks back to back into one M4A.
    static func concatenateAudio(_ inputs: [URL], output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ConversionError.engineFailed("Couldn't prepare the composition.")
        }
        var cursor = CMTime.zero
        for url in inputs {
            let asset = AVURLAsset(url: try await decodableURL(url))
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else {
                throw ConversionError.invalidInput("“\(url.lastPathComponent)” has no audio.")
            }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            cursor = cursor + duration
        }
        try await export(composition, preset: AVAssetExportPresetAppleM4A, to: output, progress: progress)
    }

    // MARK: - Audio effects (FFmpeg filter graphs)

    struct AudioEdit: Hashable, Sendable {
        var volumeDB: Double = 0
        var fadeIn: Double = 0
        var fadeOut: Double = 0
        var normalize = false

        var isIdentity: Bool { volumeDB == 0 && fadeIn == 0 && fadeOut == 0 && !normalize }

        func filter(duration: Double) -> String {
            var parts: [String] = []
            if normalize { parts.append("loudnorm=I=-16:TP=-1.5:LRA=11") }
            if volumeDB != 0 { parts.append("volume=\(String(format: "%.1f", volumeDB))dB") }
            if fadeIn > 0 { parts.append("afade=t=in:st=0:d=\(String(format: "%.2f", fadeIn))") }
            if fadeOut > 0 { parts.append("afade=t=out:st=\(String(format: "%.2f", max(0, duration - fadeOut))):d=\(String(format: "%.2f", fadeOut))") }
            // Boosts can clip; a limiter keeps peaks below full scale.
            if volumeDB > 0 || normalize { parts.append("alimiter=limit=0.97") }
            return parts.isEmpty ? "anull" : parts.joined(separator: ",")
        }
    }

    static func q(_ url: URL) -> String { FFmpegCommandRunner.quoted(url.path) }

    /// Single-input command: audio filters to AAC in an M4A container.
    static func editAudioCommand(_ input: URL, edit: AudioEdit, duration: Double, output: URL) -> String {
        "-y -i \(q(input)) -vn -af \(FFmpegCommandRunner.quoted(edit.filter(duration: duration))) -c:a aac -b:a 192k -f mp4 \(q(output))"
    }

    static func editAudio(_ input: URL, edit: AudioEdit, output: URL, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let duration = try await probe(input).duration
        try await FFmpegCommandRunner().run(editAudioCommand(input, edit: edit, duration: duration, output: output), duration: duration, progress: progress)
        try verifyOutput(output)
    }

    /// Ensures an output exists and isn't empty.
    static func verifyOutput(_ url: URL) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        guard size > 0 else { throw ConversionError.engineFailed("The output file is empty.") }
    }

    // MARK: - Animation (FFmpeg: palette GIF and animated WebP)

    enum AnimationFormat: String, Sendable {
        case gif, webp
        var fileExtension: String { rawValue }
    }

    /// Single-input command for a looping animation. Frames are capped by count because
    /// the adapter's option subset has no `-t`.
    static func animationCommand(_ input: URL, start: Double, duration: Double?, fps: Int, width: Int,
                                 format: AnimationFormat, quality: Int = 75, output: URL) -> String {
        let scale = "fps=\(fps),scale=\(width):-2:flags=lanczos"
        let seek = start > 0 ? "-ss \(String(format: "%.3f", start)) " : ""
        let frames = duration.map { " -frames:v \(max(1, Int(($0 * Double(fps)).rounded())))" } ?? ""
        switch format {
        case .gif:
            let graph = "\(scale),split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle"
            return "-y \(seek)-i \(q(input))\(frames) -vf \(FFmpegCommandRunner.quoted(graph)) -an -c:v gif -f gif \(q(output))"
        case .webp:
            return "-y \(seek)-i \(q(input))\(frames) -vf \(FFmpegCommandRunner.quoted(scale)) -an -c:v libwebp_anim " +
                "-mb-codec-opt:v quality=\(min(max(quality, 1), 100)) -mb-muxer-opt loop=0 -f webp \(q(output))"
        }
    }

    static func makeAnimation(_ input: URL, start: Double, duration: Double?, fps: Int, width: Int,
                              format: AnimationFormat, quality: Int = 75, output: URL,
                              progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws {
        let command = animationCommand(input, start: start, duration: duration, fps: fps, width: width,
                                       format: format, quality: quality, output: output)
        try await FFmpegCommandRunner().run(command, duration: duration, progress: progress)
        try verifyOutput(output)
    }

    // MARK: - Frames & GIF

    static func frames(_ input: URL, times: [Double], maxSide: Int) async throws -> [CGImage] {
        let url = try await decodableURL(input)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxSide, height: maxSide)
        let tolerance = CMTime(seconds: 0.02, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [CGImage] = []
        for time in times {
            try Task.checkCancellation()
            if let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image {
                images.append(image)
            }
        }
        guard !images.isEmpty else { throw ConversionError.engineFailed("No frames could be decoded from this video.") }
        return images
    }

    static func makeGIF(_ input: URL, start: Double, duration: Double, fps: Int, width: Int) async throws -> Data {
        let count = max(1, Int((duration * Double(fps)).rounded()))
        let times = (0 ..< count).map { start + Double($0) / Double(fps) }
        let frames = try await frames(input, times: times, maxSide: width)
        let sized = frames.map { frame -> CGImage in
            guard frame.width != width else { return frame }
            let height = Int((Double(frame.height) * Double(width) / Double(frame.width)).rounded())
            return ImageToolkit.resize(frame, to: CGSize(width: width, height: height)) ?? frame
        }
        return try ImageToolkit.animatedGIF(sized, frameDelay: 1 / Double(fps), maxSide: max(width, 1))
    }

    static func extractFrames(_ input: URL, everySeconds: Double, duration: Double, maxSide: Int = 4_096) async throws -> [CGImage] {
        let step = max(0.04, everySeconds)
        let times = stride(from: 0, to: max(duration, step / 2), by: step).map { $0 }
        return try await frames(input, times: Array(times.prefix(600)), maxSide: maxSide)
    }
}
