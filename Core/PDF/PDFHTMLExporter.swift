import Foundation
import PDFKit
import UIKit

/// A self-contained web page that looks exactly like the PDF: each page is drawn as a
/// high-resolution image with the page's real text laid invisibly on top, so it can be
/// selected, copied and found with the browser's search. Links stay clickable.
enum PDFHTMLExporter {
    struct Options {
        /// Page images are rendered at this many pixels per CSS pixel (2 = sharp on Retina).
        var density: CGFloat = 2
        var jpegQuality: CGFloat = 0.82
        var title: String?
        var progress: ((Double) -> Void)?
    }

    static func html(for document: PDFDocument, pages: [Int]? = nil, options: Options = Options()) throws -> String {
        let indices = pages ?? Array(0 ..< document.pageCount)
        guard !indices.isEmpty else { throw DocumentError.empty("The PDF has no pages.") }
        // Long documents get slightly softer page images so the file stays shareable.
        let density = indices.count > 40 ? min(options.density, 1.5) : options.density
        let attributes = document.documentAttributes ?? [:]
        let title = options.title?.nilIfBlank
            ?? (attributes[PDFDocumentAttribute.titleAttribute] as? String)?.nilIfBlank
            ?? document.documentURL?.deletingPathExtension().lastPathComponent
            ?? "Document"

        var body = ""
        for (position, index) in indices.enumerated() {
            guard let page = document.page(at: index) else { continue }
            try autoreleasepool {
                body += try pageHTML(page, number: index + 1, density: density, quality: options.jpegQuality)
            }
            options.progress?(Double(position + 1) / Double(indices.count))
        }
        return """
        <!DOCTYPE html>
        <html lang="\(Locale.current.language.languageCode?.identifier ?? "en")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="MB Converter">
        <title>\(XMLEscaping.escape(title))</title>
        <style>
        html { background: #e8eaee; }
        body { margin: 0; font-family: -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; }
        main { display: flex; flex-direction: column; align-items: center; gap: 20px; padding: 20px 12px 40px; }
        .page { position: relative; width: 100%; container-type: inline-size; background: #fff;
                box-shadow: 0 1px 2px rgba(0,0,0,.12), 0 4px 16px rgba(0,0,0,.08); overflow: hidden; }
        .page > img { position: absolute; inset: 0; width: 100%; height: 100%; display: block;
                      user-select: none; -webkit-user-select: none; pointer-events: none; }
        .t { position: absolute; margin: 0; white-space: pre; line-height: 1; color: transparent;
             transform-origin: 0 0; font-family: inherit; }
        .t::selection { background: rgba(10, 132, 255, .28); }
        .page > a { position: absolute; display: block; }
        @media (prefers-color-scheme: dark) { html { background: #1c1c1e; } }
        @media print {
          html { background: #fff; }
          main { padding: 0; gap: 0; }
          .page { box-shadow: none; break-after: page; max-width: none !important; }
        }
        </style>
        </head>
        <body>
        <main>
        \(body)</main>
        <script>
        // Stretch each invisible line to the width it occupies in the PDF so selections line up.
        function fit() {
          document.querySelectorAll('.t').forEach(function (line) {
            line.style.transform = 'none';
            var target = parseFloat(line.dataset.w) / 100 * line.parentElement.clientWidth;
            var actual = line.getBoundingClientRect().width;
            if (actual > 0 && target > 0) line.style.transform = 'scaleX(' + (target / actual) + ')';
          });
        }
        window.addEventListener('load', fit);
        window.addEventListener('resize', fit);
        </script>
        </body>
        </html>
        """
    }

    static func write(_ document: PDFDocument, to url: URL, options: Options = Options()) throws {
        try Data(html(for: document, options: options).utf8).write(to: url, options: .atomic)
    }

    // MARK: - Pages

    private static func pageHTML(_ page: PDFPage, number: Int, density: CGFloat, quality: CGFloat) throws -> String {
        let box = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        // Displayed size in points (rotation swaps the axes).
        let size = rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
        guard size.width > 0, size.height > 0 else { return "" }
        let cssWidth = size.width * 96 / 72
        let dpi = 96 * density
        guard let image = PDFRasterizer.jpegData(page: page, dpi: dpi, quality: quality) else {
            throw DocumentError.writeFailed("Couldn't render page \(number).")
        }

        var html = """
        <section class="page" id="page-\(number)" style="max-width: \(css(cssWidth))px; aspect-ratio: \(css(size.width)) / \(css(size.height));">
        <img src="data:image/jpeg;base64,\(image.base64EncodedString())" alt="Page \(number)">

        """
        // Map page space (origin bottom-left of the crop box, possibly rotated) to top-left percentages.
        func displayRect(_ rect: CGRect) -> CGRect {
            let r = rect.offsetBy(dx: -box.minX, dy: -box.minY)
            switch rotation {
            case 90: return CGRect(x: r.minY, y: r.minX, width: r.height, height: r.width)
            case 180: return CGRect(x: box.width - r.maxX, y: r.minY, width: r.width, height: r.height)
            case 270: return CGRect(x: box.height - r.maxY, y: box.width - r.maxX, width: r.height, height: r.width)
            default: return CGRect(x: r.minX, y: box.height - r.maxY, width: r.width, height: r.height)
            }
        }

        if rotation == 0 || rotation == 180 {
            for line in PDFTextReader.lines(on: page) {
                let rect = displayRect(line.bounds)
                guard rect.width > 0, rect.height > 0 else { continue }
                let fontSize = min(line.fontSize, rect.height) / size.width * 100
                let style = "left: \(percent(rect.minX / size.width)); top: \(percent(rect.minY / size.height)); font-size: \(css(fontSize))cqw;"
                html += "<p class=\"t\" style=\"\(style)\" data-w=\"\(css(rect.width / size.width * 100))\">\(XMLEscaping.escape(line.plain))</p>\n"
            }
        } else {
            // Rotated pages keep their text searchable in reading order without positional overlay.
            let text = page.string ?? ""
            if !text.isEmpty {
                html += "<p class=\"t\" style=\"left: 0; top: 0; font-size: 0.1cqw; white-space: pre-wrap;\">\(XMLEscaping.escape(text))</p>\n"
            }
        }

        for annotation in page.annotations where annotation.type == "Link" {
            let target: String?
            if let url = annotation.url {
                target = url.absoluteString
            } else if let destination = annotation.destination?.page, let document = page.document {
                target = "#page-\(document.index(for: destination) + 1)"
            } else {
                target = nil
            }
            guard let target else { continue }
            let rect = displayRect(annotation.bounds)
            let external = target.hasPrefix("#") ? "" : " target=\"_blank\" rel=\"noopener\""
            html += "<a href=\"\(XMLEscaping.escape(target))\"\(external) style=\"left: \(percent(rect.minX / size.width)); top: \(percent(rect.minY / size.height)); width: \(percent(rect.width / size.width)); height: \(percent(rect.height / size.height));\" aria-label=\"\(XMLEscaping.escape(target))\"></a>\n"
        }
        html += "</section>\n"
        return html
    }

    private static func percent(_ fraction: CGFloat) -> String { css(fraction * 100) + "%" }

    private static func css(_ value: CGFloat) -> String {
        var text = String(format: "%.3f", Double(value))
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
