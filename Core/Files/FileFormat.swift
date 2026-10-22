import Foundation
import UniformTypeIdentifiers

/// Broad family a file belongs to. Drives which tools and conversions are offered.
enum FileFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case pdf
    case document
    case spreadsheet
    case presentation
    case image
    case video
    case audio
    case archive
    case other
}

/// Every file type the tools layer understands, independent of the media `OutputFormat` pipeline.
enum FileFormat: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    // Documents
    case pdf, docx, odt, rtf, txt, markdown, html, epub
    // Spreadsheets & data
    case xlsx, ods, csv, tsv, json, xml
    // Presentations
    case pptx
    // Images
    case jpeg, png, heic, webp, tiff, gif, bmp, svg
    // Media (handled by the FFmpeg pipeline)
    case mp4, mov, m4v, mkv, webm, avi, mp3, m4a, wav, aac, flac, ogg, opus
    // Archives
    case zip

    var id: String { rawValue }

    var family: FileFamily {
        switch self {
        case .pdf: .pdf
        case .docx, .odt, .rtf, .txt, .markdown, .html, .epub: .document
        case .xlsx, .ods, .csv, .tsv, .json, .xml: .spreadsheet
        case .pptx: .presentation
        case .jpeg, .png, .heic, .webp, .tiff, .gif, .bmp, .svg: .image
        case .mp4, .mov, .m4v, .mkv, .webm, .avi: .video
        case .mp3, .m4a, .wav, .aac, .flac, .ogg, .opus: .audio
        case .zip: .archive
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .jpeg: "jpg"
        case .tiff: "tiff"
        default: rawValue
        }
    }

    var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .docx: "Word"
        case .odt: "OpenDocument Text"
        case .rtf: "Rich Text"
        case .txt: "Plain Text"
        case .markdown: "Markdown"
        case .html: "HTML"
        case .epub: "EPUB"
        case .xlsx: "Excel"
        case .ods: "OpenDocument Sheet"
        case .csv: "CSV"
        case .tsv: "TSV"
        case .json: "JSON"
        case .xml: "XML"
        case .pptx: "PowerPoint"
        case .jpeg: "JPEG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .webp: "WebP"
        case .tiff: "TIFF"
        case .gif: "GIF"
        case .bmp: "BMP"
        case .svg: "SVG"
        case .zip: "ZIP"
        default: rawValue.uppercased()
        }
    }

    /// Short label for chips and badges (e.g. "DOCX").
    var badge: String {
        switch self {
        case .markdown: "MD"
        case .jpeg: "JPG"
        default: fileExtension.uppercased()
        }
    }

    var symbolName: String {
        switch family {
        case .pdf: "doc.richtext"
        case .document: self == .epub ? "book.closed" : "doc.text"
        case .spreadsheet: self == .json || self == .xml ? "curlybraces" : "tablecells"
        case .presentation: "rectangle.on.rectangle.angled"
        case .image: "photo"
        case .video: "film"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .other: "doc"
        }
    }

    var utType: UTType {
        switch self {
        case .markdown: UTType(filenameExtension: "md") ?? .plainText
        case .docx: UTType(filenameExtension: "docx") ?? .data
        case .odt: UTType(filenameExtension: "odt") ?? .data
        case .xlsx: UTType(filenameExtension: "xlsx") ?? .data
        case .ods: UTType(filenameExtension: "ods") ?? .data
        case .pptx: UTType(filenameExtension: "pptx") ?? .data
        case .epub: .epub
        default: UTType(filenameExtension: fileExtension) ?? .data
        }
    }

    var mimeType: String {
        utType.preferredMIMEType ?? "application/octet-stream"
    }

    private static let extensionAliases: [String: FileFormat] = [
        "pdf": .pdf,
        "docx": .docx, "docm": .docx, "dotx": .docx,
        "odt": .odt, "ott": .odt,
        "rtf": .rtf,
        "txt": .txt, "text": .txt, "log": .txt,
        "md": .markdown, "markdown": .markdown, "mdown": .markdown,
        "html": .html, "htm": .html, "xhtml": .html,
        "epub": .epub,
        "xlsx": .xlsx, "xlsm": .xlsx,
        "ods": .ods,
        "csv": .csv,
        "tsv": .tsv, "tab": .tsv,
        "json": .json,
        "xml": .xml,
        "pptx": .pptx,
        "jpg": .jpeg, "jpeg": .jpeg,
        "png": .png,
        "heic": .heic, "heif": .heic,
        "webp": .webp,
        "tif": .tiff, "tiff": .tiff,
        "gif": .gif,
        "bmp": .bmp,
        "svg": .svg,
        "mp4": .mp4, "mov": .mov, "m4v": .m4v, "mkv": .mkv, "webm": .webm, "avi": .avi,
        "mp3": .mp3, "m4a": .m4a, "wav": .wav, "aac": .aac, "flac": .flac, "ogg": .ogg, "opus": .opus,
        "zip": .zip
    ]

    init?(fileExtension ext: String) {
        guard let format = Self.extensionAliases[ext.lowercased()] else { return nil }
        self = format
    }

    init?(url: URL) {
        self.init(fileExtension: url.pathExtension)
    }

    /// Formats the document pipeline can read into a `RichDocument`.
    static let documentReadable: [FileFormat] = [.pdf, .docx, .odt, .rtf, .txt, .markdown, .html, .epub, .pptx]

    /// Formats the document pipeline can write.
    static let documentWritable: [FileFormat] = [.pdf, .docx, .odt, .rtf, .txt, .markdown, .html, .epub]

    static let spreadsheetReadable: [FileFormat] = [.xlsx, .ods, .csv, .tsv, .json, .xml]
    static let spreadsheetWritable: [FileFormat] = [.xlsx, .ods, .csv, .tsv, .json, .xml, .html, .markdown, .pdf]

    static let stillImages: [FileFormat] = [.jpeg, .png, .heic, .webp, .tiff, .gif, .bmp]
}

/// Picks the most useful conversion targets for a source format, best first.
enum ConversionTargets {
    static func targets(for source: FileFormat) -> [FileFormat] {
        switch source.family {
        case .pdf:
            return [.docx, .jpeg, .png, .txt, .odt, .rtf, .markdown, .html, .epub, .tiff, .csv, .xlsx]
        case .document:
            return FileFormat.documentWritable.filter { $0 != source }
        case .presentation:
            return [.pdf, .png, .jpeg, .docx, .txt, .markdown, .html]
        case .spreadsheet:
            return FileFormat.spreadsheetWritable.filter { $0 != source }
        case .image:
            return source == .svg ? [.png, .jpeg, .pdf] : [.pdf]
        default:
            return []
        }
    }
}
