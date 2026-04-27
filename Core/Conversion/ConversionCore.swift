import CoreGraphics
import Foundation

// MARK: - Errors

enum ConversionError: LocalizedError {
    case unsupportedConversion
    case invalidInput(String)
    case engineFailed(String)
    case cancelled
    case targetUnreachable
    case codecUnavailable(reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedConversion:
            "This conversion isn't supported."
        case .invalidInput(let msg):
            "Invalid input: \(msg)"
        case .engineFailed(let msg):
            "Conversion failed: \(msg)"
        case .cancelled:
            "Cancelled."
        case .targetUnreachable:
            "Couldn't hit the target size with the chosen settings."
        case .codecUnavailable(let reason):
            "Codec unavailable: \(reason)"
        }
    }
}

// MARK: - Converter Protocol

protocol Converter: AnyObject {
    /// Convert a media file according to config. Reports progress 0...1.
    /// `encodingStats` may be called from a background thread when FFmpeg reports `frame= / fps= …` lines.
    func convert(
        input: MediaFile,
        config: ConversionConfig,
        progress: @escaping @Sendable (Double) -> Void,
        encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?
    ) async throws -> ConversionResult

    /// Cancel an in-flight conversion. Idempotent.
    func cancel()
}

// MARK: - Bitrate Calculator

/// Pure functions for translating user-chosen target sizes into bitrates.
/// Two-pass video encoding gives ±2-3% accuracy vs target with these inputs.
enum BitrateCalculator {

    /// Container muxer overhead estimate. ~2% is typical for MP4/MOV/WebM.
    static let muxOverhead: Double = 0.02

    /// Standard CBR audio bitrates (kbps) we snap to.
    static let standardAudioBitrates: [Int] = [32, 64, 96, 128, 160, 192, 256, 320]

    static var minAudioBitrateKbps: Int { standardAudioBitrates.first ?? 32 }

    /// Don't go below this for video — output becomes unwatchable.
    static let minVideoBitrateKbps: Int = 150

    /// Practical floor for high-resolution H.264-like video at 1080p30.
    /// Hardware encoders can ignore very low bitrates, so scale the minimum
    /// by the amount of video being encoded.
    static let h264MinVideoBitsPerPixelPerFrame: Double = 0.045
    static let hevcMinVideoBitsPerPixelPerFrame: Double = 0.025
    static let av1LikeMinVideoBitsPerPixelPerFrame: Double = 0.018
    static let referenceVideoPixels: Double = 1_920.0 * 1_080.0
    static let referenceVideoFPS: Double = 30.0
    static let videoPixelScaleExponent: Double = 0.85
    static let sourceVideoBitrateCeilingRatio: Double = 0.9

    /// Default audio bitrate for video output's audio track when user hasn't specified.
    static let defaultVideoAudioBitrateKbps: Int = 128

    static func maximumAudioEncodeKbps(for format: OutputFormat) -> Int {
        switch format {
        case .m4a:
            // AAC-LC on iOS is most reliable at or below 256 kbps.
            return 256
        default:
            return standardAudioBitrates.last ?? 320
        }
    }

    /// Computes the video bitrate (kbps) needed to hit `targetBytes`,
    /// reserving headroom for the audio track and muxer overhead.
    static func videoBitrateKbps(
        targetBytes: Int64,
        durationSec: Double,
        audioBitrateKbps: Int = defaultVideoAudioBitrateKbps,
        minimumVideoBitrateKbps: Int = minVideoBitrateKbps
    ) -> Int {
        guard durationSec > 0 else { return minimumVideoBitrateKbps }
        let targetBits = Double(targetBytes) * 8.0
        let audioBits  = Double(audioBitrateKbps) * 1000.0 * durationSec
        let overhead   = targetBits * muxOverhead
        let videoBits  = max(0, targetBits - audioBits - overhead)
        let kbps = (videoBits / durationSec) / 1000.0
        return max(minimumVideoBitrateKbps, Int(kbps.rounded()))
    }

    /// Computes the audio bitrate (kbps) for an audio-only target,
    /// snapped to the nearest standard rate.
    static func audioBitrateKbps(
        targetBytes: Int64,
        durationSec: Double
    ) -> Int {
        guard durationSec > 0 else { return 128 }
        let targetBits = Double(targetBytes) * 8.0
        let raw = Int(((targetBits / durationSec) / 1000.0).rounded())
        return snappedAudioBitrate(raw)
    }

    /// Snaps a raw bitrate (kbps) to the nearest standard CBR rate.
    static func snappedAudioBitrate(_ raw: Int) -> Int {
        standardAudioBitrates.min(by: { abs($0 - raw) < abs($1 - raw) }) ?? 128
    }

    /// Estimates total output bytes given video+audio bitrates and duration.
    /// Use this for live UI feedback when user moves the target-size slider.
    static func estimatedSize(
        videoBitrateKbps: Int,
        audioBitrateKbps: Int,
        durationSec: Double
    ) -> Int64 {
        let totalKbps = Double(videoBitrateKbps + audioBitrateKbps)
        let totalBits = totalKbps * 1000.0 * durationSec
        let withOverhead = totalBits * (1.0 + muxOverhead)
        return Int64(withOverhead / 8.0)
    }

    static func minimumAudioTargetBytes(durationSec: Double) -> Int64 {
        guard durationSec > 0 else { return 1 }
        return Int64((Double(minAudioBitrateKbps) * 1000.0 * durationSec / 8.0).rounded(.up))
    }

    /// Plausible maximum output size for lossy audio at the high end of CBR (e.g. 320 kbps), including mux overhead.
    /// Used to cap the target-size slider when extracting audio from a large video.
    static func maximumAudioTargetBytes(
        durationSec: Double,
        maxBitrateKbps: Int = 320
    ) -> Int64 {
        guard durationSec > 0 else { return 1 }
        let bits = Double(maxBitrateKbps) * 1000.0 * durationSec
        let withOverhead = bits * (1.0 + muxOverhead)
        return max(1, Int64((withOverhead / 8.0).rounded(.up)))
    }

    /// Caps encode bitrate (kbps) so we never exceed the source track when known (no upsampling).
    static func capAudioEncodeKbps(requested: Int, sourceBps: Int?, maximumKbps: Int? = nil) -> Int {
        let ceiling = maximumKbps ?? (standardAudioBitrates.last ?? requested)
        let r = min(ceiling, max(minAudioBitrateKbps, requested))
        guard let bps = sourceBps, bps > 0 else { return r }
        let capKbps = bps / 1000
        return min(r, max(1, capKbps))
    }

    static func sourceVideoBitrateBps(totalBitrateBps: Int?, audioBitrateBps: Int?) -> Int? {
        guard let totalBitrateBps, totalBitrateBps > 0 else { return nil }
        let audioBps = max(0, audioBitrateBps ?? 0)
        return max(1, totalBitrateBps - audioBps)
    }

    static func minimumVideoBitrateKbps(
        dimensions: CGSize?,
        fps: Double?,
        outputFormat: OutputFormat,
        sourceVideoBitrateBps: Int? = nil
    ) -> Int {
        guard let dimensions,
              let fps,
              dimensions.width > 0,
              dimensions.height > 0,
              fps > 0
        else {
            return minVideoBitrateKbps
        }

        let pixels = Double(dimensions.width * dimensions.height)
        let pixelScale = pow(pixels / referenceVideoPixels, videoPixelScaleExponent)
        let fpsScale = sqrt(fps / referenceVideoFPS)
        let referenceKbps = referenceVideoPixels
            * referenceVideoFPS
            * minimumBitsPerPixelPerFrame(for: outputFormat)
            / 1000.0
        let uncappedKbps = max(minVideoBitrateKbps, Int((referenceKbps * pixelScale * fpsScale).rounded(.up)))

        guard let sourceVideoBitrateBps, sourceVideoBitrateBps > 0 else {
            return uncappedKbps
        }

        let sourceCapKbps = Int((Double(sourceVideoBitrateBps) * sourceVideoBitrateCeilingRatio / 1000.0).rounded(.down))
        return max(minVideoBitrateKbps, min(uncappedKbps, sourceCapKbps))
    }

    /// Maps a 0...1 quality control to a practical video bitrate when duration is unknown
    /// and byte-accurate target sizing is impossible.
    static func qualityDrivenVideoBitrateKbps(
        quality: Double,
        dimensions: CGSize?,
        fps: Double?,
        outputFormat: OutputFormat,
        sourceVideoBitrateBps: Int? = nil
    ) -> Int {
        let clampedQuality = min(1, max(0, quality))
        let minimumKbps = minimumVideoBitrateKbps(
            dimensions: dimensions,
            fps: fps,
            outputFormat: outputFormat,
            sourceVideoBitrateBps: sourceVideoBitrateBps
        )

        let maximumKbps = qualityDrivenMaximumVideoBitrateKbps(
            dimensions: dimensions,
            fps: fps,
            outputFormat: outputFormat,
            sourceVideoBitrateBps: sourceVideoBitrateBps,
            minimumKbps: minimumKbps
        )
        guard maximumKbps > minimumKbps else { return minimumKbps }

        // Exponential interpolation gives the lower half of the slider usable range
        // while still allowing high bitrates near the top.
        let ratio = Double(maximumKbps) / Double(minimumKbps)
        let kbps = Double(minimumKbps) * pow(ratio, clampedQuality)
        return max(minimumKbps, min(maximumKbps, Int(kbps.rounded())))
    }

    static func minimumVideoTargetBytes(
        durationSec: Double,
        includesAudio: Bool,
        dimensions: CGSize?,
        fps: Double?,
        outputFormat: OutputFormat,
        sourceVideoBitrateBps: Int? = nil,
        maximumAudioBitrateKbps: Int? = nil
    ) -> Int64 {
        guard durationSec > 0 else { return 1 }
        let videoKbps = minimumVideoBitrateKbps(
            dimensions: dimensions,
            fps: fps,
            outputFormat: outputFormat,
            sourceVideoBitrateBps: sourceVideoBitrateBps
        )
        let audioKbps = includesAudio
            ? minimumAudioBitrateForVideoTarget(
                videoBitrateKbps: videoKbps,
                durationSec: durationSec,
                maximumAudioBitrateKbps: maximumAudioBitrateKbps
            )
            : 0
        return estimatedSize(
            videoBitrateKbps: videoKbps,
            audioBitrateKbps: audioKbps,
            durationSec: durationSec
        )
    }

    /// Suggests an audio bitrate that scales with target size — for very small
    /// targets we drop audio quality to leave more room for video.
    static func suggestedAudioBitrate(
        for targetBytes: Int64,
        durationSec: Double
    ) -> Int {
        guard durationSec > 0 else { return defaultVideoAudioBitrateKbps }
        let targetTotalKbps = (Double(targetBytes) * 8.0) / durationSec / 1000.0
        switch targetTotalKbps {
        case ..<300:    return 64
        case 300..<800: return 96
        case 800..<2000: return 128
        default:        return 192
        }
    }

    private static func minimumAudioBitrateForVideoTarget(
        videoBitrateKbps: Int,
        durationSec: Double,
        maximumAudioBitrateKbps: Int?
    ) -> Int {
        var audioKbps = 64
        for _ in 0..<4 {
            let targetBytes = estimatedSize(
                videoBitrateKbps: videoBitrateKbps,
                audioBitrateKbps: audioKbps,
                durationSec: durationSec
            )
            let suggestedAudioKbps = suggestedAudioBitrate(for: targetBytes, durationSec: durationSec)
            let nextAudioKbps = maximumAudioBitrateKbps.map { min(suggestedAudioKbps, $0) } ?? suggestedAudioKbps
            if nextAudioKbps == audioKbps {
                return audioKbps
            }
            audioKbps = nextAudioKbps
        }
        return audioKbps
    }

    private static func minimumBitsPerPixelPerFrame(for format: OutputFormat) -> Double {
        switch format {
        case .mp4_hevc:
            hevcMinVideoBitsPerPixelPerFrame
        case .webm:
            av1LikeMinVideoBitsPerPixelPerFrame
        default:
            h264MinVideoBitsPerPixelPerFrame
        }
    }

    private static func qualityMaximumBitsPerPixelPerFrame(for format: OutputFormat) -> Double {
        switch format {
        case .mp4_hevc:
            0.10
        case .webm:
            0.075
        default:
            0.14
        }
    }

    private static func qualityDrivenMaximumVideoBitrateKbps(
        dimensions: CGSize?,
        fps: Double?,
        outputFormat: OutputFormat,
        sourceVideoBitrateBps: Int?,
        minimumKbps: Int
    ) -> Int {
        if let sourceVideoBitrateBps, sourceVideoBitrateBps > 0 {
            let sourceKbps = max(minimumKbps, Int((Double(sourceVideoBitrateBps) / 1000.0).rounded()))
            return max(minimumKbps, sourceKbps)
        }

        guard let dimensions,
              dimensions.width > 0,
              dimensions.height > 0
        else {
            return max(minimumKbps, 8_000)
        }

        let effectiveFPS = max(1, fps ?? referenceVideoFPS)
        let pixels = Double(dimensions.width * dimensions.height)
        let kbps = pixels
            * effectiveFPS
            * qualityMaximumBitsPerPixelPerFrame(for: outputFormat)
            / 1000.0
        return max(minimumKbps, Int(kbps.rounded(.up)))
    }
}

// MARK: - Auto Target Planning

struct AutoTargetVideoPlan: Hashable {
    let targetDimensions: CGSize?
    let targetFPS: Double?
    let audioBitrateKbps: Int
    let videoBitrateKbps: Int
    let estimatedSizeBytes: Int64
    let isTargetReachable: Bool
}

struct AutoTargetImagePlan: Hashable {
    let targetDimensions: CGSize?
    let estimatedMinimumSizeBytes: Int64
    let isTargetReachable: Bool
}

enum AutoTargetPlanner {
    static func videoPlan(
        input: MediaFile,
        config: ConversionConfig,
        includesAudio: Bool
    ) -> AutoTargetVideoPlan {
        videoPlan(
            input: input,
            outputFormat: config.outputFormat,
            targetBytes: config.targetSizeBytes ?? input.sizeOnDisk,
            lockedDimensions: config.targetDimensions,
            lockedFPS: config.targetFPS,
            preferredAudioBitrateKbps: config.preferredAudioBitrateKbps,
            lockPolicy: config.autoTargetLockPolicy,
            includesAudio: includesAudio
        )
    }

    static func videoPlan(
        input: MediaFile,
        outputFormat: OutputFormat,
        targetBytes: Int64,
        lockedDimensions: CGSize?,
        lockedFPS: Double?,
        preferredAudioBitrateKbps: Int?,
        lockPolicy: AutoTargetLockPolicy,
        includesAudio: Bool
    ) -> AutoTargetVideoPlan {
        let duration = input.duration ?? 0
        let sourceVideoBitrateBps = BitrateCalculator.sourceVideoBitrateBps(
            totalBitrateBps: input.bitrate,
            audioBitrateBps: input.audioBitrate
        )
        let dimensions = dimensionCandidates(
            source: input.dimensions,
            lockedDimensions: lockedDimensions,
            isLocked: lockPolicy.resolution
        )
        let frameRates = fpsCandidates(
            sourceFPS: input.fps,
            lockedFPS: lockedFPS,
            isLocked: lockPolicy.fps
        )
        let audioBitrates = audioCandidates(
            targetBytes: targetBytes,
            duration: duration,
            input: input,
            outputFormat: outputFormat,
            preferredAudioBitrateKbps: preferredAudioBitrateKbps,
            isLocked: lockPolicy.audioQuality,
            includesAudio: includesAudio && input.audioCodec != nil
        )

        if duration <= 0 {
            let dimension = dimensions.first
            let frameRate = frameRates.first
            let audioKbps = audioBitrates.first ?? 0
            let minimumVideoKbps = BitrateCalculator.minimumVideoBitrateKbps(
                dimensions: dimension?.actual,
                fps: frameRate?.actual,
                outputFormat: outputFormat,
                sourceVideoBitrateBps: sourceVideoBitrateBps
            )
            let sourceVideoKbps = sourceVideoBitrateBps.map { max(1, $0 / 1000) } ?? minimumVideoKbps
            let videoKbps = max(minimumVideoKbps, sourceVideoKbps)
            return AutoTargetVideoPlan(
                targetDimensions: dimension?.target ?? lockedDimensions,
                targetFPS: frameRate?.target ?? lockedFPS,
                audioBitrateKbps: audioKbps,
                videoBitrateKbps: videoKbps,
                estimatedSizeBytes: max(1, input.sizeOnDisk),
                isTargetReachable: false
            )
        }

        var fallback: AutoTargetVideoPlan?
        for dimension in dimensions {
            for frameRate in frameRates {
                let minimumVideoKbps = BitrateCalculator.minimumVideoBitrateKbps(
                    dimensions: dimension.actual,
                    fps: frameRate.actual,
                    outputFormat: outputFormat,
                    sourceVideoBitrateBps: sourceVideoBitrateBps
                )

                for audioKbps in audioBitrates {
                    let minimumSize = BitrateCalculator.estimatedSize(
                        videoBitrateKbps: minimumVideoKbps,
                        audioBitrateKbps: audioKbps,
                        durationSec: duration
                    )
                    let videoKbps = BitrateCalculator.videoBitrateKbps(
                        targetBytes: targetBytes,
                        durationSec: duration,
                        audioBitrateKbps: audioKbps,
                        minimumVideoBitrateKbps: minimumVideoKbps
                    )
                    let estimatedSize = BitrateCalculator.estimatedSize(
                        videoBitrateKbps: videoKbps,
                        audioBitrateKbps: audioKbps,
                        durationSec: duration
                    )
                    let plan = AutoTargetVideoPlan(
                        targetDimensions: dimension.target,
                        targetFPS: frameRate.target,
                        audioBitrateKbps: audioKbps,
                        videoBitrateKbps: videoKbps,
                        estimatedSizeBytes: estimatedSize,
                        isTargetReachable: minimumSize <= targetBytes
                    )

                    if minimumSize <= targetBytes {
                        return plan
                    }

                    fallback = AutoTargetVideoPlan(
                        targetDimensions: dimension.target,
                        targetFPS: frameRate.target,
                        audioBitrateKbps: audioKbps,
                        videoBitrateKbps: minimumVideoKbps,
                        estimatedSizeBytes: minimumSize,
                        isTargetReachable: false
                    )
                }
            }
        }

        return fallback ?? AutoTargetVideoPlan(
            targetDimensions: lockedDimensions,
            targetFPS: lockedFPS,
            audioBitrateKbps: 0,
            videoBitrateKbps: BitrateCalculator.minVideoBitrateKbps,
            estimatedSizeBytes: BitrateCalculator.estimatedSize(
                videoBitrateKbps: BitrateCalculator.minVideoBitrateKbps,
                audioBitrateKbps: 0,
                durationSec: duration
            ),
            isTargetReachable: false
        )
    }

    static func minimumVideoTargetBytes(
        input: MediaFile,
        outputFormat: OutputFormat,
        lockedDimensions: CGSize?,
        lockedFPS: Double?,
        preferredAudioBitrateKbps: Int?,
        lockPolicy: AutoTargetLockPolicy,
        includesAudio: Bool
    ) -> Int64 {
        videoPlan(
            input: input,
            outputFormat: outputFormat,
            targetBytes: 1,
            lockedDimensions: lockedDimensions,
            lockedFPS: lockedFPS,
            preferredAudioBitrateKbps: preferredAudioBitrateKbps,
            lockPolicy: lockPolicy,
            includesAudio: includesAudio
        ).estimatedSizeBytes
    }

    static func imagePlan(
        input: MediaFile,
        outputFormat: OutputFormat,
        targetBytes: Int64,
        lockedDimensions: CGSize?,
        lockPolicy: AutoTargetLockPolicy
    ) -> AutoTargetImagePlan {
        let dimensions = dimensionCandidates(
            source: input.dimensions,
            lockedDimensions: lockedDimensions,
            isLocked: lockPolicy.resolution
        )

        var fallback: AutoTargetImagePlan?
        for dimension in dimensions {
            let minimumSize = minimumImageTargetBytes(
                outputFormat: outputFormat,
                dimensions: dimension.actual,
                fallbackSize: input.sizeOnDisk
            )
            let plan = AutoTargetImagePlan(
                targetDimensions: dimension.target,
                estimatedMinimumSizeBytes: minimumSize,
                isTargetReachable: minimumSize <= targetBytes
            )

            if minimumSize <= targetBytes {
                return plan
            }

            fallback = plan
        }

        return fallback ?? AutoTargetImagePlan(
            targetDimensions: lockedDimensions,
            estimatedMinimumSizeBytes: max(1, input.sizeOnDisk / 100),
            isTargetReachable: false
        )
    }

    static func minimumImageTargetBytes(
        input: MediaFile,
        outputFormat: OutputFormat,
        lockedDimensions: CGSize?,
        lockPolicy: AutoTargetLockPolicy
    ) -> Int64 {
        imagePlan(
            input: input,
            outputFormat: outputFormat,
            targetBytes: 1,
            lockedDimensions: lockedDimensions,
            lockPolicy: lockPolicy
        ).estimatedMinimumSizeBytes
    }

    private struct DimensionCandidate {
        let target: CGSize?
        let actual: CGSize?
    }

    private struct FPSCandidate {
        let target: Double?
        let actual: Double?
    }

    private static func dimensionCandidates(
        source: CGSize?,
        lockedDimensions: CGSize?,
        isLocked: Bool
    ) -> [DimensionCandidate] {
        if isLocked {
            return [DimensionCandidate(target: lockedDimensions, actual: lockedDimensions ?? source)]
        }
        guard let source, source.width > 0, source.height > 0 else {
            return [DimensionCandidate(target: nil, actual: nil)]
        }

        var candidates = [DimensionCandidate(target: nil, actual: source)]
        for edge in [1440.0, 1080.0, 720.0, 480.0, 360.0] {
            let size = scaledDimensions(presetShortEdge: edge, source: source)
            if !containsEquivalentDimension(size, in: candidates) {
                candidates.append(DimensionCandidate(target: size, actual: size))
            }
        }
        return candidates
    }

    private static func fpsCandidates(
        sourceFPS: Double?,
        lockedFPS: Double?,
        isLocked: Bool
    ) -> [FPSCandidate] {
        if isLocked {
            return [FPSCandidate(target: lockedFPS, actual: lockedFPS ?? sourceFPS)]
        }
        guard let sourceFPS, sourceFPS > 0 else {
            return [FPSCandidate(target: nil, actual: nil)]
        }

        var candidates = [FPSCandidate(target: nil, actual: sourceFPS)]
        for fps in [60.0, 30.0, 24.0, 15.0] where fps <= sourceFPS.rounded(.up) {
            if !candidates.contains(where: { $0.actual.map { abs($0 - fps) < 0.1 } ?? false }) {
                candidates.append(FPSCandidate(target: fps, actual: fps))
            }
        }
        return candidates
    }

    private static func audioCandidates(
        targetBytes: Int64,
        duration: Double,
        input: MediaFile,
        outputFormat: OutputFormat,
        preferredAudioBitrateKbps: Int?,
        isLocked: Bool,
        includesAudio: Bool
    ) -> [Int] {
        guard includesAudio else { return [0] }

        func capped(_ kbps: Int) -> Int {
            let formatCapped = outputFormat == .webm ? min(kbps, 128) : kbps
            return BitrateCalculator.capAudioEncodeKbps(
                requested: formatCapped,
                sourceBps: input.audioBitrate
            )
        }

        let suggested = BitrateCalculator.suggestedAudioBitrate(
            for: targetBytes,
            durationSec: duration
        )
        if isLocked {
            let sourceKbps = input.audioBitrate.map { max(1, $0 / 1000) }
            return [capped(preferredAudioBitrateKbps ?? sourceKbps ?? suggested)]
        }

        let raw = [192, 160, 128, 96, 64, 48, 32, suggested]
        var candidates: [Int] = []
        for kbps in raw.map(capped).sorted(by: >) where !candidates.contains(kbps) {
            candidates.append(kbps)
        }
        return candidates.isEmpty ? [capped(suggested)] : candidates
    }

    private static func scaledDimensions(presetShortEdge: Double, source: CGSize) -> CGSize {
        let shortEdge = min(Double(source.width), Double(source.height))
        guard shortEdge > 0 else { return source }
        let scale = min(1, presetShortEdge / shortEdge)
        return CGSize(
            width: (Double(source.width) * scale).rounded(),
            height: (Double(source.height) * scale).rounded()
        )
    }

    private static func containsEquivalentDimension(
        _ size: CGSize,
        in candidates: [DimensionCandidate]
    ) -> Bool {
        candidates.contains { candidate in
            guard let actual = candidate.actual else { return false }
            return Int(actual.width.rounded()) == Int(size.width.rounded())
                && Int(actual.height.rounded()) == Int(size.height.rounded())
        }
    }

    private static func minimumImageTargetBytes(
        outputFormat: OutputFormat,
        dimensions: CGSize?,
        fallbackSize: Int64
    ) -> Int64 {
        guard let dimensions else {
            return max(1, fallbackSize / 100)
        }

        let pixels = max(1, dimensions.width * dimensions.height)
        let bytesPerPixel: Double
        switch outputFormat {
        case .heic, .webpImage:
            bytesPerPixel = 0.035
        case .jpg:
            bytesPerPixel = 0.05
        default:
            bytesPerPixel = 0.08
        }

        return Int64((pixels * bytesPerPixel).rounded(.up)) + 2_048
    }
}

// MARK: - Video encode dimensions

/// H.264/HEVC/VP9 encoders expect even width/height; odd sizes can produce chroma edge artifacts (e.g. a green line on the right).
enum VideoEncodeDimensions {
    static func even(width: Int, height: Int) -> (width: Int, height: Int)? {
        guard width > 0, height > 0 else { return nil }
        let w = max(2, width - width % 2)
        let h = max(2, height - height % 2)
        return (w, h)
    }
}

// MARK: - Temp Storage

/// All conversion outputs land in app's temp dir under /conversions.
/// Cleaned on app launch and when user starts a new conversion flow.
enum TempStorage {

    static var directory: URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("conversions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Returns a unique URL inside the conversions directory with the right extension.
    static func url(for format: OutputFormat) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(format.fileExtension)")
    }

    /// Returns a unique URL with a custom extension (used for ffmpeg pass logs etc.)
    static func url(extension ext: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    /// Removes everything under /conversions. Call on app launch and after result dismissal.
    static func cleanAll() {
        let dir = directory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
        ) else { return }
        for url in contents {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
