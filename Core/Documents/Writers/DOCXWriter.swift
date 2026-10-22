import CoreGraphics
import Foundation
import ImageIO

/// Writes Office Open XML word-processing documents (.docx).
enum DOCXWriter {
    static func write(_ document: RichDocument, options: DocumentExportOptions = .default, to url: URL) throws {
        var context = Context(options: options)
        let body = context.blocks(document.blocks, listLevel: nil)
        var footerID: String?
        if options.pageNumbers {
            let id = "rId\(context.relationships.count + 1)"
            context.relationships.append(Relationship(id: id, type: "footer", target: "footer1.xml", external: false))
            footerID = id
        }
        let package = ZipPackageWriter()
        package.add("[Content_Types].xml", string: contentTypes(imageExtensions: Set(context.media.map(\.ext)), hasFooter: footerID != nil))
        package.add("_rels/.rels", string: rootRelationships)
        package.add("docProps/core.xml", string: coreProperties(document.metadata, options: options))
        package.add("docProps/app.xml", string: appProperties)
        package.add("word/document.xml", string: documentXML(body: body, options: options, footerID: footerID))
        if footerID != nil {
            package.add("word/footer1.xml", string: footerXML)
        }
        package.add("word/styles.xml", string: stylesXML(options: options))
        package.add("word/numbering.xml", string: numberingXML(numbers: context.numberings))
        package.add("word/settings.xml", string: settingsXML)
        package.add("word/_rels/document.xml.rels", string: documentRelationships(context.relationships))
        for item in context.media {
            package.add("word/media/\(item.name)", data: item.data, compressed: false)
        }
        try package.write(to: url)
    }

    // MARK: - Body

    private struct Relationship {
        let id: String
        let type: String
        let target: String
        let external: Bool
    }

    private struct MediaItem {
        let name: String
        let ext: String
        let data: Data
    }

    private struct Context {
        let options: DocumentExportOptions
        var relationships: [Relationship] = [
            Relationship(id: "rId1", type: "styles", target: "styles.xml", external: false),
            Relationship(id: "rId2", type: "numbering", target: "numbering.xml", external: false),
            Relationship(id: "rId3", type: "settings", target: "settings.xml", external: false)
        ]
        var media: [MediaItem] = []
        /// Each list instance gets its own `w:num`; `true` = ordered.
        var numberings: [Bool] = []
        var drawingID = 1

        init(options: DocumentExportOptions) {
            self.options = options
        }

        var textWidthPoints: CGFloat {
            max(72, options.pageRect.width - options.marginPoints * 2)
        }

        mutating func blocks(_ blocks: [Block], listLevel: (numID: Int, level: Int)?) -> String {
            blocks.map { block($0, list: listLevel, isFirstInItem: false) }.joined()
        }

        mutating func block(_ block: Block, list: (numID: Int, level: Int)?, isFirstInItem: Bool) -> String {
            let indentProps = list.map { "<w:ind w:left=\"\(720 * ($0.level + 1))\"/>" } ?? ""
            switch block {
            case .heading(let level, let runs):
                let style = "Heading\(min(max(level, 1), 6))"
                return paragraph(props: "<w:pStyle w:val=\"\(style)\"/>", runs: runs)
            case .paragraph(let runs, let alignment):
                var props = ""
                if let list, isFirstInItem {
                    props += "<w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(list.level)\"/><w:numId w:val=\"\(list.numID)\"/></w:numPr>"
                } else {
                    props += indentProps
                }
                switch alignment {
                case .center: props += "<w:jc w:val=\"center\"/>"
                case .right: props += "<w:jc w:val=\"right\"/>"
                case .justified: props += "<w:jc w:val=\"both\"/>"
                default: break
                }
                return paragraph(props: props, runs: runs)
            case .list(let ordered, let items):
                numberings.append(ordered)
                let numID = numberings.count
                let level = list.map { $0.level + 1 } ?? 0
                var xml = ""
                for item in items {
                    var first = true
                    if item.isEmpty {
                        xml += self.block(.paragraph(runs: []), list: (numID, level), isFirstInItem: true)
                    }
                    for child in item {
                        if case .list = child {
                            xml += self.block(child, list: (numID, level), isFirstInItem: false)
                        } else if first, case .paragraph = child {
                            xml += self.block(child, list: (numID, level), isFirstInItem: true)
                        } else if first {
                            // Lists whose items start with a non-paragraph still need a numbered marker.
                            xml += self.block(.paragraph(runs: []), list: (numID, level), isFirstInItem: true)
                            xml += self.block(child, list: (numID, level), isFirstInItem: false)
                        } else {
                            xml += self.block(child, list: (numID, level), isFirstInItem: false)
                        }
                        first = false
                    }
                }
                return xml
            case .table(let table):
                return self.table(table)
            case .image(let image):
                guard options.includeImages else { return "" }
                return "<w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>\(drawing(image))</w:p>"
            case .quote(let blocks):
                return blocks.map { child -> String in
                    if case .paragraph(let runs, _) = child {
                        return paragraph(props: "<w:pStyle w:val=\"Quote\"/>", runs: runs)
                    }
                    return self.block(child, list: list, isFirstInItem: false)
                }.joined()
            case .code(let code):
                return code.components(separatedBy: "\n").map { line in
                    paragraph(props: "<w:pStyle w:val=\"Code\"/>", runs: [Run(line)])
                }.joined()
            case .rule:
                return "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"B8C2CC\"/></w:pBdr></w:pPr></w:p>"
            case .pageBreak:
                return "<w:p><w:r><w:br w:type=\"page\"/></w:r></w:p>"
            }
        }

        mutating func paragraph(props: String, runs: [Run]) -> String {
            let pPr = props.isEmpty ? "" : "<w:pPr>\(props)</w:pPr>"
            return "<w:p>\(pPr)\(self.runs(runs))</w:p>"
        }

        mutating func runs(_ runs: [Run]) -> String {
            var xml = ""
            for run in runs.coalesced() {
                let content = runXML(run)
                if let link = run.style.link {
                    let id = "rId\(relationships.count + 1)"
                    relationships.append(Relationship(id: id, type: "hyperlink", target: link, external: true))
                    xml += "<w:hyperlink r:id=\"\(id)\">\(content)</w:hyperlink>"
                } else {
                    xml += content
                }
            }
            return xml
        }

        func runXML(_ run: Run) -> String {
            var props = ""
            let style = run.style
            if style.link != nil { props += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if style.code {
                props += "<w:rFonts w:ascii=\"Courier New\" w:hAnsi=\"Courier New\" w:cs=\"Courier New\"/>"
            }
            if style.bold { props += "<w:b/>" }
            if style.italic { props += "<w:i/>" }
            if style.strikethrough { props += "<w:strike/>" }
            if style.underline { props += "<w:u w:val=\"single\"/>" }
            if style.superscript { props += "<w:vertAlign w:val=\"superscript\"/>" }
            if style.subscript { props += "<w:vertAlign w:val=\"subscript\"/>" }
            let rPr = props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>"
            var content = ""
            var buffer = ""
            func flush() {
                guard !buffer.isEmpty else { return }
                content += "<w:t xml:space=\"preserve\">\(XMLEscaping.escape(buffer))</w:t>"
                buffer = ""
            }
            for ch in run.text {
                switch ch {
                case "\n": flush(); content += "<w:br/>"
                case "\t": flush(); content += "<w:tab/>"
                default: buffer.append(ch)
                }
            }
            flush()
            return "<w:r>\(rPr)\(content)</w:r>"
        }

        mutating func table(_ table: TableBlock) -> String {
            let columns = max(table.columnCount, 1)
            let totalTwips = Int(textWidthPoints * 20)
            let columnTwips = totalTwips / columns
            var xml = "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"\(totalTwips)\" w:type=\"dxa\"/>"
            xml += "<w:tblBorders>"
            for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] {
                xml += "<w:\(edge) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B8C2CC\"/>"
            }
            xml += "</w:tblBorders><w:tblLook w:val=\"04A0\" w:firstRow=\"1\"/></w:tblPr><w:tblGrid>"
            xml += String(repeating: "<w:gridCol w:w=\"\(columnTwips)\"/>", count: columns)
            xml += "</w:tblGrid>"
            for (rowIndex, row) in table.rows.enumerated() {
                let isHeader = table.hasHeaderRow && rowIndex == 0
                xml += isHeader ? "<w:tr><w:trPr><w:tblHeader/></w:trPr>" : "<w:tr>"
                for columnIndex in 0 ..< columns {
                    let cell = columnIndex < row.count ? row[columnIndex] : []
                    xml += "<w:tc><w:tcPr><w:tcW w:w=\"\(columnTwips)\" w:type=\"dxa\"/>"
                    if isHeader { xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"EEF2F6\"/>" }
                    xml += "</w:tcPr>"
                    var content = ""
                    for block in cell {
                        if isHeader, case .paragraph(let runs, let alignment) = block {
                            let boldRuns = runs.map { run -> Run in
                                var copy = run
                                copy.style.bold = true
                                return copy
                            }
                            content += self.block(.paragraph(runs: boldRuns, alignment: alignment), list: nil, isFirstInItem: false)
                        } else {
                            content += self.block(block, list: nil, isFirstInItem: false)
                        }
                    }
                    // Every cell must end with a paragraph.
                    if !content.hasSuffix("</w:p>") { content += "<w:p/>" }
                    xml += content + "</w:tc>"
                }
                xml += "</w:tr>"
            }
            return xml + "</w:tbl><w:p/>"
        }

        mutating func drawing(_ image: ImageBlock) -> String {
            let pixelSize = Self.pixelSize(of: image.data) ?? CGSize(width: 400, height: 300)
            var size = image.size ?? pixelSize
            if size.width > textWidthPoints {
                size = CGSize(width: textWidthPoints, height: size.height * textWidthPoints / size.width)
            }
            let ext = image.fileExtension == "jpeg" ? "jpeg" : image.fileExtension
            let name = "image\(media.count + 1).\(ext)"
            media.append(MediaItem(name: name, ext: ext, data: image.data))
            let id = "rId\(relationships.count + 1)"
            relationships.append(Relationship(id: id, type: "image", target: "media/\(name)", external: false))
            let cx = Int(size.width * 12700)
            let cy = Int(size.height * 12700)
            let docPr = drawingID
            drawingID += 1
            let alt = XMLEscaping.escape(image.altText ?? "Picture \(docPr)")
            return """
            <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(docPr)" name="Picture \(docPr)" descr="\(alt)"/><wp:cNvGraphicFramePr><a:graphicFrameLocks xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:nvPicPr><pic:cNvPr id="\(docPr)" name="\(name)" descr="\(alt)"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
            """
        }

        static func pixelSize(of data: Data) -> CGSize? {
            EmbeddedImageSizing.pointSize(of: data)
        }
    }

    // MARK: - Package parts

    private static let footerXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:ftr xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r></w:p></w:ftr>
    """

    private static func documentXML(body: String, options: DocumentExportOptions, footerID: String?) -> String {
        let page = options.pageRect
        let margin = Int(options.marginPoints * 20)
        let orient = options.orientation == .landscape ? " w:orient=\"landscape\"" : ""
        let footer = footerID.map { "<w:footerReference w:type=\"default\" r:id=\"\($0)\"/>" } ?? ""
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>\(body)<w:sectPr>\(footer)<w:pgSz w:w="\(Int(page.width * 20))" w:h="\(Int(page.height * 20))"\(orient)/><w:pgMar w:top="\(margin)" w:right="\(margin)" w:bottom="\(margin)" w:left="\(margin)" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
    }

    private static func stylesXML(options: DocumentExportOptions) -> String {
        let font = XMLEscaping.escape(options.fontFamily.officeFontName)
        let halfPoints = Int((options.fontSize * 2).rounded())
        let line = Int((240 * options.lineSpacing).rounded())
        let headingSizes = [2.0, 1.6, 1.3, 1.12, 1.0, 1.0]
        var headings = ""
        for (index, scale) in headingSizes.enumerated() {
            let level = index + 1
            headings += """
            <w:style w:type="paragraph" w:styleId="Heading\(level)"><w:name w:val="heading \(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="\(level == 1 ? 360 : 240)" w:after="120"/><w:outlineLvl w:val="\(index)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\(Int((Double(halfPoints) * scale).rounded()))"/></w:rPr></w:style>
            """
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="\(font)" w:hAnsi="\(font)" w:eastAsia="\(font)" w:cs="\(font)"/><w:sz w:val="\(halfPoints)"/><w:szCs w:val="\(halfPoints)"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="\(line)" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style><w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:rPr><w:sz w:val="\(halfPoints * 2)"/></w:rPr></w:style>\(headings)<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:ind w:left="720" w:right="720"/></w:pPr><w:rPr><w:i/><w:color w:val="404040"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F4F6F8"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New"/><w:sz w:val="\(max(14, halfPoints - 2))"/></w:rPr></w:style><w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0B5FA5"/><w:u w:val="single"/></w:rPr></w:style><w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders><w:tblCellMar><w:left w:w="108" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style></w:styles>
        """
    }

    private static func numberingXML(numbers: [Bool]) -> String {
        func abstract(id: Int, ordered: Bool) -> String {
            var levels = ""
            let bullets = ["•", "◦", "▪"]
            let formats = ["decimal", "lowerLetter", "lowerRoman"]
            for level in 0 ..< 9 {
                let indent = 720 * (level + 1)
                if ordered {
                    levels += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(formats[level % 3])\"/><w:lvlText w:val=\"%\(level + 1).\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                } else {
                    levels += "<w:lvl w:ilvl=\"\(level)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullets[level % 3])\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(indent)\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }
            }
            return "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>\(levels)</w:abstractNum>"
        }
        var nums = ""
        for (index, ordered) in numbers.enumerated() {
            nums += "<w:num w:numId=\"\(index + 1)\"><w:abstractNumId w:val=\"\(ordered ? 1 : 0)\"/>"
            if ordered { nums += "<w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride>" }
            nums += "</w:num>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\(abstract(id: 0, ordered: false))\(abstract(id: 1, ordered: true))\(nums)</w:numbering>
        """
    }

    private static let settingsXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:settings xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:defaultTabStop w:val="720"/><w:characterSpacingControl w:val="doNotCompress"/><w:compat><w:compatSetting w:name="compatibilityMode" w:uri="http://schemas.microsoft.com/office/word" w:val="15"/></w:compat></w:settings>
    """

    private static func contentTypes(imageExtensions: Set<String>, hasFooter: Bool) -> String {
        var defaults = "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/>"
        for ext in imageExtensions.sorted() {
            defaults += "<Default Extension=\"\(ext)\" ContentType=\"\(ImageBlock.mimeType(forExtension: ext))\"/>"
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\(defaults)<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/word/settings.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/>\(hasFooter ? "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>" : "")</Types>
        """
    }

    private static let rootRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
    """

    private static func documentRelationships(_ relationships: [Relationship]) -> String {
        let items = relationships.map { rel in
            let mode = rel.external ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(rel.id)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/\(rel.type)\" Target=\"\(XMLEscaping.escape(rel.target))\"\(mode)/>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\(items)</Relationships>
        """
    }

    static func coreProperties(_ metadata: DocumentMetadata, options: DocumentExportOptions) -> String {
        var fields = ""
        if let title = options.title ?? metadata.title { fields += "<dc:title>\(XMLEscaping.escape(title))</dc:title>" }
        if let author = options.author ?? metadata.author { fields += "<dc:creator>\(XMLEscaping.escape(author))</dc:creator>" }
        if let subject = metadata.subject { fields += "<dc:subject>\(XMLEscaping.escape(subject))</dc:subject>" }
        if !metadata.keywords.isEmpty { fields += "<cp:keywords>\(XMLEscaping.escape(metadata.keywords.joined(separator: ", ")))</cp:keywords>" }
        let now = ISO8601DateFormatter().string(from: Date())
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:dcmitype="http://purl.org/dc/dcmitype/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\(fields)<dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created><dcterms:modified xsi:type="dcterms:W3CDTF">\(now)</dcterms:modified></cp:coreProperties>
        """
    }

    private static let appProperties = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Application>MB Converter</Application></Properties>
    """
}
