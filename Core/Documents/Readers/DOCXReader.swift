import CoreGraphics
import Foundation

/// Reads Office Open XML word-processing documents (.docx) into a `RichDocument`.
struct DOCXReader {
    static func read(url: URL) throws -> RichDocument {
        var reader = DOCXReader(package: try ZipPackageReader(url: url))
        return try reader.read()
    }

    private let package: ZipPackageReader
    private var relationships: [String: (target: String, external: Bool)] = [:]
    private var styles: [String: StyleInfo] = [:]
    private var numberingFormats: [String: [Int: Bool]] = [:] // numId -> level -> ordered
    private var mainPart = "word/document.xml"

    private struct StyleInfo {
        var headingLevel: Int?
        var bold = false
        var italic = false
        var isCode = false
        var isQuote = false
        var basedOn: String?
        var numID: String?
        var numLevel: Int?
    }

    init(package: ZipPackageReader) {
        self.package = package
    }

    private mutating func loadSupportingParts() {
        if let rootRels = package.xmlIfPresent(at: "_rels/.rels") {
            for rel in rootRels.children("Relationship") where rel.attribute("Type")?.hasSuffix("/officeDocument") == true {
                if let target = rel.attribute("Target") {
                    mainPart = ZipPackageReader.normalized(target)
                }
            }
        }
        let relsPath = ZipPackageReader.resolve("_rels/" + (mainPart.split(separator: "/").last.map(String.init) ?? "document.xml") + ".rels", against: mainPart)
        if let rels = package.xmlIfPresent(at: relsPath) {
            for rel in rels.children("Relationship") {
                guard let id = rel.attribute("Id"), let target = rel.attribute("Target") else { continue }
                relationships[id] = (target, rel.attribute("TargetMode") == "External")
            }
        }
        if let stylesXML = package.xmlIfPresent(at: ZipPackageReader.resolve("styles.xml", against: mainPart)) {
            for style in stylesXML.children("style") {
                guard let id = style.attribute("w:styleId") else { continue }
                var info = StyleInfo()
                let name = (style.child("name")?.attribute("w:val") ?? id).lowercased()
                if name == "title" {
                    info.headingLevel = 1
                } else if name.hasPrefix("heading "), let level = Int(name.dropFirst(8)) {
                    info.headingLevel = level
                } else if let outline = style.child("pPr")?.child("outlineLvl")?.attribute("w:val"), let level = Int(outline), level < 9 {
                    info.headingLevel = level + 1
                }
                info.isCode = name.contains("code") || name.contains("preformatted") || name.contains("source")
                info.isQuote = name.contains("quote")
                if let rPr = style.child("rPr") {
                    info.bold = Self.flag(rPr.child("b"))
                    info.italic = Self.flag(rPr.child("i"))
                }
                info.basedOn = style.child("basedOn")?.attribute("w:val")
                if let numPr = style.child("pPr")?.child("numPr") {
                    info.numID = numPr.child("numId")?.attribute("w:val")
                    info.numLevel = numPr.child("ilvl")?.attribute("w:val").flatMap(Int.init)
                }
                styles[id] = info
            }
        }
        if let numbering = package.xmlIfPresent(at: ZipPackageReader.resolve("numbering.xml", against: mainPart)) {
            var abstractFormats: [String: [Int: Bool]] = [:]
            for abstract in numbering.children("abstractNum") {
                guard let id = abstract.attribute("w:abstractNumId") else { continue }
                var levels: [Int: Bool] = [:]
                for lvl in abstract.children("lvl") {
                    let level = Int(lvl.attribute("w:ilvl") ?? "0") ?? 0
                    let format = lvl.child("numFmt")?.attribute("w:val") ?? "bullet"
                    levels[level] = format != "bullet" && format != "none"
                }
                abstractFormats[id] = levels
            }
            for num in numbering.children("num") {
                guard let id = num.attribute("w:numId"),
                      let abstractID = num.child("abstractNumId")?.attribute("w:val") else { continue }
                numberingFormats[id] = abstractFormats[abstractID] ?? [:]
            }
        }
    }

    mutating func read() throws -> RichDocument {
        loadSupportingParts()
        let root = try package.xml(at: mainPart)
        guard let body = root.firstDescendant("body") else {
            throw DocumentError.unreadable("The Word document has no body.")
        }
        var document = RichDocument()
        document.blocks = blocks(in: body)
        document.metadata = Self.coreMetadata(package)
        return document
    }

    static func coreMetadata(_ package: ZipPackageReader) -> DocumentMetadata {
        var metadata = DocumentMetadata()
        guard let core = package.xmlIfPresent(at: "docProps/core.xml") else { return metadata }
        metadata.title = core.child("title")?.text.nilIfBlank
        metadata.author = core.child("creator")?.text.nilIfBlank
        metadata.subject = core.child("subject")?.text.nilIfBlank
        metadata.keywords = (core.child("keywords")?.text ?? "")
            .split(whereSeparator: { $0 == "," || $0 == ";" })
            .compactMap { String($0).nilIfBlank }
        return metadata
    }

    // MARK: - Body

    private func blocks(in container: XElement) -> [Block] {
        var flat: [FlatBlock] = []
        appendBlocks(in: container, to: &flat)
        return ListAssembler.assemble(flat)
    }

    private func appendBlocks(in container: XElement, to flat: inout [FlatBlock]) {
        for element in container.elements {
            switch element.localName {
            case "p":
                flat.append(contentsOf: paragraph(element))
            case "tbl":
                flat.append(.block(.table(table(element))))
            case "sdt":
                if let content = element.child("sdtContent") { appendBlocks(in: content, to: &flat) }
            case "customXml", "ins", "smartTag":
                appendBlocks(in: element, to: &flat)
            default:
                continue
            }
        }
    }

    private func paragraph(_ p: XElement) -> [FlatBlock] {
        let pPr = p.child("pPr")
        let styleID = pPr?.child("pStyle")?.attribute("w:val")
        let style = styleID.flatMap { resolvedStyle($0) }
        var inherited = RunStyle()
        inherited.bold = style?.bold ?? false
        inherited.italic = style?.italic ?? false
        inherited.code = style?.isCode ?? false

        var runs: [Run] = []
        var trailing: [FlatBlock] = []
        var pageBreak = false
        collectRuns(in: p, inherited: inherited, link: nil, runs: &runs, images: &trailing, pageBreak: &pageBreak)

        var result: [FlatBlock] = []
        let cleaned = runs.coalesced()
        let alignment: TextAlignment = switch pPr?.child("jc")?.attribute("w:val") {
        case "center": .center
        case "right", "end": .right
        case "both", "distribute": .justified
        default: .natural
        }

        if let outline = pPr?.child("outlineLvl")?.attribute("w:val"), let level = Int(outline), level < 6, !cleaned.isEmpty {
            result.append(.block(.heading(level: level + 1, runs: cleaned.trimmed())))
        } else if let level = style?.headingLevel, !cleaned.isEmpty {
            result.append(.block(.heading(level: min(level, 6), runs: cleaned.trimmed().map(Self.strippingHeadingBold))))
        } else if let numID = pPr?.child("numPr")?.child("numId")?.attribute("w:val") ?? style?.numID, numID != "0" {
            let level = pPr?.child("numPr")?.child("ilvl")?.attribute("w:val").flatMap(Int.init) ?? style?.numLevel ?? 0
            let ordered = numberingFormats[numID]?[level] ?? false
            result.append(.listItem(level: level, ordered: ordered, content: cleaned.isEmpty ? [] : [.paragraph(runs: cleaned)]))
        } else if style?.isCode == true {
            result.append(.block(.code(cleaned.plainText)))
        } else if style?.isQuote == true, !cleaned.isEmpty {
            result.append(.block(.quote([.paragraph(runs: cleaned)])))
        } else if !cleaned.plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(.block(.paragraph(runs: cleaned, alignment: alignment)))
        }
        if pageBreak { result.append(.block(.pageBreak)) }
        result.append(contentsOf: trailing)
        return result
    }

    private static func strippingHeadingBold(_ run: Run) -> Run {
        var copy = run
        copy.style.bold = false
        return copy
    }

    private func resolvedStyle(_ id: String, depth: Int = 0) -> StyleInfo? {
        guard var info = styles[id] else { return nil }
        if depth < 8, let parentID = info.basedOn, let parent = resolvedStyle(parentID, depth: depth + 1) {
            info.headingLevel = info.headingLevel ?? parent.headingLevel
            info.bold = info.bold || parent.bold
            info.italic = info.italic || parent.italic
            info.isCode = info.isCode || parent.isCode
            info.isQuote = info.isQuote || parent.isQuote
            info.numID = info.numID ?? parent.numID
            info.numLevel = info.numLevel ?? parent.numLevel
        }
        return info
    }

    private func collectRuns(
        in element: XElement,
        inherited: RunStyle,
        link: String?,
        runs: inout [Run],
        images: inout [FlatBlock],
        pageBreak: inout Bool
    ) {
        for child in element.elements {
            switch child.localName {
            case "r":
                var style = runStyle(child.child("rPr"), base: inherited)
                style.link = link ?? style.link
                for part in child.elements {
                    switch part.localName {
                    case "t":
                        runs.append(Run(part.text, style))
                    case "tab", "ptab":
                        runs.append(Run("\t", style))
                    case "br", "cr":
                        if part.attribute("w:type") == "page" {
                            pageBreak = true
                        } else {
                            runs.append(Run("\n", style))
                        }
                    case "noBreakHyphen":
                        runs.append(Run("-", style))
                    case "sym":
                        runs.append(Run("•", style))
                    case "drawing", "pict", "object":
                        if let image = image(in: part) { images.append(.block(.image(image))) }
                    case "AlternateContent":
                        if let fallback = part.child("Choice") ?? part.child("Fallback"),
                           let image = image(in: fallback) {
                            images.append(.block(.image(image)))
                        }
                    default:
                        continue
                    }
                }
            case "hyperlink":
                var target = link
                if let id = child.attribute("r:id"), let rel = relationships[id] {
                    target = rel.target
                } else if let anchor = child.attribute("w:anchor") {
                    target = "#" + anchor
                }
                collectRuns(in: child, inherited: inherited, link: target, runs: &runs, images: &images, pageBreak: &pageBreak)
            case "ins", "smartTag", "fldSimple", "customXml", "bdo", "dir":
                collectRuns(in: child, inherited: inherited, link: link, runs: &runs, images: &images, pageBreak: &pageBreak)
            case "sdt":
                if let content = child.child("sdtContent") {
                    collectRuns(in: content, inherited: inherited, link: link, runs: &runs, images: &images, pageBreak: &pageBreak)
                }
            default:
                continue
            }
        }
    }

    private func runStyle(_ rPr: XElement?, base: RunStyle) -> RunStyle {
        var style = base
        guard let rPr else { return style }
        if let styleID = rPr.child("rStyle")?.attribute("w:val"), let info = resolvedStyle(styleID) {
            style.bold = style.bold || info.bold
            style.italic = style.italic || info.italic
            style.code = style.code || info.isCode
        }
        if let b = rPr.child("b") { style.bold = Self.flag(b) }
        if let i = rPr.child("i") { style.italic = Self.flag(i) }
        if let u = rPr.child("u") { style.underline = (u.attribute("w:val") ?? "single") != "none" }
        if let s = rPr.child("strike") ?? rPr.child("dstrike") { style.strikethrough = Self.flag(s) }
        switch rPr.child("vertAlign")?.attribute("w:val") {
        case "superscript": style.superscript = true
        case "subscript": style.subscript = true
        default: break
        }
        if let fonts = rPr.child("rFonts")?.attribute("w:ascii")?.lowercased(),
           fonts.contains("courier") || fonts.contains("consolas") || fonts.contains("mono") {
            style.code = true
        }
        return style
    }

    private static func flag(_ element: XElement?) -> Bool {
        guard let element else { return false }
        guard let value = element.attribute("w:val")?.lowercased() else { return true }
        return !["0", "false", "off", "none"].contains(value)
    }

    private func image(in element: XElement) -> ImageBlock? {
        let blip = element.firstDescendant("blip")
        let imageData = element.firstDescendant("imagedata")
        guard let id = blip?.attribute("r:embed") ?? imageData?.attribute("r:id"),
              let rel = relationships[id], !rel.external else { return nil }
        let path = ZipPackageReader.resolve(rel.target, against: mainPart)
        guard let data = package.dataIfPresent(at: path) else { return nil }
        let ext = (path as NSString).pathExtension
        let mime = ImageBlock.sniffMimeType(data) ?? ImageBlock.mimeType(forExtension: ext)
        guard mime.hasPrefix("image/"), !mime.contains("x-emf"), !mime.contains("x-wmf") else { return nil }
        var size: CGSize?
        if let extent = element.firstDescendant("extent"),
           let cx = Double(extent.attribute("cx") ?? ""), let cy = Double(extent.attribute("cy") ?? ""),
           cx > 0, cy > 0 {
            size = CGSize(width: cx / 12700, height: cy / 12700)
        }
        let alt = element.firstDescendant("docPr")?.attribute("descr")?.nilIfBlank
        return ImageBlock(data: data, mimeType: mime, size: size, altText: alt)
    }

    private func table(_ tbl: XElement) -> TableBlock {
        var rows: [[[Block]]] = []
        var headerFlag = false
        for (index, tr) in tbl.children("tr").enumerated() {
            if index == 0, tr.child("trPr")?.child("tblHeader") != nil { headerFlag = true }
            var row: [[Block]] = []
            for tc in tr.children("tc") {
                let cellBlocks = blocks(in: tc).filter { block in
                    if case .paragraph(let runs, _) = block { return !runs.isEmpty }
                    return true
                }
                row.append(cellBlocks)
                // Horizontally merged cells keep the grid aligned.
                if let span = Int(tc.child("tcPr")?.child("gridSpan")?.attribute("w:val") ?? ""), span > 1 {
                    row.append(contentsOf: Array(repeating: [], count: span - 1))
                }
            }
            rows.append(row)
        }
        if !headerFlag, let first = rows.first, !first.isEmpty {
            headerFlag = first.allSatisfy { cell in
                cell.allSatisfy { block in
                    if case .paragraph(let runs, _) = block { return runs.allSatisfy { $0.style.bold || $0.text.trimmingCharacters(in: .whitespaces).isEmpty } }
                    return false
                }
            } && first.contains { !$0.isEmpty }
        }
        return TableBlock(rows: rows, hasHeaderRow: headerFlag)
    }
}
