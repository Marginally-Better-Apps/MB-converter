import Foundation

// Standalone test runtime: compile this driver with the production models and
// capability files using Scripts/TestFormatCapabilities.sh, not the real bridge.
enum FFmpegRuntimeInfo {
    static var encoders: Set<String> = []
    static var decoders: Set<String> = []
    static var muxers: Set<String> = []

    static func hasEncoder(_ name: String) -> Bool { encoders.contains(name) }
    static func hasDecoder(_ name: String) -> Bool { decoders.contains(name) }
    static func hasMuxer(_ name: String) -> Bool { muxers.contains(name) }
}

@main
struct CodecCapabilityTests {
    static func main() {
        check(FormatMatrix.allowedOutputs(for: .audio).isEmpty, "Unlinked runtime must not offer audio encoders")
        check(FormatMatrix.allowedOutputs(for: .image).contains(.webpImage), "Separate image libraries must remain usable")

        let audioRequirements: [(OutputFormat, String, String)] = [
            (.mp3, "libmp3lame", "mp3"), (.m4a, "aac", "mp4"),
            (.wav, "pcm_s16le", "wav"), (.aac, "aac", "adts"),
            (.flac, "flac", "flac"), (.ogg, "libvorbis", "ogg"),
            (.opus, "libopus", "ogg")
        ]
        for (format, encoder, muxer) in audioRequirements {
            FFmpegRuntimeInfo.encoders = [encoder]
            FFmpegRuntimeInfo.muxers = []
            check(!CodecCapability.canEncode(format), "\(format) requires its muxer")
            FFmpegRuntimeInfo.encoders = []
            FFmpegRuntimeInfo.muxers = [muxer]
            check(!CodecCapability.canEncode(format), "\(format) requires its encoder")
            FFmpegRuntimeInfo.encoders = [encoder]
            check(CodecCapability.encoderName(for: format) == encoder, "\(format) resolves its actual encoder")
            check(FormatMatrix.allowedOutputs(for: .audio).contains(format), "\(format) is available for audio input")
            check(FormatMatrix.allowedOutputs(for: .video).contains(format), "\(format) is available for audio extraction")
        }

        FFmpegRuntimeInfo.encoders = ["opus"]
        FFmpegRuntimeInfo.muxers = ["ogg"]
        check(!CodecCapability.canEncode(.opus), "Experimental native Opus is not a fallback")
        FFmpegRuntimeInfo.encoders = ["mp3lame"]
        FFmpegRuntimeInfo.muxers = ["mp3"]
        check(!CodecCapability.canEncode(.mp3), "Library catalog names cannot stand in for registered encoders")

        FFmpegRuntimeInfo.encoders = ["libvpx-vp9"]
        FFmpegRuntimeInfo.muxers = ["webm"]
        check(!CodecCapability.canEncode(.webm), "WebM requires Opus audio encoding")
        FFmpegRuntimeInfo.encoders.insert("libopus")
        check(FormatMatrix.allowedOutputs(for: .video).contains(.webm), "VP9, Opus and WebM enable video export")
        FFmpegRuntimeInfo.muxers = []
        check(!CodecCapability.canEncode(.webm), "WebM requires its muxer")

        check(!CodecCapability.canDecode(videoCodec: "av01"), "AV1 requires a decoder")
        FFmpegRuntimeInfo.decoders = ["h264"]
        check(!CodecCapability.canDecode(videoCodec: "av01.0.08M.08"), "AV1 codec strings require an AV1 decoder")
        FFmpegRuntimeInfo.decoders = ["libdav1d"]
        check(CodecCapability.canDecode(videoCodec: "AV1"), "dav1d enables AV1 import")
        FFmpegRuntimeInfo.decoders = ["av1"]
        check(!CodecCapability.canDecode(videoCodec: "av01"), "Hardware-only AV1 registration does not enable the software pipeline")

        for format in OutputFormat.allCases {
            let defaultConfig = ConversionConfig(outputFormat: format)
            let fastConfig = ConversionConfig(outputFormat: format, usesSinglePassVideoTargetEncode: true)
            check(defaultConfig.usesTwoPassVideoEncoding == (format == .webm), "Only VP9 uses a statistics pass, even with legacy configuration defaults")
            check(!fastConfig.usesTwoPassVideoEncoding, "Single-pass requests never run two-pass encoding")
        }
        print("Format capability tests passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
