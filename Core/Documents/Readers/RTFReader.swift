import Foundation
import UIKit

enum RTFReader {
    static func read(url: URL) throws -> RichDocument {
        try read(data: Data(contentsOf: url))
    }

    static func read(data: Data) throws -> RichDocument {
        let attributed: NSAttributedString
        do {
            attributed = try NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            )
        } catch {
            throw DocumentError.unreadable("The rich text file is damaged or uses an unsupported variant.")
        }
        var document = AttributedTextImporter.document(from: attributed)
        document.metadata = metadata(from: data)
        return document
    }

    /// Pulls `\info` fields that NSAttributedString drops.
    static func metadata(from data: Data) -> DocumentMetadata {
        var metadata = DocumentMetadata()
        let text = String(decoding: data.prefix(64 * 1024), as: UTF8.self)
        func field(_ name: String) -> String? {
            guard let range = text.range(of: "{\\\(name) ") else { return nil }
            guard let end = text[range.upperBound...].firstIndex(of: "}") else { return nil }
            return RTFWriter.unescape(String(text[range.upperBound ..< end])).nilIfBlank
        }
        metadata.title = field("title")
        metadata.author = field("author")
        metadata.subject = field("subject")
        metadata.keywords = (field("keywords") ?? "").split(separator: ",").compactMap { String($0).nilIfBlank }
        return metadata
    }
}
