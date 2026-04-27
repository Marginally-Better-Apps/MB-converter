import Foundation

enum CodecCapability {
    struct DecodeIssue: Hashable, Sendable {
        let codecLabel: String
        let reason: String
    }

    static func canEncode(_ format: OutputFormat) -> Bool {
        encoderName(for: format) != nil
    }

    static func canDecode(videoCodec: String?) -> Bool {
        decodeIssue(videoCodec: videoCodec) == nil
    }

    static func canDecode(audioCodec: String?) -> Bool {
        decodeIssue(audioCodec: audioCodec) == nil
    }

    static func encoderName(for format: OutputFormat) -> String? {
        switch format {
        case .mp4_h264, .mov:
            return "h264_videotoolbox"
        case .mp4_hevc:
            return "hevc_videotoolbox"
        case .webm:
            return runtimeHasExternalLibrary("libvpx") ? "libvpx-vp9" : nil
        case .mp3:
            return runtimeHasExternalLibrary("libmp3lame") ? "libmp3lame" : nil
        case .m4a, .aac:
            return "aac"
        case .wav:
            return "pcm_s16le"
        case .flac:
            return "flac"
        case .ogg:
            return runtimeHasExternalLibrary("libvorbis") ? "libvorbis" : nil
        case .opus:
            return runtimeHasExternalLibrary("libopus") ? "libopus" : "opus"
        case .jpg:
            return "mjpeg"
        case .png:
            return "png"
        case .heic:
            return "heic"
        case .webpImage:
            return "libwebp"
        case .tiff:
            return "tiff"
        case .gif:
            return "gif"
        }
    }

    static func unsupportedReason(for format: OutputFormat) -> String? {
        guard !canEncode(format) else { return nil }

        switch format {
        case .webm:
            return "WebM video output needs the libvpx encoder, which is not included in the bundled FFmpegKit min package."
        case .mp3:
            return "MP3 output needs the libmp3lame encoder, which is not included in the bundled FFmpegKit min package."
        case .ogg:
            return "OGG/Vorbis output needs the libvorbis encoder, which is not included in the bundled FFmpegKit min package."
        default:
            return "\(format.displayName) output is not available in the bundled FFmpeg runtime."
        }
    }

    static func decodeIssue(for media: MediaFile) -> DecodeIssue? {
        switch media.category {
        case .video:
            return decodeIssue(videoCodec: media.videoCodec) ?? decodeIssue(audioCodec: media.audioCodec)
        case .audio:
            return decodeIssue(audioCodec: media.audioCodec)
        case .image, .animatedImage:
            return nil
        }
    }

    static func decodeIssue(videoCodec: String?) -> DecodeIssue? {
        guard let codec = normalizedCodec(videoCodec), !codec.isEmpty else { return nil }
        if av1CodecIDs.contains(codec) || codec.hasPrefix("av01") {
            return DecodeIssue(
                codecLabel: displayCodecLabel(videoCodec),
                reason: "AV1 video is not decodable by the bundled FFmpegKit min package."
            )
        }
        return nil
    }

    static func decodeIssue(audioCodec: String?) -> DecodeIssue? {
        guard let codec = normalizedCodec(audioCodec), !codec.isEmpty else { return nil }
        if unsupportedAudioCodecIDs.contains(codec) {
            return DecodeIssue(
                codecLabel: displayCodecLabel(audioCodec),
                reason: "\(displayCodecLabel(audioCodec)) audio is not decodable by the bundled FFmpegKit min package."
            )
        }
        return nil
    }

    private static let av1CodecIDs: Set<String> = ["av1", "av01"]
    private static let unsupportedAudioCodecIDs: Set<String> = []

    private static func runtimeHasExternalLibrary(_ name: String) -> Bool {
        FFmpegRuntimeInfo.current.hasExternalLibrary(name)
    }

    private static func normalizedCodec(_ codec: String?) -> String? {
        codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayCodecLabel(_ codec: String?) -> String {
        let trimmed = codec?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "an unknown codec" : trimmed.uppercased()
    }
}
