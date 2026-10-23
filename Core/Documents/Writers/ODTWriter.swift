import CoreGraphics
import Foundation
import ImageIO

/// Writes OpenDocument Text (.odt), the ISO/IEC 26300 format used by LibreOffice and others.
enum ODTWriter {
    static let mimeType = "application/vnd.oasis.opendocument.text"

    static func write(_ document: RichDocument, options: DocumentExportOptions = .default, to url: URL) throws {
        var context = Context(options: options)
        let body = document.blocks.map { context.block($0) }.joined()
        let package = ZipPackageWriter()
        // The mimetype entry must come first and be stored uncompressed.
        package.add("mimetype", string: mimeType, compressed: false)
        package.add("content.xml", string: contentXML(body: body, automaticStyles: context.automaticStyles))
        package.add("styles.xml", string: stylesXML(options: options))
        package.add("meta.xml", string: metaXML(document.metadata, options: options))
        for image in context.images {
            package.add(image.path, data: image.data, compressed: false)
        }
        package.add("META-INF/manifest.xml", string: manifestXML(images: context.images))
        try package.write(to: url)
    }

    static let namespaces = """
    xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:style="urn:oasis:names:tc:opendocument:xmlns:style:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:draw="urn:oasis:names:tc:opendocument:xmlns:drawing:1.0" xmlns:fo="urn:oasis:names:tc:opendocument:xmlns:xsl-fo-compatible:1.0" xmlns:xlink="http://www.w3.org/1999/xlink" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:meta="urn:oasis:names:tc:opendocument:xmlns:meta:1.0" xmlns:number="urn:oasis:names:tc:opendocument:xmlns:datastyle:1.0" xmlns:svg="urn:oasis:names:tc:opendocument:xmlns:svg-compatible:1.0" office:version="1.3"
    """

    private struct EmbeddedImage {
        let path: String
        let mimeType: String
        let data: Data
    }

    private struct Context {
        let options: DocumentExportOptions
        var textStyles: [RunStyle: String] = [:]
        var images: [EmbeddedImage] = []
        var tableCount = 0

        init(options: DocumentExportOptions) {
            self.options = options
        }

        var automaticStyles: String {
            var xml = """
            <style:style style:name="PCenter" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="center"/></style:style><style:style style:name="PRight" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="end"/></style:style><style:style style:name="PJustify" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:text-align="justify"/></style:style><style:style style:name="PBreak" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:break-before="page"/></style:style><style:style style:name="PRule" style:family="paragraph" style:parent-style-name="Standard"><style:paragraph-properties fo:border-bottom="0.75pt solid #b8c2cc" fo:padding="0pt"/></style:style><style:style style:name="Tbl" style:family="table"><style:table-properties table:align="margins"/></style:style><style:style style:name="Cell" style:family="table-cell"><style:table-cell-properties fo:padding="0.05in" fo:border="0.75pt solid #b8c2cc"/></style:style><style:style style:name="HeadCell" style:family="table-cell"><style:table-cell-properties fo:padding="0.05in" fo:border="0.75pt solid #b8c2cc" fo:background-color="#eef2f6"/></style:style><style:style style:name="HeadText" style:family="paragraph" style:parent-style-name="Table_20_Contents"><style:text-properties fo:font-weight="bold"/></style:style><text:list-style style:name="LBullet">
            """
            let bullets = ["•", "◦", "▪"]
            for level in 1 ... 10 {
                xml += "<text:list-level-style-bullet text:level=\"\(level)\" text:bullet-char=\"\(bullets[(level - 1) % 3])\"><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" fo:text-indent=\"-0.25in\" fo:margin-left=\"\(String(format: "%.2f", 0.5 * Double(level)))in\"/></style:list-level-properties></text:list-level-style-bullet>"
            }
            xml += "</text:list-style><text:list-style style:name=\"LNumber\">"
            for level in 1 ... 10 {
                let format = ["1", "a", "i"][(level - 1) % 3]
                xml += "<text:list-level-style-number text:level=\"\(level)\" style:num-suffix=\".\" style:num-format=\"\(format)\"><style:list-level-properties text:list-level-position-and-space-mode=\"label-alignment\"><style:list-level-label-alignment text:label-followed-by=\"listtab\" fo:text-indent=\"-0.25in\" fo:margin-left=\"\(String(format: "%.2f", 0.5 * Double(level)))in\"/></style:list-level-properties></text:list-level-style-number>"
            }
            xml += "</text:list-style>"
            for (style, name) in textStyles.sorted(by: { $0.value < $1.value }) {
                var props = ""
                if style.bold { props += " fo:font-weight=\"bold\" style:font-weight-asian=\"bold\" style:font-weight-complex=\"bold\"" }
                if style.italic { props += " fo:font-style=\"italic\" style:font-style-asian=\"italic\" style:font-style-complex=\"italic\"" }
                if style.underline { props += " style:text-underline-style=\"solid\" style:text-underline-width=\"auto\" style:text-underline-color=\"font-color\"" }
                if style.strikethrough { props += " style:text-line-through-style=\"solid\" style:text-line-through-type=\"single\"" }
                if style.superscript { props += " style:text-position=\"super 58%\"" }
                if style.subscript { props += " style:text-position=\"sub 58%\"" }
                if style.code { props += " style:font-name=\"Courier New\" fo:font-family=\"'Courier New'\"" }
                xml += "<style:style style:name=\"\(name)\" style:family=\"text\"><style:text-properties\(props)/></style:style>"
            }
            return xml
        }


        mutating func frame(_ image: ImageBlock, size: CGSize) -> String {

            let index = images.count + 1

            let path = "Pictures/image\(index).\(image.fileExtension)"

            images.append(EmbeddedImage(path: path, mimeType: image.mimeType, data: image.data))

            let alt = XMLEscaping.escape(image.altText ?? "")

            return "<draw:frame draw:name=\"Image\(index)\" text:anchor-type=\"as-char\" svg:width=\"\(String(format: "%.2f", size.width))pt\" svg:height=\"\(String(format: "%.2f", size.height))pt\"><draw:image xlink:href=\"\(path)\" xlink:type=\"simple\" xlink:show=\"embed\" xlink:actuate=\"onLoad\"/><svg:desc>\(alt)</svg:desc></draw:frame>"

        }

        mutating func block(_ block: Block, inList: Bool = false) -> String {
            switch block {
            case .heading(let level, let runs):
                let clamped = min(max(level, 1), 6)
                return "<text:h text:style-name=\"Heading_20_\(clamped)\" text:outline-level=\"\(clamped)\">\(inline(runs))</text:h>"
            case .paragraph(let runs, let alignment):
                let style: String = switch alignment {
                case .center: "PCenter"
                case .right: "PRight"
                case .justified: "PJustify"
                default: inList ? "List_20_Contents" : "Standard"
                }
                return "<text:p text:style-name=\"\(style)\">\(inline(runs))</text:p>"
            case .list(let ordered, let items):
                return list(ordered: ordered, items: items, nested: false)
            case .table(let table):
                tableCount += 1
                let columns = max(table.columnCount, 1)
                var xml = "<table:table table:name=\"Table\(tableCount)\" table:style-name=\"Tbl\"><table:table-column table:number-columns-repeated=\"\(columns)\"/>"
                for (index, row) in table.rows.enumerated() {
                    let isHeader = table.hasHeaderRow && index == 0
                    if isHeader { xml += "<table:table-header-rows>" }
                    xml += "<table:table-row>"
                    for column in 0 ..< columns {
                        let cell = column < row.count ? row[column] : []
                        xml += "<table:table-cell table:style-name=\"\(isHeader ? "HeadCell" : "Cell")\" office:value-type=\"string\">"
                        if cell.isEmpty {
                            xml += "<text:p text:style-name=\"Table_20_Contents\"/>"
                        }
                        for child in cell {
                            if case .paragraph(let runs, _) = child {
                                xml += "<text:p text:style-name=\"\(isHeader ? "HeadText" : "Table_20_Contents")\">\(inline(runs))</text:p>"
                            } else {
                                xml += self.block(child)
                            }
                        }
                        xml += "</table:table-cell>"
                    }
                    xml += "</table:table-row>"
                    if isHeader { xml += "</table:table-header-rows>" }
                }
                return xml + "</table:table>"
            case .image(let image):
                guard options.includeImages else { return "" }
                let textWidth = max(72, options.pageRect.width - options.marginPoints * 2)
                var size = image.size ?? EmbeddedImageSizing.pointSize(of: image.data) ?? CGSize(width: 300, height: 200)
                if size.width > textWidth {
                    size = CGSize(width: textWidth, height: size.height * textWidth / size.width)
                }
                return "<text:p text:style-name=\"PCenter\">\(frame(image, size: size))</text:p>"
            case .imageRow(let row):
                guard options.includeImages, !row.isEmpty else { return "" }
                let textWidth = max(72, options.pageRect.width - options.marginPoints * 2)
                let sizes = ImageRowLayout.sizes(for: row, available: textWidth - 4, gap: 8)
                return "<text:p text:style-name=\"PCenter\">" + zip(row, sizes).map { frame($0, size: $1) }.joined(separator: "<text:s text:c=\"2\"/>") + "</text:p>"
            case .quote(let blocks):
                return blocks.map { child -> String in
                    if case .paragraph(let runs, _) = child {
                        return "<text:p text:style-name=\"Quotations\">\(inline(runs))</text:p>"
                    }
                    return self.block(child)
                }.joined()
            case .code(let code):
                return code.components(separatedBy: "\n").map { line in
                    "<text:p text:style-name=\"Preformatted_20_Text\">\(Self.escapeText(line))</text:p>"
                }.joined()
            case .rule:
                return "<text:p text:style-name=\"PRule\"/>"
            case .pageBreak:
                return "<text:p text:style-name=\"PBreak\"/>"
            }
        }

        mutating func list(ordered: Bool, items: [[Block]], nested: Bool) -> String {
            let styleAttribute = " text:style-name=\"\(ordered ? "LNumber" : "LBullet")\""
            var xml = "<text:list\(styleAttribute)>"
            for item in items {
                xml += "<text:list-item>"
                if item.isEmpty { xml += "<text:p text:style-name=\"List_20_Contents\"/>" }
                for child in item {
                    if case .list(let childOrdered, let childItems) = child {
                        xml += list(ordered: childOrdered, items: childItems, nested: true)
                    } else {
                        xml += block(child, inList: true)
                    }
                }
                xml += "</text:list-item>"
            }
            return xml + "</text:list>"
        }

        mutating func inline(_ runs: [Run]) -> String {
            var xml = ""
            for run in runs.coalesced() {
                var styleKey = run.style
                styleKey.link = nil
                var content = Self.escapeText(run.text)
                if styleKey != RunStyle() {
                    let name = textStyles[styleKey] ?? "T\(textStyles.count + 1)"
                    textStyles[styleKey] = name
                    content = "<text:span text:style-name=\"\(name)\">\(content)</text:span>"
                }
                if let link = run.style.link {
                    content = "<text:a xlink:type=\"simple\" xlink:href=\"\(XMLEscaping.escape(link))\">\(content)</text:a>"
                }
                xml += content
            }
            return xml
        }

        /// ODF collapses whitespace, so runs of spaces, tabs and newlines need explicit elements.
        static func escapeText(_ text: String) -> String {
            var xml = ""
            var spaces = 0
            func flushSpaces() {
                guard spaces > 0 else { return }
                xml += " "
                if spaces > 1 { xml += "<text:s text:c=\"\(spaces - 1)\"/>" }
                spaces = 0
            }
            for ch in text {
                switch ch {
                case " ":
                    spaces += 1
                case "\t":
                    flushSpaces(); xml += "<text:tab/>"
                case "\n":
                    flushSpaces(); xml += "<text:line-break/>"
                default:
                    flushSpaces(); xml += XMLEscaping.escape(String(ch))
                }
            }
            flushSpaces()
            return xml
        }
    }

    private static func contentXML(body: String, automaticStyles: String) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content \(namespaces)><office:font-face-decls/><office:automatic-styles>\(automaticStyles)</office:automatic-styles><office:body><office:text>\(body)</office:text></office:body></office:document-content>
        """
    }

    private static func stylesXML(options: DocumentExportOptions) -> String {
        let font = XMLEscaping.escape(options.fontFamily.officeFontName)
        let size = options.fontSize
        let page = options.pageRect
        let margin = options.marginPoints
        let headingScales = [2.0, 1.6, 1.3, 1.12, 1.0, 1.0]
        var headings = ""
        for (index, scale) in headingScales.enumerated() {
            headings += "<style:style style:name=\"Heading_20_\(index + 1)\" style:display-name=\"Heading \(index + 1)\" style:family=\"paragraph\" style:parent-style-name=\"Heading\" style:next-style-name=\"Standard\" style:default-outline-level=\"\(index + 1)\" style:class=\"text\"><style:text-properties fo:font-size=\"\(String(format: "%.1f", size * scale))pt\" fo:font-weight=\"bold\"/></style:style>"
        }
        let footer = options.pageNumbers
            ? "<style:footer><text:p text:style-name=\"Footer\"><text:page-number text:select-page=\"current\">1</text:page-number></text:p></style:footer>"
            : ""
        let lineHeight = Int((options.lineSpacing * 100).rounded())
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles \(namespaces)><office:font-face-decls><style:font-face style:name="\(font)" svg:font-family="'\(font)'"/><style:font-face style:name="Courier New" svg:font-family="'Courier New'" style:font-family-generic="modern" style:font-pitch="fixed"/></office:font-face-decls><office:styles><style:default-style style:family="paragraph"><style:paragraph-properties fo:line-height="\(lineHeight)%"/><style:text-properties style:font-name="\(font)" fo:font-family="'\(font)'" fo:color="#000000" fo:font-size="\(String(format: "%.1f", size))pt" fo:language="en" fo:country="US"/></style:default-style><style:style style:name="Standard" style:family="paragraph" style:class="text"><style:paragraph-properties fo:margin-top="0in" fo:margin-bottom="0.08in"/></style:style><style:style style:name="Heading" style:family="paragraph" style:parent-style-name="Standard" style:next-style-name="Standard" style:class="text"><style:paragraph-properties fo:margin-top="0.17in" fo:margin-bottom="0.08in" fo:keep-with-next="always"/></style:style>\(headings)<style:style style:name="List_20_Contents" style:display-name="List Contents" style:family="paragraph" style:parent-style-name="Standard" style:class="list"><style:paragraph-properties fo:margin-bottom="0.03in"/></style:style><style:style style:name="Quotations" style:family="paragraph" style:parent-style-name="Standard" style:class="html"><style:paragraph-properties fo:margin-left="0.4in" fo:margin-right="0.4in"/><style:text-properties fo:font-style="italic"/></style:style><style:style style:name="Preformatted_20_Text" style:display-name="Preformatted Text" style:family="paragraph" style:parent-style-name="Standard" style:class="html"><style:paragraph-properties fo:margin-top="0in" fo:margin-bottom="0in" fo:background-color="#f4f6f8"/><style:text-properties style:font-name="Courier New" fo:font-family="'Courier New'" fo:font-size="\(String(format: "%.1f", max(7, size - 1)))pt"/></style:style><style:style style:name="Table_20_Contents" style:display-name="Table Contents" style:family="paragraph" style:parent-style-name="Standard" style:class="extra"><style:paragraph-properties fo:margin-bottom="0in"/></style:style><style:style style:name="Footer" style:family="paragraph" style:parent-style-name="Standard" style:class="extra"><style:paragraph-properties fo:text-align="center"/></style:style></office:styles><office:automatic-styles><style:page-layout style:name="pm1"><style:page-layout-properties fo:page-width="\(String(format: "%.2f", page.width))pt" fo:page-height="\(String(format: "%.2f", page.height))pt" style:print-orientation="\(options.orientation.rawValue)" fo:background-color="#ffffff" fo:margin-top="\(Int(margin))pt" fo:margin-bottom="\(Int(margin))pt" fo:margin-left="\(Int(margin))pt" fo:margin-right="\(Int(margin))pt"/></style:page-layout></office:automatic-styles><office:master-styles><style:master-page style:name="Standard" style:page-layout-name="pm1">\(footer)</style:master-page></office:master-styles></office:document-styles>
        """
    }

    private static func metaXML(_ metadata: DocumentMetadata, options: DocumentExportOptions) -> String {
        var fields = "<meta:generator>MB Converter</meta:generator>"
        if let title = options.title ?? metadata.title { fields += "<dc:title>\(XMLEscaping.escape(title))</dc:title>" }
        if let author = options.author ?? metadata.author {
            fields += "<meta:initial-creator>\(XMLEscaping.escape(author))</meta:initial-creator><dc:creator>\(XMLEscaping.escape(author))</dc:creator>"
        }
        if let subject = metadata.subject { fields += "<dc:subject>\(XMLEscaping.escape(subject))</dc:subject>" }
        for keyword in metadata.keywords { fields += "<meta:keyword>\(XMLEscaping.escape(keyword))</meta:keyword>" }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-meta \(namespaces)><office:meta>\(fields)</office:meta></office:document-meta>
        """
    }

    private static func manifestXML(images: [EmbeddedImage]) -> String {
        var entries = "<manifest:file-entry manifest:full-path=\"/\" manifest:version=\"1.3\" manifest:media-type=\"\(mimeType)\"/><manifest:file-entry manifest:full-path=\"content.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"styles.xml\" manifest:media-type=\"text/xml\"/><manifest:file-entry manifest:full-path=\"meta.xml\" manifest:media-type=\"text/xml\"/>"
        for image in images {
            entries += "<manifest:file-entry manifest:full-path=\"\(image.path)\" manifest:media-type=\"\(image.mimeType)\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.3">\(entries)</manifest:manifest>
        """
    }
}

/// Shared helper for converting embedded image pixels to points.
enum EmbeddedImageSizing {
    static func pointSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? CGFloat,
              let height = properties[kCGImagePropertyPixelHeight] as? CGFloat,
              width > 0, height > 0
        else { return nil }
        return CGSize(width: width * 0.75, height: height * 0.75)
    }
}
