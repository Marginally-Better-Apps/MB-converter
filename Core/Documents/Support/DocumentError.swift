import Foundation

enum DocumentError: LocalizedError, Equatable {
    case unsupportedFormat(String)
    case unreadable(String)
    case writeFailed(String)
    case passwordRequired
    case wrongPassword
    case empty(String)
    case invalidOption(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let detail):
            "This format isn't supported: \(detail)"
        case .unreadable(let detail):
            "Couldn't read the file. \(detail)"
        case .writeFailed(let detail):
            "Couldn't write the file. \(detail)"
        case .passwordRequired:
            "This PDF is password protected. Enter its password to continue."
        case .wrongPassword:
            "That password didn't unlock the PDF."
        case .empty(let detail):
            detail
        case .invalidOption(let detail):
            detail
        }
    }
}
