import Foundation

/// Tuning and routing for **audio output** conversions (not embedded video audio).
enum AudioExportParameters {
    /// Practical AAC cap used by app controls and encode planning.
    static let maxAACKbps: Int = 320

    static func validate(_ edits: AudioEditSettings, sourceDuration: Double) throws {
        let end = edits.trimEnd ?? sourceDuration
        guard sourceDuration.isFinite, sourceDuration > 0,
              edits.trimStart.isFinite, end.isFinite,
              edits.trimStart >= 0, end <= sourceDuration + 0.001, end > edits.trimStart,
              edits.volume.isFinite, (0...2).contains(edits.volume),
              edits.speed.isFinite, (0.5...2).contains(edits.speed) else {
            throw ConversionError.invalidInput("Choose a valid audio range, volume, and speed.")
        }
    }

    static func number(_ value: Double) -> String {
        String(format: "%.9f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    /// The input is sought to trimStart before this graph. atrim removes decoder
    /// preroll sample-accurately; resetting timestamps keeps every export at zero.
    /// Preview and final export use exactly the same graph.
    static func filter(_ edits: AudioEditSettings, sourceDuration: Double, sourceChannels: Int,
                       sourceSampleRate: Int = 44_100) -> String {
        let length = min(edits.trimEnd ?? sourceDuration, sourceDuration) - edits.trimStart
        var filters = ["atrim=start=0:duration=\(number(length))", "asetpts=PTS-STARTPTS"]
        switch edits.channels {
        case .left: filters.append("pan=mono|c0=c0")
        case .right: filters.append("pan=mono|c0=c\(sourceChannels > 1 ? 1 : 0)")
        case .mono: filters.append("aformat=channel_layouts=mono")
        case .stereo: filters.append("aformat=channel_layouts=stereo")
        case .original: break
        }
        if edits.speed != 1 {
            if edits.preservePitch {
                filters.append("atempo=\(number(edits.speed))")
            } else {
                let shiftedSampleRate = Int((Double(sourceSampleRate) * edits.speed).rounded())
                filters.append("asetrate=\(shiftedSampleRate),aresample=\(sourceSampleRate)")
            }
        }
        if edits.volume != 1 { filters.append("volume=\(number(edits.volume))") }
        if edits.volume > 1, edits.limiterEnabled {
            // Disable auto makeup gain; compensate lookahead so boosted audio
            // doesn't acquire a leading delay or lose its final samples.
            filters.append("alimiter=limit=0.98:level=false:latency=true")
        }
        return filters.joined(separator: ",")
    }

    /// Video audio edits preserve the video's duration and synchronization.
    static func videoTrackFilter(_ edits: AudioEditSettings, sourceChannels: Int) -> String? {
        var filters: [String] = []
        switch edits.channels {
        case .left: filters.append("pan=mono|c0=c0")
        case .right: filters.append("pan=mono|c0=c\(sourceChannels > 1 ? 1 : 0)")
        case .mono: filters.append("aformat=channel_layouts=mono")
        case .stereo: filters.append("aformat=channel_layouts=stereo")
        case .original: break
        }
        if edits.volume != 1 { filters.append("volume=\(number(edits.volume))") }
        if edits.volume > 1, edits.limiterEnabled {
            filters.append("alimiter=limit=0.98:level=false:latency=true")
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }
}
