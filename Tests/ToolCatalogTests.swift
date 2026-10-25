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

/// Input synthesis lives in the app (`SelfTestPlan`) so the in-app self-test uses the same files.
enum ToolInputFactory {
    static func make(_ format: FileFormat) async throws -> URL { try await SelfTestPlan.input(format) }
    static var preferredOrder: [FileFormat] { SelfTestPlan.preferredOrder }
}

/// Every tool's default run is covered by `SelfTestSuite` (the same checks as the in-app self-test).
@Suite(.serialized, .timeLimit(.minutes(3)))
struct ToolRunTests {
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
