import Foundation
import UniformTypeIdentifiers

/// Source of truth for what conversions are allowed.
/// Add new mappings here when expanding format support.
enum FormatMatrix {
    static let supportedVideoFilenameExtensions: [String] = [
        "mjpeg", "mjpg",
        "webm", "mkv", "ts", "mts", "m2ts", "3gp", "hevc",
        "mp4", "m4v", "mov", "avi", "mpeg", "mpg", "f4v", "flv", "m2v",
        "mxf", "ogv", "vob", "asf", "wmv", "wtv", "swf"
    ]
    static let supportedAudioFilenameExtensions: [String] = [
        "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "alac", "aiff", "aif", "caf", "wma", "ac3", "aifc", "amr", "ape", "au", "mka", "m4b", "oga", "wv"
    ]

    private static let supportedVideoFilenameExtensionSet = Set(supportedVideoFilenameExtensions)
    private static let supportedAudioFilenameExtensionSet = Set(supportedAudioFilenameExtensions)

    /// Candidate outputs, filtered against the encoders and muxers in this app build.
    static func allowedOutputs(for category: MediaCategory) -> [OutputFormat] {
        let formats: [OutputFormat] = switch category {
        case .video:
            [
                // Same-category
                .mp4_h264, .mp4_hevc, .mov, .webm,
                .jpg, .png,
                // Audio extraction
                .m4a, .mp3, .wav, .aac, .flac, .ogg, .opus, .alac, .aiff, .caf
            ]
        case .audio:
            [.m4a, .mp3, .wav, .aac, .flac, .ogg, .opus, .alac, .aiff, .caf]
        case .image:
            [.jpg, .png, .heic, .webpImage, .avif, .pdf, .txt, .tiff, .bmp, .ico, .jpeg2000, .tga, .psd, .exr, .icns]
        case .animatedImage:
            [
                // Animated to video
                .mp4_h264, .mp4_hevc,
                // First-frame extraction
                .jpg, .png, .heic, .tiff
            ]
        case .document:
            [.pdf, .docx, .txt, .rtf, .markdown, .html, .odt, .jpg, .png]
        case .data:
            [.csv, .json, .tsv, .pdf, .txt]
        case .archive, .file:
            []
        }
        return (formats + [.zip, .gzip]).filter { CodecCapability.canEncode($0) }
    }

    /// Detects the input category from a file URL.
    /// Unknown types remain importable for ZIP/GZIP compression.
    static func detectCategory(from url: URL) -> MediaCategory? {
        let ext = url.pathExtension.lowercased()
        if ["pdf", "docx", "odt", "rtf", "txt", "md", "markdown", "html", "htm"].contains(ext) { return .document }
        if ["csv", "tsv", "json"].contains(ext) { return .data }
        if ["zip", "gz", "gzip"].contains(ext) { return .archive }
        // Motion JPEG (extension-only container) is video for conversion; do not treat as a still image.
        if supportedVideoFilenameExtensionSet.contains(ext) {
            return .video
        }
        guard let type = UTType(filenameExtension: ext) else {
            return categoryByExtension(ext)
        }
        // GIF is animated image, distinct from still image
        if type.conforms(to: .gif) { return .animatedImage }
        if type.conforms(to: .movie) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .image) { return .image }
        // Fall back to extension-based detection for formats UTType doesn't know
        return categoryByExtension(ext)
    }

    /// Fallback for formats UTType doesn't recognize (e.g. webm on some iOS versions).
    private static func categoryByExtension(_ ext: String) -> MediaCategory? {
        switch ext {
        case _ where supportedVideoFilenameExtensionSet.contains(ext):
            .video
        case _ where supportedAudioFilenameExtensionSet.contains(ext):
            .audio
        case "webp", "avif": .image
        case "gif": .animatedImage
        default: .file
        }
    }

    /// Suggested default output for a given input category (for initial UI state).
    static func defaultOutput(for category: MediaCategory) -> OutputFormat {
        switch category {
        case .video: .mp4_h264
        case .audio: .m4a
        case .image: .jpg
        case .animatedImage: .mp4_h264
        case .document: .pdf
        case .data: .csv
        case .archive, .file: .zip
        }
    }
}
