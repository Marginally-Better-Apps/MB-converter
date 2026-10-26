import Foundation
import PDFKit
import UIKit

enum ToolHelpers {
    static func savings(before: Int64, after: Int64) -> String {
        guard before > 0 else { return after.formattedBytes }
        if after < before {
            let percent = Int((Double(before - after) / Double(before) * 100).rounded())
            return "\(percent)% smaller · \(before.formattedBytes) → \(after.formattedBytes)"
        }
        return "\(before.formattedBytes) → \(after.formattedBytes)"
    }

    static func write(_ data: Data, _ base: String, _ ext: String, _ context: ToolContext) throws -> URL {
        let url = context.outputURL(base, ext)
        try data.write(to: url)
        return url
    }

    static func openPDF(_ input: ToolInputFile, _ context: ToolContext) throws -> PDFDocument {
        try PDFToolkit.open(input.url, password: context.password)
    }

    /// Empty text means "all pages".
    static func pageSet(_ text: String, pageCount: Int) throws -> Set<Int>? {
        guard let text = text.nilIfBlank else { return nil }
        return try PageRangeParser.parseSet(text, pageCount: pageCount)
    }

    static func pageCountSummary(_ count: Int) -> String {
        "\(count) page\(count == 1 ? "" : "s")"
    }

    static let placementChoices = PDFStamper.Placement.allCases.map { ToolChoice($0.rawValue, $0.label) }
    static let pagesOption = ToolOption.text("pages", "Pages", placeholder: "All pages", section: "Pages", footnote: "For example 1-3, 5, 8-")
}

extension ToolCatalog {
    static let pdfTools: [ToolDefinition] = [
        ToolDefinition(
            id: "pdf.merge", title: "Merge PDF", summary: "Combine several PDFs into one, in any order",
            symbol: "doc.on.doc", category: .pdf, input: .many([.pdf], noun: "PDFs", min: 2),
            keywords: ["combine", "join", "append"], isFeatured: true, actionTitle: "Merge"
        ) { context in
            let documents = try context.inputs.map { try ToolHelpers.openPDF($0, context) }
            let merged = PDFToolkit.merge(documents)
            let url = context.outputURL("\(try context.first.baseName)-merged", "pdf")
            try PDFToolkit.write(merged, to: url)
            return ToolOutput(files: [url], summary: "\(ToolHelpers.pageCountSummary(merged.pageCount)) from \(documents.count) files")
        },

        ToolDefinition(
            id: "pdf.split", title: "Split PDF", summary: "Break a PDF into ranges, chunks or single pages",
            symbol: "scissors", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .choice("mode", "Split by", [ToolChoice("ranges", "Ranges"), ToolChoice("every", "Every N pages"), ToolChoice("each", "Each page"), ToolChoice("size", "File size")], segmented: false),
                .text("ranges", "Ranges", placeholder: "1-3, 4-6, 7-", default: "", footnote: "Each comma-separated range becomes its own PDF.", visible: { $0.string("mode") == "ranges" }),
                .stepper("every", "Pages per file", range: 1 ... 500, default: 2, visible: { $0.string("mode") == "every" }),
                .slider("size", "Max file size", range: 1 ... 50, default: 5, format: { "\(Int($0)) MB" }, visible: { $0.string("mode") == "size" })
            ],
            keywords: ["separate", "divide", "extract"], isFeatured: true, actionTitle: "Split",
            validate: { values, _, _ in values.string("mode") == "ranges" && values.string("ranges").nilIfBlank == nil ? "Type where to split, like 1-3, 4-6" : nil }
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let mode: PDFToolkit.SplitMode = switch context.options.string("mode") {
            case "every": .everyNPages(context.options.int("every"))
            case "each": .eachPage
            case "size": .maxFileSize(bytes: Int64(context.options.double("size") * 1_048_576))
            default: .ranges(context.options.string("ranges").nilIfBlank ?? "1-\(document.pageCount)")
            }
            let parts = try await background { try PDFToolkit.split(document, mode: mode) }
            var urls: [URL] = []
            for (index, part) in parts.enumerated() {
                let url = context.outputURL("\(input.baseName)-part-\(index + 1)", "pdf")
                try PDFToolkit.write(part, to: url)
                urls.append(url)
            }
            return ToolOutput(files: urls, summary: "\(parts.count) PDFs")
        },

        ToolDefinition(
            id: "pdf.organize", title: "Organize Pages", summary: "Reorder, rotate, delete and insert pages visually",
            symbol: "square.grid.2x2", category: .pdf, input: .one([.pdf], noun: "PDF"),
            editor: .pageOrganizer, keywords: ["rearrange", "reorder", "sort", "move", "duplicate", "insert", "blank"], isFeatured: true, actionTitle: "Save"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let edits = context.editor.pageEdits ?? PDFToolkit.PageEdit.identity(pageCount: document.pageCount)
            let output = try PDFToolkit.organize(document, edits: edits)
            let url = context.outputURL("\(input.baseName)-organized", "pdf")
            try PDFToolkit.write(output, to: url)
            return ToolOutput(files: [url], summary: ToolHelpers.pageCountSummary(output.pageCount))
        },

        ToolDefinition(
            id: "pdf.rotate", title: "Rotate PDF", summary: "Turn every page, or just some, by 90° steps",
            symbol: "rotate.right", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .choice("angle", "Rotation", [ToolChoice("90", "90° right"), ToolChoice("180", "180°"), ToolChoice("270", "90° left")], segmented: true),
                ToolHelpers.pagesOption
            ],
            keywords: ["turn", "orientation", "landscape"], actionTitle: "Rotate"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let pages = try ToolHelpers.pageSet(context.options.string("pages"), pageCount: document.pageCount)
            let output = PDFToolkit.rotate(document, by: context.options.int("angle"), pages: pages)
            let url = context.outputURL("\(input.baseName)-rotated", "pdf")
            try PDFToolkit.write(output, to: url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "pdf.delete", title: "Delete Pages", summary: "Remove pages you don't need",
            symbol: "trash", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [.text("pages", "Pages to delete", placeholder: "2, 5-7", footnote: "For example 1-3, 5, 8-")],
            keywords: ["remove", "page deleter"], actionTitle: "Delete",
            validate: { values, _, _ in values.string("pages").nilIfBlank == nil ? "Type the pages to delete" : nil }
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            guard let text = context.options.string("pages").nilIfBlank else {
                throw DocumentError.invalidOption("Enter the pages to delete.")
            }
            let remove = try PageRangeParser.parseSet(text, pageCount: document.pageCount)
            let output = try PDFToolkit.deletePages(document, remove: remove)
            let url = context.outputURL("\(input.baseName)-edited", "pdf")
            try PDFToolkit.write(output, to: url)
            return ToolOutput(files: [url], summary: "Removed \(ToolHelpers.pageCountSummary(remove.count)) · \(ToolHelpers.pageCountSummary(output.pageCount)) left")
        },

        ToolDefinition(
            id: "pdf.extract", title: "Extract Pages", summary: "Save selected pages as a new PDF",
            symbol: "doc.badge.arrow.up", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .text("pages", "Pages to keep", placeholder: "1-3, 5", footnote: "Pages are kept in the order you type them."),
                .toggle("separate", "Save each page as its own file")
            ],
            keywords: ["select", "pull out", "copy"], actionTitle: "Extract",
            validate: { values, _, _ in values.string("pages").nilIfBlank == nil ? "Type the pages to keep" : nil }
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            guard let text = context.options.string("pages").nilIfBlank else {
                throw DocumentError.invalidOption("Enter the pages to extract.")
            }
            let indices = try PageRangeParser.parse(text, pageCount: document.pageCount)
            if context.options.bool("separate") {
                let urls = try indices.map { index -> URL in
                    let url = context.outputURL("\(input.baseName)-page-\(index + 1)", "pdf")
                    try PDFToolkit.write(PDFToolkit.document(from: document, pageIndices: [index]), to: url)
                    return url
                }
                return ToolOutput(files: urls)
            }
            let url = context.outputURL("\(input.baseName)-extract", "pdf")
            try PDFToolkit.write(PDFToolkit.document(from: document, pageIndices: indices), to: url)
            return ToolOutput(files: [url], summary: ToolHelpers.pageCountSummary(indices.count))
        },

        ToolDefinition(
            id: "pdf.compress", title: "Compress PDF", summary: "Shrink PDFs for email and upload",
            symbol: "arrow.down.right.and.arrow.up.left", category: .pdf, input: .many([.pdf], noun: "PDFs"),
            options: [
                .choice("level", "Compression", PDFCompressor.Level.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: PDFCompressor.Level.balanced.rawValue, segmented: true,
                        footnote: "Text, vectors and links stay sharp; images are resampled. Fillable forms keep their fields. You always get the smallest result.")
            ],
            keywords: ["reduce", "smaller", "optimize", "size", "shrink"], isFeatured: true, actionTitle: "Compress"
        ) { context in
            let level = context.options.choice("level", as: PDFCompressor.Level.self, default: .balanced)
            var urls: [URL] = []
            var before: Int64 = 0
            var after: Int64 = 0
            var keptAll = true
            for (index, input) in context.inputs.enumerated() {
                let url = context.outputURL("\(input.baseName)-compressed", "pdf")
                let password = context.password
                let result = try await Ghostscript.cancellable { flag in try PDFCompressor.compress(input.url, password: password, level: level, to: url, cancel: flag) }
                before += result.originalBytes
                after += result.compressedBytes
                keptAll = keptAll && result.keptOriginal
                urls.append(url)
                context.progress.report(Double(index + 1) / Double(context.inputs.count))
            }
            let summary = keptAll ? "Already optimized — no smaller version was possible." : ToolHelpers.savings(before: before, after: after)
            return ToolOutput(files: urls, summary: summary)
        },

        ToolDefinition(
            id: "pdf.protect", title: "Protect PDF", summary: "Add a password and restrict printing or copying",
            symbol: "lock", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .text("password", "Password", placeholder: "Required to open", secure: true, section: "Password"),
                .text("confirm", "Confirm password", placeholder: "Type it again", secure: true, section: "Password"),
                ToolOption.toggle("print", "Allow printing", default: true, section: "Permissions").advanced(),
                ToolOption.toggle("copy", "Allow copying text", default: true, section: "Permissions").advanced(),
                ToolOption.toggle("edit", "Allow editing", default: false, section: "Permissions",
                                  footnote: "Uses AES encryption. Keep the password safe — it can't be recovered.").advanced()
            ],
            keywords: ["password", "encrypt", "secure", "lock"], actionTitle: "Protect",
            validate: { values, _, _ in
                if values.string("password").isEmpty { return "Type a password" }
                if values.string("password") != values.string("confirm") { return "The passwords don't match" }
                return nil
            }
        ) { context in
            let input = try context.first
            let password = context.options.string("password")
            guard !password.isEmpty else { throw DocumentError.invalidOption("Enter a password.") }
            guard password == context.options.string("confirm") else { throw DocumentError.invalidOption("The passwords don't match.") }
            let document = try ToolHelpers.openPDF(input, context)
            let url = context.outputURL("\(input.baseName)-protected", "pdf")
            try PDFToolkit.protect(
                document, userPassword: password, ownerPassword: nil,
                permissions: .init(allowPrinting: context.options.bool("print"), allowCopying: context.options.bool("copy"), allowEditing: context.options.bool("edit")),
                to: url
            )
            return ToolOutput(files: [url], summary: "Password protected")
        },

        ToolDefinition(
            id: "pdf.unlock", title: "Unlock PDF", summary: "Remove a password you know from a PDF",
            symbol: "lock.open", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [.text("password", "Current password", placeholder: "Password", secure: true, footnote: "Only remove passwords from files you own or are allowed to modify.")],
            keywords: ["remove password", "decrypt", "unprotect"], actionTitle: "Unlock"
        ) { context in
            let input = try context.first
            let document = try PDFToolkit.open(input.url, password: context.options.string("password").nilIfBlank ?? context.password)
            let url = context.outputURL("\(input.baseName)-unlocked", "pdf")
            try PDFToolkit.removePassword(document, to: url)
            return ToolOutput(files: [url], summary: "Password removed")
        },

        ToolDefinition(
            id: "pdf.watermark", title: "Add Watermark", summary: "Stamp text or a logo across pages",
            symbol: "drop", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .choice("kind", "Watermark", [ToolChoice("text", "Text"), ToolChoice("image", "Image")], segmented: true),
                .text("text", "Text", placeholder: "CONFIDENTIAL", default: "CONFIDENTIAL", visible: { $0.string("kind") != "image" }),
                .image("logo", "Image", visible: { $0.string("kind") == "image" }),
                .choice("placement", "Position", ToolHelpers.placementChoices, default: PDFStamper.Placement.center.rawValue, section: "Style"),
                ToolOption.slider("size", "Size", range: 12 ... 120, default: 54, section: "Style", format: { "\(Int($0)) pt" }, visible: { $0.string("kind") != "image" }).advanced(),
                ToolOption.slider("scale", "Width", range: 5 ... 100, default: 30, section: "Style", format: { "\(Int($0))%" }, visible: { $0.string("kind") == "image" }).advanced(),
                ToolOption.slider("opacity", "Opacity", range: 5 ... 100, default: 30, section: "Style", format: { "\(Int($0))%" }).advanced(),
                ToolOption.slider("rotation", "Angle", range: -90 ... 90, step: 5, default: -35, section: "Style", format: { "\(Int($0))°" }, visible: { $0.string("kind") != "image" }).advanced(),
                ToolOption.color("color", "Color", default: 0x7A8794, section: "Style", visible: { $0.string("kind") != "image" }).advanced(),
                ToolOption.toggle("behind", "Place behind content", section: "Style", visible: { $0.string("kind") != "image" }).advanced(),
                ToolHelpers.pagesOption
            ],
            keywords: ["stamp", "confidential", "draft", "logo", "brand"], actionTitle: "Add Watermark"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let pages = try ToolHelpers.pageSet(context.options.string("pages"), pageCount: document.pageCount)
            let placement = context.options.choice("placement", as: PDFStamper.Placement.self, default: .center)
            let data: Data
            if context.options.string("kind") == "image" {
                guard let logo = context.options.data("logo") else { throw DocumentError.invalidOption("Choose an image for the watermark.") }
                let mark = PDFStamper.ImageWatermark(imageData: logo, relativeWidth: context.options.double("scale") / 100, opacity: context.options.double("opacity") / 100, placement: placement)
                data = try await background { PDFStamper.watermark(document, image: mark, pages: pages) }
            } else {
                guard let text = context.options.string("text").nilIfBlank else { throw DocumentError.invalidOption("Enter watermark text.") }
                let mark = PDFStamper.TextWatermark(
                    text: text, fontSize: context.options.double("size"), colorHex: context.options.hex("color"),
                    opacity: context.options.double("opacity") / 100, rotation: context.options.double("rotation"),
                    placement: placement, behindContent: context.options.bool("behind")
                )
                data = try await background { PDFStamper.watermark(document, mark, pages: pages) }
            }
            return ToolOutput(files: [try ToolHelpers.write(data, "\(input.baseName)-watermarked", "pdf", context)])
        },

        ToolDefinition(
            id: "pdf.pagenumbers", title: "Add Page Numbers", summary: "Number pages in the header or footer",
            symbol: "number", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .choice("format", "Format", PDFStamper.NumberFormat.allCases.map { ToolChoice($0.rawValue, $0.label) }),
                .choice("placement", "Position", [PDFStamper.Placement.bottom, .bottomRight, .bottomLeft, .top, .topRight, .topLeft].map { ToolChoice($0.rawValue, $0.label) }),
                ToolOption.slider("size", "Text size", range: 7 ... 24, default: 10, format: { "\(Int($0)) pt" }).advanced(),
                .stepper("start", "Start at", range: 0 ... 9_999, default: 1),
                .toggle("skipFirst", "Skip the first page", footnote: "Useful for cover pages.")
            ],
            keywords: ["numbering", "paginate", "footer", "header"], actionTitle: "Add Numbers"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let numbering = PDFStamper.PageNumbering(
                format: context.options.choice("format", as: PDFStamper.NumberFormat.self, default: .plain),
                placement: context.options.choice("placement", as: PDFStamper.Placement.self, default: .bottom),
                fontSize: context.options.double("size"),
                startAt: context.options.int("start"),
                skipFirstPage: context.options.bool("skipFirst")
            )
            let data = try await background { PDFStamper.addPageNumbers(document, numbering) }
            return ToolOutput(files: [try ToolHelpers.write(data, "\(input.baseName)-numbered", "pdf", context)])
        },

        ToolDefinition(
            id: "pdf.edit", title: "Edit & Annotate", summary: "Add text, images, highlights and shapes",
            symbol: "pencil.and.outline", category: .pdf, input: .one([.pdf], noun: "PDF"),
            editor: .pdfMarkup(signatureFirst: false),
            keywords: ["annotate", "add text", "highlight", "whiteout", "markup", "write", "fill"], isFeatured: true, actionTitle: "Save PDF",
            validate: { _, editor, _ in editor.overlays.isEmpty ? "Add something to a page" : nil }
        ) { context in
            try await applyOverlays(context, suffix: "edited")
        },

        ToolDefinition(
            id: "pdf.sign", title: "Sign PDF", summary: "Draw your signature and place it on any page",
            symbol: "signature", category: .pdf, input: .one([.pdf], noun: "PDF"),
            editor: .pdfMarkup(signatureFirst: true),
            keywords: ["esign", "signature", "initials", "fill and sign"], isFeatured: true, actionTitle: "Save Signed PDF",
            validate: { _, editor, _ in editor.overlays.isEmpty ? "Place your signature" : nil }
        ) { context in
            try await applyOverlays(context, suffix: "signed")
        },

        ToolDefinition(
            id: "pdf.redact", title: "Redact PDF", summary: "Permanently black out words and numbers",
            symbol: "eye.slash", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .text("terms", "Find and redact", placeholder: "Names, account numbers…", multiline: true, footnote: "Separate terms with commas or new lines. Matching pages are flattened so the hidden text is truly removed."),
                ToolOption.toggle("case", "Match case").advanced()
            ],
            keywords: ["black out", "censor", "hide", "privacy", "remove text"], actionTitle: "Redact",
            validate: { values, _, _ in values.string("terms").nilIfBlank == nil ? "Type the words to hide" : nil }
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let terms = context.options.string("terms").components(separatedBy: CharacterSet(charactersIn: ",\n")).compactMap(\.nilIfBlank)
            var items = PDFStamper.redactionItems(for: terms, in: document, caseSensitive: context.options.bool("case"))
            items += context.editor.overlays
            guard !items.isEmpty else { throw DocumentError.empty("None of those terms were found in the PDF.") }
            let pages = Set(items.map(\.pageIndex)).count
            let data = try await background { PDFStamper.apply(items, to: document) }
            return ToolOutput(files: [try ToolHelpers.write(data, "\(input.baseName)-redacted", "pdf", context)], summary: "\(items.count) redaction\(items.count == 1 ? "" : "s") on \(ToolHelpers.pageCountSummary(pages))")
        },

        ToolDefinition(
            id: "pdf.crop", title: "Crop PDF", summary: "Trim margins or cut pages to size",
            symbol: "crop", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .choice("mode", "Mode", [ToolChoice("auto", "Trim whitespace"), ToolChoice("margins", "Custom margins")], segmented: true),
                .slider("top", "Top", range: 0 ... 300, default: 36, section: "Margins", format: { "\(Int($0)) pt" }, visible: { $0.string("mode") == "margins" }),
                .slider("bottom", "Bottom", range: 0 ... 300, default: 36, section: "Margins", format: { "\(Int($0)) pt" }, visible: { $0.string("mode") == "margins" }),
                .slider("left", "Left", range: 0 ... 300, default: 36, section: "Margins", format: { "\(Int($0)) pt" }, visible: { $0.string("mode") == "margins" }),
                .slider("right", "Right", range: 0 ... 300, default: 36, section: "Margins", format: { "\(Int($0)) pt" }, visible: { $0.string("mode") == "margins" }),
                ToolHelpers.pagesOption
            ],
            keywords: ["trim", "margins", "cut", "whitespace"], actionTitle: "Crop"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let output: PDFDocument
            if context.options.string("mode") == "margins" {
                let insets = PDFToolkit.CropInsets(top: context.options.double("top"), left: context.options.double("left"), bottom: context.options.double("bottom"), right: context.options.double("right"))
                output = try PDFToolkit.crop(document, insets: insets, pages: try ToolHelpers.pageSet(context.options.string("pages"), pageCount: document.pageCount))
            } else {
                let pages = try ToolHelpers.pageSet(context.options.string("pages"), pageCount: document.pageCount)
                output = try await background { PDFToolkit.autoTrim(document, pages: pages) }
            }
            let url = context.outputURL("\(input.baseName)-cropped", "pdf")
            try PDFToolkit.write(output, to: url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "pdf.ocr", title: "Make Searchable (OCR)", summary: "Recognize text in scanned PDFs, on device",
            symbol: "text.viewfinder", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                ToolOption.choice("language", "Language", OCRLanguages.choices).advanced(),
                ToolOption.toggle("force", "Re-recognize pages that already have text").advanced(),
                ToolOption.toggle("text", "Also save a .txt file", default: false).advanced()
            ],
            keywords: ["ocr", "scan", "recognize", "searchable", "selectable", "text"], actionTitle: "Make Searchable"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let languages = OCRLanguages.languages(for: context.options.string("language"))
            let force = context.options.bool("force")
            let progress = context.progress
            let result = try await background { try PDFOCR.makeSearchable(document, languages: languages, force: force) { progress.report($0) } }
            var urls = [try ToolHelpers.write(result.data, "\(input.baseName)-searchable", "pdf", context)]
            if context.options.bool("text") {
                urls.append(try ToolHelpers.write(Data(result.text.utf8), input.baseName, "txt", context))
            }
            return ToolOutput(files: urls, text: result.text.nilIfBlank)
        },

        ToolDefinition(
            id: "pdf.flatten", title: "Flatten PDF", summary: "Bake form fields and annotations into pages",
            symbol: "square.stack.3d.down.forward", category: .pdf, input: .one([.pdf], noun: "PDF"),
            keywords: ["forms", "annotations", "lock fields"], actionTitle: "Flatten"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let url = context.outputURL("\(input.baseName)-flattened", "pdf")
            try PDFToolkit.flatten(document, to: url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "pdf.grayscale", title: "Grayscale PDF", summary: "Convert pages to black and white for printing",
            symbol: "circle.lefthalf.filled", category: .pdf, input: .one([.pdf], noun: "PDF"),
            keywords: ["black and white", "greyscale", "monochrome", "print"], actionTitle: "Convert"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let url = context.outputURL("\(input.baseName)-grayscale", "pdf")
            let password = context.password
            if Ghostscript.isAvailable {
                do {
                    // Converts the colors themselves, so text stays text and vectors stay sharp.
                    try await Ghostscript.cancellable { flag in try Ghostscript.grayscale(input.url, to: url, password: password, cancel: flag) }
                    if let rewrite = PDFDocument(url: url), PDFFidelity.looksTheSame(document, rewrite, grayscale: true) {
                        return ToolOutput(files: [url])
                    }
                    DiagnosticsLog.shared.record(message: "Ghostscript grayscale renders differently; re-rendering pages", context: "Ghostscript grayscale")
                    try? FileManager.default.removeItem(at: url)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    DiagnosticsLog.shared.record(error: error, context: "Ghostscript grayscale")
                }
            }
            let data = try await background { PDFStamper.render(document, rasterDPI: 150, grayscale: true) }
            try data.write(to: url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "pdf.repair", title: "Repair PDF", summary: "Rebuild damaged PDFs that won't open elsewhere",
            symbol: "bandage", category: .pdf, input: .one([.pdf], noun: "PDF"),
            keywords: ["fix", "corrupt", "broken", "damaged", "recover", "rebuild"], actionTitle: "Repair"
        ) { context in
            let input = try context.first
            guard Ghostscript.isAvailable else { throw DocumentError.unsupportedFormat("PDF repair") }
            let url = context.outputURL("\(input.baseName)-repaired", "pdf")
            let password = context.password
            let report = try await Ghostscript.cancellable { flag in try PDFRepair.repair(input.url, to: url, password: password, cancel: flag) }
            let pages = report.pageCount
            let summary = report.problems.isEmpty
                ? "Rebuilt cleanly · \(ToolHelpers.pageCountSummary(pages))"
                : "Fixed \(report.problems.count) problem\(report.problems.count == 1 ? "" : "s") · \(ToolHelpers.pageCountSummary(pages))"
            return ToolOutput(files: [url], summary: summary, text: report.problems.isEmpty ? nil : report.problems.joined(separator: "\n"))
        },

        ToolDefinition(
            id: "pdf.pdfa", title: "Convert to PDF/A", summary: "Archive-ready PDFs for records and court filings",
            symbol: "archivebox", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                ToolOption.choice("part", "Standard", [ToolChoice("2", "PDF/A-2b"), ToolChoice("1", "PDF/A-1b"), ToolChoice("3", "PDF/A-3b")], segmented: true,
                                  footnote: "PDF/A-2b suits most archives. Choose 1b only if a portal asks for it: it can't hold transparency, so pages that use it become images. Fonts are embedded and colors set to sRGB; passwords and form fields are removed.").advanced()
            ],
            keywords: ["pdfa", "pdf/a", "archive", "archival", "iso 19005", "long term", "court", "records"], actionTitle: "Make PDF/A"
        ) { context in
            let input = try context.first
            guard Ghostscript.isAvailable else { throw DocumentError.unsupportedFormat("PDF/A") }
            let part = min(max(context.options.int("part"), 1), 3)
            let url = context.outputURL("\(input.baseName)-PDFA", "pdf")
            let password = context.password
            try await Ghostscript.cancellable { flag in try Ghostscript.pdfA(input.url, to: url, part: part, password: password, cancel: flag) }
            return ToolOutput(files: [url], summary: "PDF/A-\(part)b · fonts embedded")
        },

        ToolDefinition(
            id: "pdf.metadata", title: "Edit PDF Properties", summary: "Change title, author and keywords, or strip them",
            symbol: "info.circle", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .toggle("strip", "Remove all properties"),
                .text("title", "Title", placeholder: "Keep current", visible: { !$0.bool("strip") }),
                .text("author", "Author", placeholder: "Keep current", visible: { !$0.bool("strip") }),
                .text("subject", "Subject", placeholder: "Keep current", visible: { !$0.bool("strip") }),
                .text("keywords", "Keywords", placeholder: "Comma separated", visible: { !$0.bool("strip") })
            ],
            keywords: ["metadata", "title", "author", "properties", "privacy"], actionTitle: "Save"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let copy = PDFToolkit.document(from: document, pageIndices: Array(0 ..< document.pageCount))
            if context.options.bool("strip") {
                PDFToolkit.setMetadata(.init(), on: copy, clearOthers: true)
            } else {
                var metadata = PDFToolkit.metadata(of: document)
                func apply(_ key: String, _ path: WritableKeyPath<PDFToolkit.Metadata, String?>) {
                    if let value = context.options.string(key).nilIfBlank { metadata[keyPath: path] = value }
                }
                apply("title", \.title)
                apply("author", \.author)
                apply("subject", \.subject)
                apply("keywords", \.keywords)
                PDFToolkit.setMetadata(metadata, on: copy)
            }
            let url = context.outputURL(input.baseName, "pdf")
            try PDFToolkit.write(copy, to: url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "pdf.reverse", title: "Reverse PDF", summary: "Flip the page order back to front",
            symbol: "arrow.up.arrow.down", category: .pdf, input: .one([.pdf], noun: "PDF"),
            keywords: ["backwards", "invert order"], actionTitle: "Reverse"
        ) { context in
            let input = try context.first
            let output = PDFToolkit.reverse(try ToolHelpers.openPDF(input, context))
            let url = context.outputURL("\(input.baseName)-reversed", "pdf")
            try PDFToolkit.write(output, to: url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "pdf.removeblank", title: "Remove Blank Pages", summary: "Drop empty pages from scans",
            symbol: "doc.badge.ellipsis", category: .pdf, input: .one([.pdf], noun: "PDF"),
            keywords: ["empty", "clean", "scan"], actionTitle: "Clean Up"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let blanks = try await background { PDFToolkit.blankPageIndices(document) }
            guard !blanks.isEmpty else { throw DocumentError.empty("No blank pages were found.") }
            let output = try PDFToolkit.deletePages(document, remove: blanks)
            let url = context.outputURL("\(input.baseName)-cleaned", "pdf")
            try PDFToolkit.write(output, to: url)
            return ToolOutput(files: [url], summary: "Removed \(ToolHelpers.pageCountSummary(blanks.count))")
        },

        ToolDefinition(
            id: "pdf.toimages", title: "PDF to Images", summary: "Save pages as JPG, PNG, HEIC or TIFF",
            symbol: "photo.on.rectangle", category: .pdf, input: .one([.pdf], noun: "PDF"),
            options: [
                .choice("format", "Format", [ToolChoice("jpeg", "JPEG"), ToolChoice("png", "PNG"), ToolChoice("heic", "HEIC"), ToolChoice("tiff", "TIFF (one file)")], segmented: false),
                ToolOption.choice("dpi", "Resolution", [ToolChoice("72", "72 dpi"), ToolChoice("150", "150 dpi"), ToolChoice("300", "300 dpi")], default: "150", segmented: true).advanced(),
                ToolOption.slider("quality", "Quality", range: 30 ... 100, default: 85, format: { "\(Int($0))%" }, visible: { ["jpeg", "heic"].contains($0.string("format")) }).advanced(),
                ToolHelpers.pagesOption
            ],
            keywords: ["pdf to jpg", "pdf to png", "pdf to tiff", "convert", "pages to pictures"], isFeatured: true, actionTitle: "Convert"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let dpi = CGFloat(context.options.double("dpi"))
            let pages = try ToolHelpers.pageSet(context.options.string("pages"), pageCount: document.pageCount).map { $0.sorted() }
            if context.options.string("format") == "tiff" {
                let data = try await background { try PDFToImages.multipageTIFF(document, pages: pages, dpi: dpi) }
                return ToolOutput(files: [try ToolHelpers.write(data, input.baseName, "tiff", context)])
            }
            let format = context.options.choice("format", as: PDFToImages.Format.self, default: .jpeg)
            let quality = context.options.double("quality") / 100
            let images = try await background { try PDFToImages.render(document, pages: pages, format: format, dpi: dpi, quality: quality) }
            let urls = try images.map { try ToolHelpers.write($0.data, "\(input.baseName)-page-\($0.index + 1)", format.fileExtension, context) }
            return ToolOutput(files: urls, summary: "\(urls.count) image\(urls.count == 1 ? "" : "s") at \(Int(dpi)) dpi")
        },

        ToolDefinition(
            id: "pdf.fromimages", title: "Images to PDF", summary: "Turn photos and scans into a PDF",
            symbol: "photo.stack", category: .pdf, input: .many(Set(FileFormat.stillImages), noun: "images"),
            options: [
                .choice("page", "Page size", ImagesToPDF.PageSizing.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: ImagesToPDF.PageSizing.a4.rawValue),
                ToolOption.choice("orientation", "Orientation", ImagesToPDF.Orientation.allCases.map { ToolChoice($0.rawValue, $0.label) }, segmented: true, visible: { $0.string("page") != "fitImage" }).advanced(),
                ToolOption.choice("fit", "Image fit", ImagesToPDF.Fit.allCases.map { ToolChoice($0.rawValue, $0.label) }, segmented: true, visible: { $0.string("page") != "fitImage" }).advanced(),
                ToolOption.choice("margin", "Margins", [ToolChoice("0", "None"), ToolChoice("18", "Small"), ToolChoice("36", "Large")], default: "18", segmented: true).advanced(),
                ToolOption.choice("quality", "Image quality", [ToolChoice("high", "High"), ToolChoice("medium", "Medium"), ToolChoice("original", "Original")], segmented: true, footnote: "Medium makes much smaller files; Original keeps full resolution.").advanced()
            ],
            keywords: ["jpg to pdf", "png to pdf", "heic to pdf", "photo to pdf", "scan", "create pdf", "tiff to pdf"], isFeatured: true, actionTitle: "Create PDF"
        ) { context in
            var options = ImagesToPDF.Options()
            options.pageSizing = context.options.choice("page", as: ImagesToPDF.PageSizing.self, default: .a4)
            options.orientation = context.options.choice("orientation", as: ImagesToPDF.Orientation.self, default: .auto)
            options.fit = context.options.choice("fit", as: ImagesToPDF.Fit.self, default: .fit)
            options.margin = CGFloat(context.options.double("margin"))
            switch context.options.string("quality") {
            case "medium": options.maxPixelSize = 1_600; options.jpegQuality = 0.7
            case "original": options.maxPixelSize = nil; options.jpegQuality = 0.95
            default: options.maxPixelSize = 2_800; options.jpegQuality = 0.85
            }
            let urls = context.inputs.map(\.url)
            let data = try await background { try ImagesToPDF.makePDF(from: urls, options: options) }
            let name = context.inputs.count == 1 ? try context.first.baseName : "Images"
            return ToolOutput(files: [try ToolHelpers.write(data, name, "pdf", context)], summary: ToolHelpers.pageCountSummary(urls.count))
        },

        ToolDefinition(
            id: "pdf.extractimages", title: "Extract Images", summary: "Save every embedded picture from a PDF",
            symbol: "photo.badge.arrow.down", category: .pdf, input: .one([.pdf], noun: "PDF"),
            keywords: ["pictures", "photos", "graphics", "export images"], actionTitle: "Extract"
        ) { context in
            let input = try context.first
            let document = try ToolHelpers.openPDF(input, context)
            let images = try await background { PDFImageExtractor.extract(document) }
            guard !images.isEmpty else { throw DocumentError.empty("This PDF doesn't contain extractable images.") }
            let urls = try images.enumerated().map { index, image in
                try ToolHelpers.write(image.data, "\(input.baseName)-image-\(index + 1)", image.fileExtension, context)
            }
            return ToolOutput(files: urls, summary: "\(urls.count) image\(urls.count == 1 ? "" : "s")")
        }
    ]

    @MainActor
    static func applyOverlays(_ context: ToolContext, suffix: String) async throws -> ToolOutput {
        let input = try context.first
        let document = try ToolHelpers.openPDF(input, context)
        let items = context.editor.overlays
        guard !items.isEmpty else { throw DocumentError.invalidOption("Add something to a page first.") }
        let data = try await background { PDFStamper.apply(items, to: document) }
        return ToolOutput(files: [try ToolHelpers.write(data, "\(input.baseName)-\(suffix)", "pdf", context)])
    }
}

enum OCRLanguages {
    static let choices: [ToolChoice] = [
        ToolChoice("auto", "Automatic"),
        ToolChoice("en-US", "English"),
        ToolChoice("es-ES", "Spanish"),
        ToolChoice("fr-FR", "French"),
        ToolChoice("de-DE", "German"),
        ToolChoice("it-IT", "Italian"),
        ToolChoice("pt-BR", "Portuguese"),
        ToolChoice("zh-Hans", "Chinese (Simplified)"),
        ToolChoice("zh-Hant", "Chinese (Traditional)"),
        ToolChoice("ja-JP", "Japanese"),
        ToolChoice("ko-KR", "Korean"),
        ToolChoice("uk-UA", "Ukrainian"),
        ToolChoice("ru-RU", "Russian")
    ]

    static func languages(for value: String) -> [String]? {
        value == "auto" || value.isEmpty ? nil : [value]
    }
}
