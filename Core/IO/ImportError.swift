import Foundation

enum ImportError: LocalizedError {
    case noSupportedMediaInPasteboard
    case unsupportedType
    case copyFailed(String)
    case fileTooLarge(limitBytes: Int64)
    case invalidRemoteURL
    case couldNotDetermineRemoteFileType
    case remoteResponseNotMedia
    case networkFailed(String)
    case codecNotDecodable(codecLabel: String, reason: String)

    /// Plain sentences that say what to do next. Technical detail goes to `failureReason`,
    /// which the error log keeps.
    var errorDescription: String? {
        switch self {
        case .noSupportedMediaInPasteboard:
            "There's nothing on the clipboard to open. Copy a photo, video or PDF, then try again."
        case .unsupportedType:
            "This app can't open this kind of file. Try saving it as a photo, video, PDF or document first."
        case .copyFailed:
            "The file couldn't be brought into the app. Try again, or save it to Files and open it from there."
        case .fileTooLarge(let limitBytes):
            "This file is too big to open here. Choose a file smaller than \(limitBytes / (1024 * 1024)) MB."
        case .invalidRemoteURL:
            "That doesn't look like a web link. Paste a link that starts with https://."
        case .couldNotDetermineRemoteFileType:
            "We couldn't tell what kind of file that link is. Try a link that goes straight to the file, like one ending in .mp4 or .pdf."
        case .remoteResponseNotMedia:
            "That link opens a web page, not a file. Try a link that downloads the file itself."
        case .networkFailed:
            "The download didn't finish. Check the link and your internet connection, then try again."
        case .codecNotDecodable(let codecLabel, _):
            "This file is saved in a format this app can't play (\(codecLabel)). Try converting or exporting it as MP4 in another app first."
        }
    }

    var failureReason: String? {
        switch self {
        case .copyFailed(let message), .networkFailed(let message): message
        case .codecNotDecodable(_, let reason): reason
        default: nil
        }
    }
}
