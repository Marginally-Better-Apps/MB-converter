import Foundation
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - Media Category

enum MediaCategory: String, Codable, Hashable {
    case video
    case audio
    case image
    case animatedImage
}

// MARK: - Output Format

enum OutputFormat: String, CaseIterable, Identifiable, Hashable, Codable {
    // Video
    case mp4_h264, mp4_hevc, mov, webm

    // Audio
    case mp3, m4a, wav, aac, flac, ogg, opus

    // Image
    case jpg, png, heic, webpImage, tiff

    // Animated
    case gif

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .mp4_h264, .mp4_hevc: "mp4"
        case .mov: "mov"
        case .webm: "webm"
        case .gif: "gif"
        case .mp3: "mp3"
        case .m4a: "m4a"
        case .wav: "wav"
        case .aac: "aac"
        case .flac: "flac"
        case .ogg: "ogg"
        case .opus: "opus"
        case .jpg: "jpg"
        case .png: "png"
        case .heic: "heic"
        case .webpImage: "webp"
        case .tiff: "tiff"
        }
    }

    var displayName: String {
        switch self {
        case .mp4_h264: "MP4 (H.264)"
        case .mp4_hevc: "MP4 (HEVC)"
        case .mov: "MOV"
        case .webm: "WebM"
        case .gif: "GIF"
        case .mp3: "MP3"
        case .m4a: "M4A"
        case .wav: "WAV"
        case .aac: "AAC"
        case .flac: "FLAC"
        case .ogg: "OGG"
        case .opus: "Opus"
        case .jpg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .webpImage: "WebP"
        case .tiff: "TIFF"
        }
    }

    var category: MediaCategory {
        switch self {
        case .mp4_h264, .mp4_hevc, .mov, .webm: .video
        case .gif: .animatedImage
        case .mp3, .m4a, .wav, .aac, .flac, .ogg, .opus: .audio
        case .jpg, .png, .heic, .webpImage, .tiff: .image
        }
    }

    var isLossy: Bool {
        switch self {
        case .mp4_h264, .mp4_hevc, .mov, .webm, .gif,
             .mp3, .m4a, .aac, .ogg, .opus,
             .jpg, .heic, .webpImage:
            true
        case .wav, .flac, .png, .tiff:
            false
        }
    }

    /// Whether this format can hit an arbitrary target size via quality/bitrate tuning.
    /// Lossless formats can only "hit" a target by reducing dimensions.
    var supportsTargetSize: Bool {
        switch self {
        case .webpImage:
            false
        default:
            isLossy
        }
    }

    /// All converter outputs are regular files; copy puts raw bytes on the pasteboard with a matching UTI.
    var supportsClipboardCopy: Bool { true }
}

extension OutputFormat {
    /// Pasteboard type for `UIPasteboard.setData(_:forPasteboardType:)`; falls back when `UTType` has no filename mapping.
    var pasteboardTypeIdentifier: String {
        if let t = UTType(filenameExtension: fileExtension) {
            return t.identifier
        }
        switch self {
        case .mp4_h264, .mp4_hevc: return UTType.mpeg4Movie.identifier
        case .mov: return UTType.quickTimeMovie.identifier
        case .webm: return "org.webmproject.webm"
        case .mp3: return UTType.mp3.identifier
        case .m4a: return UTType.mpeg4Audio.identifier
        case .wav: return UTType.wav.identifier
        case .aac: return "public.aac"
        case .flac: return "org.xiph.flac"
        case .ogg: return "org.xiph.ogg-audio"
        case .opus: return "org.xiph.opus"
        case .jpg: return UTType.jpeg.identifier
        case .png: return UTType.png.identifier
        case .heic: return UTType.heic.identifier
        case .webpImage: return UTType.webP.identifier
        case .tiff: return UTType.tiff.identifier
        case .gif: return UTType.gif.identifier
        }
    }
}

extension OutputFormat {
    /// Muxer for two-pass first pass output. The `null` muxer and `/dev/null` are often unavailable
    /// in iOS `ffmpeg-kit` builds, so pass 1 writes a discard file in temp instead.
    var ffmpegFirstPassMuxerArg: String {
        switch self {
        case .webm: " -f webm"
        case .mov: " -f mov"
        case .mp4_h264, .mp4_hevc: " -f mp4"
        case .mp3, .m4a, .wav, .aac, .flac, .ogg, .opus, .jpg, .png, .heic, .webpImage, .tiff, .gif:
            " -f mp4"
        }
    }

    /// Explicit muxer used for final output when FFmpeg can't infer from extension.
    var ffmpegOutputMuxerArg: String {
        switch self {
        case .webm: " -f webm"
        case .mov: " -f mov"
        case .mp4_h264, .mp4_hevc: " -f mp4"
        case .mp3: " -f mp3"
        // MPEG-4 audio in an .m4a file; `ipod` muxer is absent or flaky in some ffmpeg-kit-min iOS builds.
        case .m4a: " -f mp4"
        case .wav: " -f wav"
        case .aac: " -f adts"
        case .flac: " -f flac"
        case .ogg, .opus: " -f ogg"
        case .jpg: " -f mjpeg"
        case .png: " -f image2"
        case .heic: " -f heif"
        case .webpImage: " -f webp"
        case .tiff: " -f image2"
        case .gif: " -f gif"
        }
    }

    /// HEVC in MP4: `hvc1` sample entry matches what AVFoundation/QuickTime expect; FFmpeg may otherwise mark the stream as `hev1`, which can break in-app preview while VLC still plays the file.
    var ffmpegHEVCContainerTagArg: String {
        switch self {
        case .mp4_hevc: " -tag:v hvc1"
        default: ""
        }
    }

    var supportsVideoRemux: Bool {
        switch self {
        case .mp4_h264, .mp4_hevc, .mov:
            true
        default:
            false
        }
    }

    func canRemuxVideoCodec(_ codec: String?) -> Bool {
        guard supportsVideoRemux, let codec = codec?.normalizedCodecID else {
            return false
        }

        switch self {
        case .mp4_h264:
            return Self.h264CodecIDs.contains(codec)
        case .mp4_hevc:
            return Self.hevcCodecIDs.contains(codec)
        case .mov:
            return Self.h264CodecIDs.contains(codec) || Self.hevcCodecIDs.contains(codec)
        default:
            return false
        }
    }

    func canRemuxAudioCodec(_ codec: String?) -> Bool {
        guard let codec = codec?.normalizedCodecID, !codec.isEmpty else {
            return true
        }

        switch self {
        case .mp4_h264, .mp4_hevc:
            return Self.aacCodecIDs.contains(codec)
        case .mov:
            return Self.aacCodecIDs.contains(codec) || Self.movAudioCodecIDs.contains(codec)
        default:
            return false
        }
    }

    func canRemuxStandaloneAudioCodec(_ codec: String?, inputContainer: String?) -> Bool {
        guard category == .audio else { return false }
        let container = inputContainer?.normalizedCodecID ?? ""
        guard let codec = codec?.normalizedCodecID, !codec.isEmpty else {
            return false
        }

        switch self {
        case .m4a:
            // MPEG-4 audio container: safe stream copy for AAC/ALAC family.
            return Self.aacCodecIDs.contains(codec) || Self.movAudioCodecIDs.contains(codec)
        case .aac:
            // ADTS is AAC elementary stream.
            return Self.aacCodecIDs.contains(codec)
        case .wav:
            // WAV stream copy is only safe for PCM variants across our current runtime builds.
            return Self.wavPCMCodecIDs.contains(codec)
                || codec.hasPrefix("pcm_")
        case .mp3:
            return Self.mp3CodecIDs.contains(codec)
        case .flac:
            return Self.flacCodecIDs.contains(codec)
        case .ogg:
            return Self.vorbisCodecIDs.contains(codec)
        case .opus:
            return Self.opusCodecIDs.contains(codec) && (container == "ogg" || container == "opus")
        default:
            return false
        }
    }

    private static let h264CodecIDs: Set<String> = ["avc1", "avc3", "h264"]
    private static let hevcCodecIDs: Set<String> = ["hvc1", "hev1", "hevc"]
    private static let aacCodecIDs: Set<String> = ["mp4a", "aac"]
    private static let movAudioCodecIDs: Set<String> = ["alac", "lpcm", "sowt", "twos"]
    private static let wavPCMCodecIDs: Set<String> = ["lpcm", "sowt", "twos"]
    private static let mp3CodecIDs: Set<String> = ["mp3", "mp3float", "mp3fixed"]
    private static let flacCodecIDs: Set<String> = ["flac"]
    private static let vorbisCodecIDs: Set<String> = ["vorbis"]
    private static let opusCodecIDs: Set<String> = ["opus"]
}

private extension String {
    var normalizedCodecID: String {
        trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - Media File (Input)

struct MediaFile: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let originalFilename: String
    let category: MediaCategory
    let sizeOnDisk: Int64
    let dimensions: CGSize?         // image, video, animated
    let duration: TimeInterval?     // audio, video, animated
    let fps: Double?                // video, animated
    let bitrate: Int?               // bps; container average (audio, video) or whole file
    /// Audio track only; bps. Populated for video when an audio track exists.
    let audioBitrate: Int?
    let videoCodec: String?
    let audioCodec: String?
    let containerFormat: String     // file extension lowercased

    init(
        id: UUID = UUID(),
        url: URL,
        originalFilename: String,
        category: MediaCategory,
        sizeOnDisk: Int64,
        dimensions: CGSize? = nil,
        duration: TimeInterval? = nil,
        fps: Double? = nil,
        bitrate: Int? = nil,
        audioBitrate: Int? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil,
        containerFormat: String
    ) {
        self.id = id
        self.url = url
        self.originalFilename = originalFilename
        self.category = category
        self.sizeOnDisk = sizeOnDisk
        self.dimensions = dimensions
        self.duration = duration
        self.fps = fps
        self.bitrate = bitrate
        self.audioBitrate = audioBitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.containerFormat = containerFormat
    }
}

// MARK: - Output metadata (EXIF, tags, etc.)

struct MetadataExportPolicy: Hashable, Sendable {
    /// When `true`, all container/EXIF metadata is stripped. When `false`, only the listed tags are written back.
    var stripAll: Bool
    /// Global container tags (FFmpeg `-metadata`); used when `stripAll` is `false`.
    var retainedFormatTags: [String: String]
    /// Per input stream index (as reported by ffprobe) for `-metadata:s:i:key=value`.
    var retainedStreamTags: [Int: [String: String]]
    /// Image metadata split by `ImageMetadataScope` for `CGImageDestination` (Exif, GPS, IPTC, TIFF, …).
    var retainedImageTags: [ImageMetadataEntry]
    /// Stream indices that had tags in the probe; used to reset per-stream metadata before re-applying retained tags.
    var sourceStreamIndicesForTagStrip: [Int]

    static let `default` = MetadataExportPolicy(
        stripAll: true,
        retainedFormatTags: [:],
        retainedStreamTags: [:],
        retainedImageTags: [],
        sourceStreamIndicesForTagStrip: []
    )
}

struct ImageMetadataEntry: Hashable, Sendable, Identifiable {
    var id: String { imagePropertyKey }

    var scope: ImageMetadataScope
    var dictionaryKey: String
    var value: String
    var imagePropertyKey: String
}

/// Where the value lives when writing a still image.
enum ImageMetadataScope: String, Hashable, Sendable {
    case exif
    case gps
    case iptc
    case tiff
    case png // sparse keys on PNG output
    case xmp
}

// MARK: - Crop

/// A crop rectangle in the source media's pixel coordinate space.
struct CropRegion: Hashable, Codable, Sendable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    var dimensions: CGSize {
        CGSize(width: CGFloat(width), height: CGFloat(height))
    }

    var rect: CGRect {
        CGRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height))
    }

    func clamped(to source: CGSize, minimumSize: Double = 8) -> CropRegion? {
        guard source.width > 0, source.height > 0 else { return nil }

        let maxWidth = Double(source.width)
        let maxHeight = Double(source.height)
        let minSize = min(minimumSize, maxWidth, maxHeight)
        let nextWidth = min(max(width, minSize), maxWidth)
        let nextHeight = min(max(height, minSize), maxHeight)
        let nextX = min(max(0, x), maxWidth - nextWidth)
        let nextY = min(max(0, y), maxHeight - nextHeight)

        return CropRegion(
            x: nextX.rounded(),
            y: nextY.rounded(),
            width: nextWidth.rounded(),
            height: nextHeight.rounded()
        )
    }

    func isEffectivelyFullFrame(for source: CGSize) -> Bool {
        guard source.width > 0, source.height > 0 else { return false }
        let clamped = clamped(to: source)
        return clamped?.x == 0
            && clamped?.y == 0
            && clamped?.width == Double(source.width.rounded())
            && clamped?.height == Double(source.height.rounded())
    }

    static func fullFrame(source: CGSize) -> CropRegion? {
        guard source.width > 0, source.height > 0 else { return nil }
        return CropRegion(
            x: 0,
            y: 0,
            width: Double(source.width.rounded()),
            height: Double(source.height.rounded())
        )
    }
}

// MARK: - Conversion Config (User Choices)

enum OutputOperationMode: String, CaseIterable, Identifiable, Hashable, Codable {
    case manual
    case autoTarget

    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual:
            "Manual"
        case .autoTarget:
            "Auto"
        }
    }
}

struct AutoTargetLockPolicy: Hashable, Codable {
    var resolution: Bool
    var fps: Bool
    var audioQuality: Bool

    static let manual = AutoTargetLockPolicy(
        resolution: true,
        fps: true,
        audioQuality: true
    )

    static let unlocked = AutoTargetLockPolicy(
        resolution: false,
        fps: false,
        audioQuality: false
    )
}

struct ConversionConfig: Hashable {
    var outputFormat: OutputFormat
    var targetDimensions: CGSize?           // nil = keep original; never larger than source
    var targetFPS: Double?                  // nil = keep original; never larger than source
    var targetSizeBytes: Int64?             // nil = use defaults / no enforcement
    var cropRegion: CropRegion?             // nil = full frame
    var imageQuality: Double? = nil         // 0...1 single-pass quality for still-image encoders that use quality mode
    var videoQuality: Double? = nil         // 0...1 quality fallback for video when duration/target sizing is unavailable
    var usesSinglePassVideoTargetEncode: Bool
    var frameTimeForExtraction: Double?     // seconds; for video → image conversions
    var preferredAudioBitrateKbps: Int?     // override default for video output's audio track
    var operationMode: OutputOperationMode
    var autoTargetLockPolicy: AutoTargetLockPolicy
    var prefersRemuxWhenPossible: Bool
    var metadata: MetadataExportPolicy

    init(
        outputFormat: OutputFormat,
        targetDimensions: CGSize? = nil,
        targetFPS: Double? = nil,
        targetSizeBytes: Int64? = nil,
        cropRegion: CropRegion? = nil,
        imageQuality: Double? = nil,
        videoQuality: Double? = nil,
        usesSinglePassVideoTargetEncode: Bool = false,
        frameTimeForExtraction: Double? = nil,
        preferredAudioBitrateKbps: Int? = nil,
        operationMode: OutputOperationMode = .manual,
        autoTargetLockPolicy: AutoTargetLockPolicy = .manual,
        prefersRemuxWhenPossible: Bool = false,
        metadata: MetadataExportPolicy = .default
    ) {
        self.outputFormat = outputFormat
        self.targetDimensions = targetDimensions
        self.targetFPS = targetFPS
        self.targetSizeBytes = targetSizeBytes
        self.cropRegion = cropRegion
        self.imageQuality = imageQuality
        self.videoQuality = videoQuality
        self.usesSinglePassVideoTargetEncode = usesSinglePassVideoTargetEncode
        self.frameTimeForExtraction = frameTimeForExtraction
        self.preferredAudioBitrateKbps = preferredAudioBitrateKbps
        self.operationMode = operationMode
        self.autoTargetLockPolicy = autoTargetLockPolicy
        self.prefersRemuxWhenPossible = prefersRemuxWhenPossible
        self.metadata = metadata
    }
}

// MARK: - Conversion Result (Output)

struct ConversionResult: Identifiable, Hashable {
    let id: UUID
    let url: URL                   // tmp file
    let outputFormat: OutputFormat
    let sizeOnDisk: Int64
    let dimensions: CGSize?
    let duration: TimeInterval?
    let fps: Double?
    let bitrate: Int?
    /// Encoded audio stream; bps. Set for video outputs with an audio track.
    let audioBitrate: Int?
    let videoCodec: String?
    let audioCodec: String?

    init(
        id: UUID = UUID(),
        url: URL,
        outputFormat: OutputFormat,
        sizeOnDisk: Int64,
        dimensions: CGSize? = nil,
        duration: TimeInterval? = nil,
        fps: Double? = nil,
        bitrate: Int? = nil,
        audioBitrate: Int? = nil,
        videoCodec: String? = nil,
        audioCodec: String? = nil
    ) {
        self.id = id
        self.url = url
        self.outputFormat = outputFormat
        self.sizeOnDisk = sizeOnDisk
        self.dimensions = dimensions
        self.duration = duration
        self.fps = fps
        self.bitrate = bitrate
        self.audioBitrate = audioBitrate
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
    }
}
