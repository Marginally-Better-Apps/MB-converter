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
    // Images handled by ImageMagick (or ImageIO where available)
    case avif, jxl, jp2, psd, tga, ico, pnm, pcx, qoi, dds, sgi, xpm, hdr, eps
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
        case .jpeg, .png, .heic, .webp, .tiff, .gif, .bmp, .svg,
             .avif, .jxl, .jp2, .psd, .tga, .ico, .pnm, .pcx, .qoi, .dds, .sgi, .xpm, .hdr, .eps: .image
        case .mp4, .mov, .m4v, .mkv, .webm, .avi: .video
        case .mp3, .m4a, .wav, .aac, .flac, .ogg, .opus: .audio
        case .zip: .archive
        }
    }

    var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .jpeg: "jpg"
        case .pnm: "ppm"
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
        case .avif: "AVIF"
        case .jxl: "JPEG XL"
        case .jp2: "JPEG 2000"
        case .psd: "Photoshop"
        case .tga: "Targa"
        case .ico: "Icon"
        case .pnm: "Netpbm"
        case .pcx: "PCX"
        case .qoi: "QOI"
        case .dds: "DirectDraw Surface"
        case .sgi: "SGI"
        case .xpm: "X Pixmap"
        case .hdr: "Radiance HDR"
        case .eps: "EPS"
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
        "avif": .avif, "jxl": .jxl, "jp2": .jp2, "j2k": .jp2, "jpf": .jp2,
        "psd": .psd, "psb": .psd, "tga": .tga, "icb": .tga, "ico": .ico, "cur": .ico,
        "ppm": .pnm, "pgm": .pnm, "pbm": .pnm, "pnm": .pnm, "pam": .pnm,
        "pcx": .pcx, "qoi": .qoi, "dds": .dds, "sgi": .sgi, "rgb": .sgi, "xpm": .xpm, "hdr": .hdr,
        "eps": .eps, "epsf": .eps,
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

    /// Raster images the tools can decode (ImageIO, or ImageMagick for the rest).
    static let stillImages: [FileFormat] = [.jpeg, .png, .heic, .webp, .tiff, .gif, .bmp,
                                            .avif, .jxl, .jp2, .psd, .tga, .ico, .pnm, .pcx, .qoi, .dds, .sgi, .xpm, .hdr]

    /// ImageMagick coder name used when ImageIO can't handle the format.
    var magickCoder: String? {
        switch self {
        case .avif: "avif"
        case .jxl: "jxl"
        case .jp2: "jp2"
        case .psd: "psd"
        case .tga: "tga"
        case .ico: "ico"
        case .pnm: "ppm"
        case .pcx: "pcx"
        case .qoi: "qoi"
        case .dds: "dds"
        case .sgi: "sgi"
        case .xpm: "xpm"
        case .hdr: "hdr"
        case .eps: "eps"
        case .bmp: "bmp"
        case .gif: "gif"
        case .tiff: "tiff"
        case .png: "png"
        case .jpeg: "jpeg"
        case .webp: "webp"
        default: nil
        }
    }
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
            if source == .eps { return [] } // EPS can be written, not read (that needs Ghostscript).
            let raster: [FileFormat] = [.png, .jpeg, .webp, .heic, .avif, .jxl, .tiff, .gif, .bmp, .psd, .tga,
                                        .ico, .jp2, .qoi, .pnm, .pcx, .dds, .sgi, .xpm, .hdr, .eps]
            return [.pdf] + raster.filter { $0 != source && (ImageToolkit.OutputFormat(fileFormat: $0)?.isAvailable ?? false) }
        default:
            return []
        }
    }
}
