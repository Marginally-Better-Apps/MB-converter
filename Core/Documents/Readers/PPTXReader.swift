import CoreGraphics
import Foundation

/// Extracts slide titles, text, tables and pictures from PowerPoint (.pptx) decks.
enum PPTXReader {
    static func read(url: URL) throws -> RichDocument {
        let package = try ZipPackageReader(url: url)
        let presentation = try package.xml(at: "ppt/presentation.xml")
        var rels: [String: String] = [:]
        for rel in package.xmlIfPresent(at: "ppt/_rels/presentation.xml.rels")?.children("Relationship") ?? [] {
            if let id = rel.attribute("Id"), let target = rel.attribute("Target") { rels[id] = target }
        }
        let slidePaths = (presentation.child("sldIdLst")?.children("sldId") ?? []).compactMap { slide -> String? in
            guard let id = slide.attribute("r:id"), let target = rels[id] else { return nil }
            return ZipPackageReader.resolve(target, against: "ppt/presentation.xml")
        }
        guard !slidePaths.isEmpty else { throw DocumentError.empty("The presentation has no slides.") }

        var blocks: [Block] = []
        for (index, path) in slidePaths.enumerated() {
            let slideBlocks = try slide(at: path, number: index + 1, package: package)
            if !blocks.isEmpty { blocks.append(.pageBreak) }
            blocks.append(contentsOf: slideBlocks)
        }
        var document = RichDocument(blocks: blocks)
        document.metadata = DOCXReader.coreMetadata(package)
        return document
    }

    static func slideCount(url: URL) -> Int {
        guard let package = try? ZipPackageReader(url: url),
              let presentation = package.xmlIfPresent(at: "ppt/presentation.xml")
        else { return 0 }
        return presentation.child("sldIdLst")?.children("sldId").count ?? 0
    }

    private static func slide(at path: String, number: Int, package: ZipPackageReader) throws -> [Block] {
        let slide = try package.xml(at: path)
        var rels: [String: String] = [:]
        let relsPath = ZipPackageReader.resolve("_rels/" + ((path as NSString).lastPathComponent) + ".rels", against: path)
        for rel in package.xmlIfPresent(at: relsPath)?.children("Relationship") ?? [] {
            if let id = rel.attribute("Id"), let target = rel.attribute("Target") { rels[id] = target }
        }
        guard let tree = slide.firstDescendant("spTree") else { return [] }
        var title: [Run]?
        var body: [FlatBlock] = []
        visit(tree)

        func visit(_ container: XElement) {
            for shape in container.elements {
                switch shape.localName {
                case "sp":
                    let placeholder = shape.firstDescendant("ph")?.attribute("type")
                    guard let txBody = shape.child("txBody") else { continue }
                    if placeholder == "title" || placeholder == "ctrTitle", title == nil {
                        title = txBody.children("p").map(runs).filter { !$0.isEmpty }.reduce(into: [Run]()) { result, next in
                            if !result.isEmpty { result.append(Run(" ")) }
                            result.append(contentsOf: next)
                        }
                        continue
                    }
                    if ["sldNum", "dt", "ftr"].contains(placeholder ?? "") { continue }
                    let isBody = placeholder == "body" || placeholder == nil && shape.firstDescendant("ph") != nil
                    for paragraph in txBody.children("p") {
                        let paragraphRuns = runs(paragraph)
                        guard !paragraphRuns.plainText.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                        let props = paragraph.child("pPr")
                        let level = Int(props?.attribute("lvl") ?? "0") ?? 0
                        let explicitNone = props?.child("buNone") != nil
                        let numbered = props?.child("buAutoNum") != nil
                        let bulleted = props?.child("buChar") != nil || (isBody && !explicitNone)
                        if numbered || bulleted {
                            body.append(.listItem(level: level, ordered: numbered, content: [.paragraph(runs: paragraphRuns)]))
                        } else {
                            body.append(.block(.paragraph(runs: paragraphRuns)))
                        }
                    }
                case "grpSp":
                    visit(shape)
                case "graphicFrame":
                    if let table = shape.firstDescendant("tbl") {
                        let rows = table.children("tr").map { tr in
                            tr.children("tc").map { tc -> [Block] in
                                let text = (tc.child("txBody")?.children("p") ?? []).map(runs).filter { !$0.isEmpty }
                                return text.map { Block.paragraph(runs: $0) }
                            }
                        }
                        if !rows.isEmpty { body.append(.block(.table(TableBlock(rows: rows, hasHeaderRow: true)))) }
                    }
                case "pic":
                    guard let embed = shape.firstDescendant("blip")?.attribute("r:embed"),
                          let target = rels[embed] else { continue }
                    let mediaPath = ZipPackageReader.resolve(target, against: path)
                    guard let data = package.dataIfPresent(at: mediaPath) else { continue }
                    let mime = ImageBlock.sniffMimeType(data) ?? ImageBlock.mimeType(forExtension: (mediaPath as NSString).pathExtension)
                    guard mime.hasPrefix("image/"), !mime.contains("emf"), !mime.contains("wmf") else { continue }
                    var size: CGSize?
                    if let ext = shape.firstDescendant("ext"), let cx = Double(ext.attribute("cx") ?? ""), let cy = Double(ext.attribute("cy") ?? "") {
                        size = CGSize(width: cx / 12700, height: cy / 12700)
                    }
                    body.append(.block(.image(ImageBlock(data: data, mimeType: mime, size: size, altText: shape.firstDescendant("cNvPr")?.attribute("descr")))))
                default:
                    continue
                }
            }
        }

        var blocks: [Block] = []
        let heading = title?.trimmed() ?? []
        blocks.append(.heading(level: 2, runs: heading.isEmpty ? [Run("Slide \(number)")] : heading))
        blocks.append(contentsOf: ListAssembler.assemble(body))
        return blocks
    }

    private static func runs(_ paragraph: XElement) -> [Run] {
        var result: [Run] = []
        for element in paragraph.elements {
            switch element.localName {
            case "r", "fld":
                var style = RunStyle()
                if let props = element.child("rPr") {
                    style.bold = props.attribute("b") == "1" || props.attribute("b") == "true"
                    style.italic = props.attribute("i") == "1" || props.attribute("i") == "true"
                    style.underline = (props.attribute("u") ?? "none") != "none"
                    style.strikethrough = (props.attribute("strike") ?? "noStrike") != "noStrike"
                    if let baseline = Int(props.attribute("baseline") ?? "0") {
                        style.superscript = baseline > 0
                        style.subscript = baseline < 0
                    }
                }
                result.append(Run(element.child("t")?.text ?? "", style))
            case "br":
                result.append(Run("\n"))
            default:
                continue
            }
        }
        return result.coalesced()
    }
}
