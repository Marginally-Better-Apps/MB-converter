import Foundation

enum EPUBReader {
    static func read(url: URL) throws -> RichDocument {
        let package = try ZipPackageReader(url: url)
        guard let container = package.xmlIfPresent(at: "META-INF/container.xml"),
              let opfPath = container.firstDescendant("rootfile")?.attribute("full-path")
        else {
            throw DocumentError.unreadable("The EPUB is missing its container manifest.")
        }
        let opf = try package.xml(at: opfPath)
        var metadata = DocumentMetadata()
        if let meta = opf.child("metadata") {
            metadata.title = meta.child("title")?.text.nilIfBlank
            metadata.author = meta.child("creator")?.text.nilIfBlank
            metadata.subject = (meta.child("description") ?? meta.child("subject"))?.text.collapsingWhitespace.nilIfBlank
            metadata.language = meta.child("language")?.text.nilIfBlank
        }
        var manifest: [String: (href: String, type: String)] = [:]
        for item in opf.child("manifest")?.children("item") ?? [] {
            guard let id = item.attribute("id"), let href = item.attribute("href") else { continue }
            manifest[id] = (href, item.attribute("media-type") ?? "")
        }
        var blocks: [Block] = []
        for itemref in opf.child("spine")?.children("itemref") ?? [] {
            guard itemref.attribute("linear") != "no",
                  let idref = itemref.attribute("idref"),
                  let item = manifest[idref],
                  item.type.contains("html")
            else { continue }
            let chapterPath = ZipPackageReader.resolve(item.href, against: opfPath)
            guard let data = package.dataIfPresent(at: chapterPath) else { continue }
            let chapter = HTMLReader.read(html: TextDecoding.decode(data)) { src in
                guard !src.contains("://") else { return nil }
                let path = ZipPackageReader.resolve(src.split(separator: "#").first.map(String.init) ?? src, against: chapterPath)
                return package.dataIfPresent(at: path)
            }
            guard !chapter.blocks.isEmpty else { continue }
            if !blocks.isEmpty { blocks.append(.pageBreak) }
            blocks.append(contentsOf: chapter.blocks)
        }
        guard !blocks.isEmpty else { throw DocumentError.empty("The EPUB has no readable chapters.") }
        return RichDocument(metadata: metadata, blocks: blocks)
    }
}
