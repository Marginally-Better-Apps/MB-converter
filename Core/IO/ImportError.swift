import Foundation

enum ImportError: LocalizedError {
    case noSupportedMediaInPasteboard
    case unsupportedType
    case copyFailed(String)
    case fileTooLarge(limitBytes: Int64)
    case invalidRemoteURL
    case couldNotDetermineRemoteFileType
    case networkFailed(String)
    case codecNotDecodable(codecLabel: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .noSupportedMediaInPasteboard:
            "There is no supported media in the clipboard. Copy a file in Files or copy an image."
        case .unsupportedType:
            "This file type is not supported."
        case .copyFailed(let message):
            "Import failed: \(message)"
        case .fileTooLarge(let limitBytes):
            "The file is larger than \(limitBytes / (1024 * 1024)) MB."
        case .invalidRemoteURL:
            "Enter a valid http or https link."
        case .couldNotDetermineRemoteFileType:
            "Could not tell the file type from the link or server response. Try a URL whose path ends with a supported extension (for example .mp4)."
        case .networkFailed(let message):
            "Download failed: \(message)"
        case .codecNotDecodable(let codecLabel, let reason):
            "This file uses \(codecLabel), which the bundled FFmpeg can't decode. \(reason)"
        }
    }
}
