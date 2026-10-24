import Foundation

/// Writes EPUB 3 with an EPUB 2 NCX for older readers. Chapters split at level-1 headings.
enum EPUBWriter {
    static func write(_ document: RichDocument, options: DocumentExportOptions = .default, to url: URL) throws {
        let title = options.title ?? document.resolvedTitle ?? "Untitled"
        let author = options.author ?? document.metadata.author
        let language = document.metadata.language ?? "en"
        let identifier = "urn:uuid:\(UUID().uuidString.lowercased())"
        let chapters = document.chapters()

        var images: [(path: String, mime: String, data: Data)] = []
        var imageNames: [Data: String] = [:]
        func imageSource(_ image: ImageBlock) -> String {
            if let existing = imageNames[image.data] { return existing }
            let name = "images/image\(images.count + 1).\(image.fileExtension)"
            images.append((name, image.mimeType, image.data))
            imageNames[image.data] = name
            return name
        }

        var chapterFiles: [(file: String, title: String)] = []
        let package = ZipPackageWriter()
        package.add("mimetype", string: "application/epub+zip", compressed: false)
        package.add("META-INF/container.xml", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """)

        let sourceChapters = chapters.isEmpty ? [[Block.paragraph(runs: [])]] : chapters
        for (index, blocks) in sourceChapters.enumerated() {
            let chapterTitle: String = {
                for block in blocks {
                    if case .heading(_, let runs) = block, let text = runs.plainText.nilIfBlank { return text }
                }
                return sourceChapters.count == 1 ? title : "Chapter \(index + 1)"
            }()
            let file = "chapter\(index + 1).xhtml"
            var chapterMetadata = document.metadata
            chapterMetadata.language = language
            let html = HTMLWriter.render(blocks: blocks, title: chapterTitle, metadata: chapterMetadata, options: options, mode: .epubChapter, imageSource: imageSource)
            package.add("OEBPS/\(file)", string: html)
            chapterFiles.append((file, chapterTitle))
        }

        package.add("OEBPS/style.css", string: HTMLWriter.stylesheet(options: options, mode: .epubChapter))
        package.add("OEBPS/nav.xhtml", string: navigation(title: title, chapters: chapterFiles, language: language))
        package.add("OEBPS/toc.ncx", string: ncx(title: title, identifier: identifier, chapters: chapterFiles))
        for image in images {
            package.add("OEBPS/\(image.path)", data: image.data, compressed: false)
        }

        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/><item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/><item id=\"css\" href=\"style.css\" media-type=\"text/css\"/>"
        var spine = ""
        for (index, chapter) in chapterFiles.enumerated() {
            manifest += "<item id=\"c\(index + 1)\" href=\"\(chapter.file)\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"c\(index + 1)\"/>"
        }
        for (index, image) in images.enumerated() {
            manifest += "<item id=\"img\(index + 1)\" href=\"\(image.path)\" media-type=\"\(image.mime)\"/>"
        }
        var meta = "<dc:identifier id=\"bookid\">\(identifier)</dc:identifier><dc:title>\(XMLEscaping.escape(title))</dc:title><dc:language>\(XMLEscaping.escape(language))</dc:language>"
        if let author { meta += "<dc:creator>\(XMLEscaping.escape(author))</dc:creator>" }
        if let subject = document.metadata.subject { meta += "<dc:description>\(XMLEscaping.escape(subject))</dc:description>" }
        let modified = ISO8601DateFormatter().string(from: Date())
        meta += "<meta property=\"dcterms:modified\">\(modified)</meta>"
        package.add("OEBPS/content.opf", string: """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">\(meta)</metadata><manifest>\(manifest)</manifest><spine toc="ncx">\(spine)</spine></package>
        """)
        try package.write(to: url)
    }

    private static func navigation(title: String, chapters: [(file: String, title: String)], language: String) -> String {
        let items = chapters.map { "<li><a href=\"\($0.file)\">\(XMLEscaping.escape($0.title))</a></li>" }.joined()
        return """
        <?xml version="1.0" encoding="utf-8"?>
        <!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops" lang="\(language)" xml:lang="\(language)"><head><title>\(XMLEscaping.escape(title))</title></head><body><nav epub:type="toc" id="toc"><h1>Contents</h1><ol>\(items)</ol></nav></body></html>
        """
    }

    private static func ncx(title: String, identifier: String, chapters: [(file: String, title: String)]) -> String {
        let points = chapters.enumerated().map { index, chapter in
            "<navPoint id=\"np\(index + 1)\" playOrder=\"\(index + 1)\"><navLabel><text>\(XMLEscaping.escape(chapter.title))</text></navLabel><content src=\"\(chapter.file)\"/></navPoint>"
        }.joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="\(identifier)"/><meta name="dtb:depth" content="1"/></head><docTitle><text>\(XMLEscaping.escape(title))</text></docTitle><navMap>\(points)</navMap></ncx>
        """
    }
}
