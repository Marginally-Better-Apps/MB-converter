import Foundation
import ImageIO
import UniformTypeIdentifiers

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
        let encoder: String
        let muxer: String
        switch format {
        case .mp4_h264:
            (encoder, muxer) = ("h264_videotoolbox", "mp4")
        case .mov:
            (encoder, muxer) = ("h264_videotoolbox", "mov")
        case .mp4_hevc:
            (encoder, muxer) = ("hevc_videotoolbox", "mp4")
        case .webm:
            // WebM output includes Opus audio when the input has an audio track.
            guard FFmpegRuntimeInfo.hasEncoder("libopus") else { return nil }
            (encoder, muxer) = ("libvpx-vp9", "webm")
        case .alac:
            (encoder, muxer) = ("alac", "mp4")
        case .aiff:
            (encoder, muxer) = ("pcm_s16be", "aiff")
        case .caf:
            (encoder, muxer) = ("pcm_s16le", "caf")
        case .mp3:
            (encoder, muxer) = ("libmp3lame", "mp3")
        case .m4a:
            (encoder, muxer) = ("aac", "mp4")
        case .aac:
            (encoder, muxer) = ("aac", "adts")
        case .wav:
            (encoder, muxer) = ("pcm_s16le", "wav")
        case .flac:
            (encoder, muxer) = ("flac", "flac")
        case .ogg:
            (encoder, muxer) = ("libvorbis", "ogg")
        case .opus:
            (encoder, muxer) = ("libopus", "ogg")
        // Still-image conversion uses ImageIO/Core Image and its separate WebP library.
        // Those paths must not disappear when FFmpeg excludes an image encoder.
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
        case .bmp, .ico, .jpeg2000, .avif, .tga, .psd, .exr, .icns:
            guard let type = UTType(filenameExtension: format.fileExtension),
                  (CGImageDestinationCopyTypeIdentifiers() as? [String])?.contains(type.identifier) == true else { return nil }
            return format.rawValue
        case .pdf, .docx, .odt, .rtf, .txt, .markdown, .html, .csv, .tsv, .json, .zip, .gzip:
            return "native"
        case .gif:
            (encoder, muxer) = ("gif", "gif")
        }
        return FFmpegRuntimeInfo.hasEncoder(encoder) && FFmpegRuntimeInfo.hasMuxer(muxer)
            ? encoder : nil
    }

    static func unsupportedReason(for format: OutputFormat) -> String? {
        guard !canEncode(format) else { return nil }

        switch format {
        case .webm:
            return "WebM output requires the VP9 and Opus encoders and WebM muxer in the bundled FFmpeg runtime."
        case .mp3:
            return "MP3 output requires the LAME encoder and MP3 muxer in the bundled FFmpeg runtime."
        case .ogg:
            return "OGG output requires the Vorbis encoder and Ogg muxer in the bundled FFmpeg runtime."
        case .opus:
            return "Opus output requires the libopus encoder and Ogg muxer in the bundled FFmpeg runtime."
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
        case .image, .animatedImage, .document, .data, .archive, .file:
            return nil
        }
    }

    static func decodeIssue(videoCodec: String?) -> DecodeIssue? {
        guard let codec = normalizedCodec(videoCodec), !codec.isEmpty else { return nil }
        // FFmpeg's native "av1" decoder uses hardware frames. This adapter's
        // filter pipeline explicitly selects the bundled dav1d software decoder.
        if (av1CodecIDs.contains(codec) || codec.hasPrefix("av01")),
           !FFmpegRuntimeInfo.hasDecoder("libdav1d") {
            return DecodeIssue(
                codecLabel: displayCodecLabel(videoCodec),
                reason: "The dav1d AV1 decoder is not included in the bundled FFmpeg runtime."
            )
        }
        return nil
    }

    static func decodeIssue(audioCodec: String?) -> DecodeIssue? {
        guard let codec = normalizedCodec(audioCodec), !codec.isEmpty else { return nil }
        if unsupportedAudioCodecIDs.contains(codec) {
            return DecodeIssue(
                codecLabel: displayCodecLabel(audioCodec),
                reason: "\(displayCodecLabel(audioCodec)) audio is not decodable by the bundled FFmpeg runtime."
            )
        }
        return nil
    }

    private static let av1CodecIDs: Set<String> = ["av1", "av01"]
    private static let unsupportedAudioCodecIDs: Set<String> = []

    private static func normalizedCodec(_ codec: String?) -> String? {
        codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func displayCodecLabel(_ codec: String?) -> String {
        let trimmed = codec?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "an unknown codec" : trimmed.uppercased()
    }
}
