import Foundation
import PDFKit
import Testing
@testable import Converter

struct ToolCatalogStructureTests {
    @Test func identifiersAreUniqueAndResolvable() {
        let ids = ToolCatalog.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        for id in ToolCatalog.featuredOrder { #expect(ToolCatalog.tool(id) != nil, "Missing featured tool \(id)") }
        #expect(ToolCatalog.all.count >= 80)
    }

    @Test func everyCategoryHasTools() {
        for category in ToolCategory.allCases {
            #expect(!ToolCatalog.tools(in: category).isEmpty, "\(category) is empty")
        }
    }

    @Test(arguments: ToolCatalog.all.map(\.id.rawValue))
    func toolIsWellFormed(id: String) throws {
        let tool = try #require(ToolCatalog.tool(ToolID(rawValue: id)))
        #expect(!tool.title.isEmpty && !tool.summary.isEmpty && !tool.symbol.isEmpty)
        #expect(tool.title.count <= 28, "Title too long for a tile: \(tool.title)")
        let keys = tool.options.map(\.key)
        #expect(Set(keys).count == keys.count, "Duplicate option keys in \(id)")
        for option in tool.options {
            if case .choice(let choices, _) = option.kind {
                #expect(choices.contains { .string($0.value) == option.defaultValue }, "\(id).\(option.key) default isn't a choice")
            }
            if case .slider(let range, _, _) = option.kind, case .number(let value) = option.defaultValue {
                #expect(range.contains(value), "\(id).\(option.key) default out of range")
            }
        }
        if tool.input.acceptsFiles { #expect(!tool.input.formats.isEmpty) }
    }

    @Test func searchRanksTitleMatchesFirst() {
        #expect(ToolCatalog.search("pdf to word").first?.id == "convert.pdf.docx")
        #expect(ToolCatalog.search("compress").prefix(3).contains { $0.id == "pdf.compress" })
        #expect(ToolCatalog.search("heic to jpg").first?.id == "image.convert")
        #expect(ToolCatalog.search("zzzz-nothing").isEmpty)
    }

    @Test func suggestsToolsForFiles() {
        let pdfTools = ToolCatalog.tools(accepting: .pdf)
        #expect(pdfTools.first?.category == .pdf)
        #expect(pdfTools.contains { $0.id == "pdf.merge" })
        #expect(ToolCatalog.conversionTool(from: .docx, to: .pdf)?.id == "convert.docx.pdf")
        #expect(ToolCatalog.conversionTool(from: .ods, to: .pdf)?.id == "convert.xlsx.pdf")
    }

    @Test func conversionTargetsAreAllReachable() {
        for source in FileFormat.documentReadable + FileFormat.spreadsheetReadable {
            #expect(!ConversionEngine.targets(for: source).isEmpty)
            #expect(!ConversionEngine.targets(for: source).contains(source))
        }
    }

    @Test func storageNamesAreSafeAndUnique() throws {
        #expect(ToolStorage.sanitize("a/b:c?") == "a-b-c-")
        #expect(ToolStorage.sanitize(".hidden") == "file.hidden")
        let directory = ToolStorage.newRunDirectory()
        let first = ToolStorage.uniqueURL(in: directory, baseName: "x", ext: "pdf")
        try Data().write(to: first)
        #expect(ToolStorage.uniqueURL(in: directory, baseName: "x", ext: "pdf").lastPathComponent == "x 2.pdf")
    }

    @Test func optionValuesCoerceTypes() {
        var values = ToolOptionValues(["a": .string("12"), "b": .number(3.6), "c": .bool(true)])
        #expect(values.double("a") == 12)
        #expect(values.int("b") == 4)
        #expect(values.string("b") == "3.6")
        #expect(values.bool("c"))
        values["d"] = .number(Double(0xFF00FF))
        #expect(values.hex("d") == 0xFF00FF)
    }
}

/// Builds a real input file for any format a tool might need.
enum ToolInputFactory {
    static func make(_ format: FileFormat) async throws -> URL {
        switch format {
        case .pdf:
            let url = TestSupport.tempURL("pdf")
            try PDFToolkit.write(TestSupport.makePDF(pages: 3, body: "Quarterly numbers for Page review. Account 555-0100."), to: url)
            return url
        case .docx, .odt, .rtf, .pptx, .xlsx, .ods:
            let source = try TestSupport.fixture("sample.\(format.fileExtension)")
            let url = TestSupport.tempURL(format.fileExtension)
            try FileManager.default.copyItem(at: source, to: url)
            return url
        case .markdown: return try write("# Notes\n\nSome **bold** text.\n\n- one\n- two\n", "md")
        case .txt: return try write("Plain text file.\n\nSecond paragraph.", "txt")
        case .html: return try write("<h1>Title</h1><p>Hello <b>web</b>.</p><table><tr><th>A</th></tr><tr><td>1</td></tr></table>", "html")
        case .csv: return try write("name,qty\nBolts,42\nNuts,7\n", "csv")
        case .tsv: return try write("name\tqty\nBolts\t42\n", "tsv")
        case .json: return try write(#"[{"name":"Bolts","qty":42},{"name":"Nuts","qty":7}]"#, "json")
        case .xml: return try write("<items><item><name>Bolts</name><qty>42</qty></item><item><name>Nuts</name><qty>7</qty></item></items>", "xml")
        case .svg: return try write(##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#0b5fa5"/><circle cx="60" cy="40" r="20" fill="white"/></svg>"##, "svg")
        case .epub:
            let url = TestSupport.tempURL("epub")
            try EPUBWriter.write(TestSupport.sampleDocument, to: url)
            return url
        case .png, .jpeg, .heic, .webp, .tiff, .bmp:
            let format = ImageToolkit.OutputFormat(fileFormat: format) ?? .png
            return try TestSupport.writeImage(TestSupport.makeImage(width: 320, height: 240), format: format)
        case .gif:
            let url = TestSupport.tempURL("gif")
            try ImageToolkit.animatedGIF([TestSupport.makeImage(width: 64, height: 64)], frameDelay: 0.1).write(to: url)
            return url
        case .mp4, .mov, .m4v, .mkv, .webm, .avi:
            return try await MediaFixtures.video(seconds: 1.5)
        case .mp3, .m4a, .wav, .aac, .flac, .ogg, .opus:
            return try await MediaFixtures.audio(seconds: 1.5)
        case .zip:
            return try ToolStorage.zip([try write("a", "txt"), try write("b", "txt")], named: "bundle", in: ToolStorage.newRunDirectory())
        }
    }

    private static func write(_ text: String, _ ext: String) throws -> URL {
        let url = TestSupport.tempURL(ext)
        try Data(text.utf8).write(to: url)
        return url
    }

    static let preferredOrder: [FileFormat] = [.pdf, .docx, .xlsx, .csv, .png, .jpeg, .mp4, .m4a, .markdown, .json, .xml, .pptx, .odt, .ods, .rtf, .html, .txt, .epub, .svg, .zip]
}

@Suite(.serialized)
struct ToolRunTests {
    /// Tools needing the network or a picker-only handoff are covered elsewhere.
    static let skipped: Set<String> = ["util.webpdf", "util.webimage"]

    /// Option overrides for tools whose defaults intentionally require user input.
    static let overrides: [String: [String: OptionValue]] = [
        "pdf.delete": ["pages": .string("2")],
        "pdf.extract": ["pages": .string("3,1")],
        "pdf.protect": ["password": .string("pw"), "confirm": .string("pw")],
        "pdf.redact": ["terms": .string("555-0100")],
        "image.text": ["text": .string("© Test")],
        "image.meme": ["top": .string("hello")],
        "util.qr": ["text": .string("https://example.com")],
        "util.write": ["body": .string("# Hello\n\nWorld")],
        "audio.adjust": ["volume": .number(-3)],
        "pdf.split": ["ranges": .string("1, 2-3")]
    ]

    /// Tools that may legitimately refuse the synthetic input.
    static let acceptableFailures: [String: String] = [
        "image.blurfaces": "no faces in a synthetic image",
        "image.removebg": "subject lifting can be unavailable on simulators",
        "pdf.removeblank": "the sample has no blank pages",
        "pdf.extractimages": "the sample PDF has no images",
        "image.ocr": "the synthetic image has no text (covered by ImageToolTests)"
    ]

    static var runnableIDs: [String] {
        ToolCatalog.all.filter { !$0.opensMediaConverter && !skipped.contains($0.id.rawValue) }.map(\.id.rawValue)
    }

    @MainActor
    @Test(arguments: runnableIDs)
    func runsWithDefaults(id: String) async throws {
        let tool = try #require(ToolCatalog.tool(ToolID(rawValue: id)))
        var inputs: [ToolInputFile] = []
        if tool.id == "video.addaudio" {
            inputs = [try ToolInputFile(url: try await ToolInputFactory.make(.mp4)), try ToolInputFile(url: try await ToolInputFactory.make(.m4a))]
        } else if tool.input.acceptsFiles {
            let format = try #require(ToolInputFactory.preferredOrder.first(where: tool.input.accepts) ?? tool.input.formats.first)
            for _ in 0 ..< max(tool.input.minCount, 1) {
                inputs.append(try ToolInputFile(url: try await ToolInputFactory.make(format)))
            }
        }
        var options = ToolOptionValues(defaults: tool.options)
        for option in tool.options {
            if case .dynamicChoice(let provider) = option.kind { options[option.key] = .string(provider(inputs).first?.value ?? "") }
        }
        for (key, value) in Self.overrides[id] ?? [:] { options[key] = value }
        let editor: ToolEditorState = switch tool.editor {
        case .pdfMarkup: .overlays([PDFOverlayItem(pageIndex: 0, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05), kind: .text("Approved", fontSize: 14, colorHex: 0, bold: true))])
        case .imageCrop: .crop(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        case .mediaRange: .range(start: 0.2, end: 1.0)
        default: .none
        }
        let context = ToolContext(inputs: inputs, options: options, editor: editor)
        do {
            let output = try await tool.run(context)
            #expect(!output.files.isEmpty, "\(id) produced no files")
            for file in output.files {
                #expect(file.byteCount > 0, "\(id) wrote an empty \(file.name)")
                if file.format == .pdf {
                    #expect(PDFDocument(url: file.url) != nil || id == "pdf.protect", "\(id) wrote an unreadable PDF")
                }
            }
        } catch {
            if Self.acceptableFailures[id] != nil { return }
            Issue.record("\(id) failed: \(error.localizedDescription)")
        }
    }

    @MainActor
    @Test func unlockRoundTrip() async throws {
        let locked = TestSupport.tempURL("pdf")
        try PDFToolkit.protect(TestSupport.makePDF(pages: 1), userPassword: "pw", ownerPassword: nil, to: locked)
        let tool = try #require(ToolCatalog.tool("pdf.unlock"))
        var options = ToolOptionValues(defaults: tool.options)
        options["password"] = .string("pw")
        let output = try await tool.run(ToolContext(inputs: [try ToolInputFile(url: locked)], options: options))
        #expect(PDFDocument(url: output.files[0].url)?.isEncrypted == false)
    }

    @MainActor
    @Test func universalConverterOffersSharedTargets() throws {
        let tool = try #require(ToolCatalog.tool("convert.any"))
        guard case .dynamicChoice(let provider) = tool.options[0].kind else { Issue.record("expected dynamic choice"); return }
        let docx = try ToolInputFile(url: URL(fileURLWithPath: "/tmp/a.docx"))
        let md = try ToolInputFile(url: URL(fileURLWithPath: "/tmp/b.md"))
        let targets = provider([docx, md]).map(\.value)
        #expect(targets.contains("pdf") && !targets.contains("docx") && !targets.contains("markdown"))
    }
}
