import Foundation
import PDFKit
import UIKit

/// Routes any supported source → target conversion to the right engine.
@MainActor
enum ConversionEngine {
    struct Settings {
        var document = DocumentExportOptions()
        var layout: DocumentConverter.Layout = .reformat
        /// PDF → HTML: a page-exact replica (default) instead of reflowed text and images.
        var pdfHTMLExact = true
        var imageDPI: CGFloat = 150
        var imageQuality: Double = 0.9
        /// For spreadsheet → single-sheet formats: nil = every sheet as its own file.
        var sheetIndex: Int?
        var password: String?
    }

    nonisolated static func targets(for source: FileFormat) -> [FileFormat] {
        ConversionTargets.targets(for: source)
    }

    nonisolated static func canConvert(_ source: FileFormat, to target: FileFormat) -> Bool {
        targets(for: source).contains(target)
    }

    /// Converts one file, returning one or more outputs (e.g. one image per PDF page).
    static func convert(_ input: ToolInputFile, to target: FileFormat, settings: Settings, context: ToolContext) async throws -> [URL] {
        let source = input.format
        guard canConvert(source, to: target) else {
            throw DocumentError.unsupportedFormat("\(source.displayName) to \(target.displayName)")
        }
        let base = input.baseName

        switch (source.family, target.family) {
        case (.pdf, _) where target == .eps || target == .ps:
            return try await exportPostScript(input, as: target, settings: settings, context: context)

        case (.image, _) where source.isPostScript:
            return try await convertPostScript(input, to: target, settings: settings, context: context)

        case (.pdf, .image):
            let document = try PDFToolkit.open(input.url, password: settings.password ?? context.password)
            if target == .tiff {
                let data = try await background { try PDFToImages.multipageTIFF(document, dpi: settings.imageDPI) }
                let url = context.outputURL(base, "tiff")
                try data.write(to: url)
                return [url]
            }
            let format: PDFToImages.Format = target == .png ? .png : (target == .heic ? .heic : .jpeg)
            let pages = try await background { try PDFToImages.render(document, format: format, dpi: settings.imageDPI, quality: settings.imageQuality) }
            return try pages.map { page in
                let url = context.outputURL(pages.count == 1 ? base : "\(base)-page-\(page.index + 1)", format.fileExtension)
                try page.data.write(to: url)
                return url
            }

        case (.presentation, .image):
            // Render slides through WebKit's Office viewer, then rasterize.
            let pdfData = try await WebPDFRenderer.renderFile(input.url, setup: .init(pageRect: CGRect(x: 0, y: 0, width: 960, height: 540), margin: 0))
            guard let document = PDFDocument(data: pdfData) else { throw DocumentError.writeFailed("The slides couldn't be rendered.") }
            let format: PDFToImages.Format = target == .png ? .png : .jpeg
            let pages = try await background { try PDFToImages.render(document, format: format, dpi: settings.imageDPI, quality: settings.imageQuality) }
            return try pages.map { page in
                let url = context.outputURL("\(base)-slide-\(page.index + 1)", format.fileExtension)
                try page.data.write(to: url)
                return url
            }

        case (.presentation, _) where target == .pdf:
            let url = context.outputURL(base, "pdf")
            let landscape = CGRect(x: 0, y: 0, width: 792, height: 612)
            try await WebPDFRenderer.renderFile(input.url, setup: .init(pageRect: landscape, margin: 18, title: base)).write(to: url)
            return [url]

        case (.image, _) where target == .pdf:
            let url = context.outputURL(base, "pdf")
            if source == .svg {
                let image = try await WebPDFRenderer.snapshotFile(input.url, width: 1_024)
                let png = try Self.temporaryPNG(image)
                try ImagesToPDF.makePDF(from: [png]).write(to: url)
            } else if ImageToolkit.OutputFormat(fileFormat: source).map({ !$0.usesImageIO && $0 != .webp }) ?? false {
                // Decode via ImageMagick first so ImageIO can embed it.
                let proxy = try Magick.pngProxy(for: input.url)
                defer { try? FileManager.default.removeItem(at: proxy) }
                try await background { try ImagesToPDF.makePDF(from: [proxy]) }.write(to: url)
            } else {
                try await background { try ImagesToPDF.makePDF(from: [input.url]) }.write(to: url)
            }
            return [url]

        case (.image, .image):
            guard let format = ImageToolkit.OutputFormat(fileFormat: target) else {
                throw DocumentError.unsupportedFormat(target.displayName)
            }
            let cgImage: CGImage
            if source == .svg {
                guard let rendered = try await WebPDFRenderer.snapshotFile(input.url, width: 1_024).cgImage else {
                    throw DocumentError.writeFailed("The SVG couldn't be rendered.")
                }
                cgImage = rendered
            } else {
                let url = input.url
                cgImage = try await background { try ImageToolkit.load(url) }
            }
            let url = context.outputURL(base, format.fileExtension)
            let quality = settings.imageQuality
            try await background { try ImageToolkit.encode(cgImage, as: format, quality: quality) }.write(to: url)
            return [url]

        case (.spreadsheet, _):
            let workbook = try SpreadsheetConverter.read(input.url, format: source)
            guard !workbook.isEmpty else { throw DocumentError.empty("The file has no data.") }
            return try await writeWorkbook(workbook, as: target, base: base, settings: settings, context: context)

        case (.pdf, .spreadsheet), (.document, .spreadsheet), (.presentation, .spreadsheet):
            let workbook = try SpreadsheetConverter.read(input.url, format: source)
            return try await writeWorkbook(workbook, as: target, base: base, settings: settings, context: context)

        case (.pdf, _) where target == .html && settings.pdfHTMLExact:
            let url = context.outputURL(base, target.fileExtension)
            let document = try PDFToolkit.open(input.url, password: settings.password ?? context.password)
            var options = PDFHTMLExporter.Options()
            options.title = settings.document.title
            let progress = context.progress
            options.progress = { progress.report($0) }
            let exportOptions = options
            try await background { try PDFHTMLExporter.write(document, to: url, options: exportOptions) }
            return [url]

        case (_, _) where target == .markdown:
            // Markdown can't embed pictures sensibly; save them beside the .md and link by file name.
            let url = context.outputURL(base, target.fileExtension)
            let document = try DocumentConverter.read(input.url, format: source, password: settings.password ?? context.password)
            guard !document.isEffectivelyEmpty else { throw DocumentError.empty("No readable content was found in this file.") }
            var images: [URL] = []
            var names: [ImageBlock: String] = [:]
            let includeImages = settings.document.includeImages
            for block in document.allImages where includeImages && names[block] == nil {
                let imageURL = context.outputURL("\(base)-image-\(names.count + 1)", block.fileExtension)
                try block.data.write(to: imageURL)
                names[block] = imageURL.lastPathComponent
                images.append(imageURL)
            }
            let resolved = names
            try MarkdownWriter.data(document, imageSource: { resolved[$0].map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 } ?? "" }).write(to: url)
            return [url] + images

        default:
            let url = context.outputURL(base, target.fileExtension)
            try await DocumentConverter.convert(
                input: input.url,
                from: source,
                to: target,
                options: settings.document,
                layout: settings.layout,
                password: settings.password ?? context.password,
                output: url
            )
            return [url]
        }
    }

    private static func writeWorkbook(_ workbook: Workbook, as target: FileFormat, base: String, settings: Settings, context: ToolContext) async throws -> [URL] {
        let singleSheetFormats: Set<FileFormat> = [.csv, .tsv]
        if singleSheetFormats.contains(target), workbook.sheets.count > 1, settings.sheetIndex == nil {
            var urls: [URL] = []
            for (index, sheet) in workbook.sheets.enumerated() where !sheet.isEmpty {
                let url = context.outputURL("\(base)-\(sheet.name)", target.fileExtension)
                try await SpreadsheetConverter.write(workbook, as: target, sheetIndex: index, to: url)
                urls.append(url)
            }
            return urls
        }
        let url = context.outputURL(base, target.fileExtension)
        var options = settings.document
        if target == .pdf, (workbook.sheets.map(\.columnCount).max() ?? 0) > 6 {
            options.orientation = .landscape
        }
        try await SpreadsheetConverter.write(workbook, as: target, options: options, sheetIndex: settings.sheetIndex, to: url)
        return [url]
    }

    /// PDF → PostScript (one file) or EPS (one file per page).
    private static func exportPostScript(_ input: ToolInputFile, as target: FileFormat, settings: Settings, context: ToolContext) async throws -> [URL] {
        let password = settings.password ?? context.password
        let directory = context.outputDirectory
        let files = try await Ghostscript.cancellable { flag in
            try Ghostscript.export(input.url, as: target == .eps ? .eps : .ps, into: directory, password: password, cancel: flag)
        }
        return try name(files, base: input.baseName, ext: target.fileExtension, context: context)
    }

    /// Gives scratch outputs their final names: "base.ext", or "base-page-N.ext" for several.
    private static func name(_ files: [URL], base: String, ext: String, context: ToolContext) throws -> [URL] {
        try files.enumerated().map { index, file in
            let url = context.outputURL(files.count == 1 ? base : "\(base)-page-\(index + 1)", ext)
            try FileManager.default.moveItem(at: file, to: url)
            return url
        }
    }

    /// EPS, PostScript or Illustrator → PDF, images, or the other PostScript flavor.
    private static func convertPostScript(_ input: ToolInputFile, to target: FileFormat, settings: Settings, context: ToolContext) async throws -> [URL] {
        let base = input.baseName
        // EPS and AI are artwork: crop to the drawing and keep its transparency.
        let artwork = input.format != .ps
        switch target {
        case .pdf:
            let url = context.outputURL(base, "pdf")
            try await Ghostscript.cancellable { flag in try Ghostscript.postScriptToPDF(input.url, to: url, crop: artwork, cancel: flag) }
            return [url]
        case .eps, .ps:
            let pdf = context.outputDirectory.appendingPathComponent(".\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: pdf) }
            try await Ghostscript.cancellable { flag in try Ghostscript.postScriptToPDF(input.url, to: pdf, crop: artwork, cancel: flag) }
            let directory = context.outputDirectory
            let files = try await Ghostscript.cancellable { flag in try Ghostscript.export(pdf, as: target == .eps ? .eps : .ps, into: directory, cancel: flag) }
            return try name(files, base: base, ext: target.fileExtension, context: context)
        default:
            guard let format = ImageToolkit.OutputFormat(fileFormat: target) else {
                throw DocumentError.unsupportedFormat(target.displayName)
            }
            // Artwork renders sharp at 300 dpi; PostScript documents use the chosen page resolution.
            let dpi = artwork ? 300 : Int(settings.imageDPI)
            let transparent = artwork && target != .jpeg
            let directory = context.outputDirectory
            let pages = try await Ghostscript.cancellable { flag in
                try Ghostscript.renderPNG(input.url, dpi: dpi, transparent: transparent, crop: artwork, into: directory, cancel: flag)
            }
            defer { pages.forEach { try? FileManager.default.removeItem(at: $0) } }
            let quality = settings.imageQuality
            var urls: [URL] = []
            for (index, page) in pages.enumerated() {
                let url = context.outputURL(pages.count == 1 ? base : "\(base)-page-\(index + 1)", format.fileExtension)
                if target == .png {
                    try FileManager.default.copyItem(at: page, to: url)
                } else {
                    let image = try await background { try ImageToolkit.load(page) }
                    try await background { try ImageToolkit.encode(image, as: format, quality: quality) }.write(to: url)
                }
                urls.append(url)
            }
            return urls
        }
    }

    private static func temporaryPNG(_ image: UIImage) throws -> URL {
        guard let data = image.pngData() else { throw DocumentError.writeFailed("Couldn't encode the image.") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
        try data.write(to: url)
        return url
    }
}
