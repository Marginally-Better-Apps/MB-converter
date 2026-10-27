import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import Converter

/// The simpler tool flow: tools say what's missing before you tap, settings nobody needs are folded
/// away, picking the file runs single-decision tools, and editors are part of the tool screen.
@MainActor
struct ToolFlowTests {
    private func tool(_ id: String) throws -> ToolDefinition {
        try #require(ToolCatalog.tool(ToolID(rawValue: id)))
    }

    @Test func singleDecisionToolsRunOnPick() throws {
        // Picking the file is the whole decision for these.
        for id in ["pdf.reverse", "pdf.flatten", "pdf.grayscale", "pdf.repair", "pdf.removeblank", "pdf.extractimages", "pdf.pdfa"] {
            #expect(try tool(id).runsOnPick, "\(id) should run as soon as its file is picked")
        }
        // These need a choice, an editor, or more than one file.
        for id in ["pdf.compress", "pdf.merge", "pdf.organize", "pdf.sign", "image.meme", "image.crop", "video.trim", "pdf.protect", "pdf.delete", "pdf.extract", "pdf.split"] {
            #expect(try !tool(id).runsOnPick, "\(id) shouldn't run before the user has decided")
        }
    }

    @Test func missingInputIsExplainedBeforeTapping() throws {
        let pdf = try ToolInputFile(url: try Corpus.input(Corpus.documents[0]).url)
        func reason(_ id: String, _ values: [String: OptionValue] = [:], editor: ToolEditorState = .none) throws -> String? {
            let tool = try tool(id)
            var options = ToolOptionValues(defaults: tool.options)
            for (key, value) in values { options[key] = value }
            return tool.validate?(options, editor, [pdf])
        }
        #expect(try reason("pdf.delete") == "Tap the pages to delete")
        #expect(try reason("pdf.delete", editor: .pageSelection([1])) == nil)
        #expect(try reason("pdf.delete", ["pages": .string("2")]) == nil)
        #expect(try reason("pdf.protect", ["password": .string("a"), "confirm": .string("b")]) == "The passwords don't match")
        #expect(try reason("pdf.protect", ["password": .string("a"), "confirm": .string("a")]) == nil)
        #expect(try reason("pdf.sign") == "Place your signature")
        #expect(try reason("pdf.split") == "Tap the page where each new PDF starts")
        #expect(try reason("pdf.split", editor: .pageSelection([2])) == nil)
        #expect(try reason("pdf.split", ["mode": .string("each")]) == nil)
        #expect(try reason("pdf.redact") == "Type the words to hide")
        #expect(try reason("image.meme") == "Tap a text box and type")
        #expect(try reason("image.meme", editor: .texts([TextOverlay(text: "hi")])) == nil)
        #expect(try reason("util.qr") == "Type a link or text")
        #expect(try reason("audio.adjust") == "Change the volume or add a fade")
        #expect(try reason("audio.adjust", ["volume": .number(3)]) == nil)
        #expect(try reason("image.adjust") == "Pick a filter or move a slider")
        #expect(try reason("image.adjust", ["filter": .string("mono")]) == nil)
    }

    @Test func viewModelBlocksWithTheToolsReason() throws {
        let input = try Corpus.input(Corpus.documents[0])
        let model = ToolViewModel(tool: try tool("pdf.delete"), inputs: [input])
        #expect(model.blockingReason == "Tap the pages to delete")
        #expect(!model.isMissingFiles)
        model.values["pages"] = .string("1")
        #expect(model.blockingReason == nil)

        let empty = ToolViewModel(tool: try tool("pdf.merge"), inputs: [])
        #expect(empty.isMissingFiles, "With no files the button opens the picker")
        #expect(empty.blockingReason == "Add at least 2 PDFs")
        let music = ToolViewModel(tool: try tool("video.addaudio"), inputs: [])
        #expect(music.blockingReason == "Add a video and a song")
    }

    @Test func outputSettingsAreFolded() throws {
        for id in ["image.crop", "image.rotate", "image.text", "image.border"] {
            let tool = try tool(id)
            for key in ["saveAs", "quality"] {
                if let option = tool.options.first(where: { $0.key == key }) {
                    #expect(option.isAdvanced, "\(id): \(key) belongs under More options")
                }
            }
        }
        let model = ToolViewModel(tool: try tool("image.crop"), inputs: [])
        #expect(model.optionSections.isEmpty, "Crop shows its editor and nothing else up front")
        #expect(!model.advancedOptions.isEmpty)
    }

    @Test func textOverlayMapsToItsCaption() {
        let box = TextOverlay(text: "Alex", center: CGPoint(x: 0.25, y: 0.7), relativeSize: 0.1, allCaps: true)
        #expect(box.caption.text == "ALEX")
        #expect(box.caption.position == CGPoint(x: 0.25, y: 0.7))
        let frame = CaptionRenderer.frame(box.caption, imageSize: CGSize(width: 1_000, height: 800))
        #expect(abs(frame.midX - 250) < 1 && abs(frame.midY - 560) < 1)
        let starting = TextOverlay.defaults(for: .meme)
        let anchors = starting.map { $0.anchor }
        #expect(anchors == [PDFStamper.Placement.top, .bottom])
        #expect(starting.allSatisfy { $0.isEmpty }, "Starting boxes are placeholders, not drawn")
    }

    @Test func memeDrawsEveryTypedBoxAndSkipsEmptyOnes() async throws {
        let photo = try SelfTestFixtures.sample("astronaut-portrait.jpg")
        let boxes = [TextOverlay(text: "TOP", anchor: .top), TextOverlay(text: "", anchor: .bottom),
                     TextOverlay(text: "MIDDLE", center: CGPoint(x: 0.5, y: 0.5))]
        let output = try await Corpus.run("image.meme", [try ToolInputFile(url: photo)], editor: .texts(boxes))
        let before = try ImageToolkit.load(photo), after = try ImageToolkit.load(output.files[0].url)
        #expect(PixelDifference.mean(before, after, region: CGRect(x: 0.3, y: 0.0, width: 0.4, height: 0.12)) > 8, "top text missing")
        #expect(PixelDifference.mean(before, after, region: CGRect(x: 0.3, y: 0.45, width: 0.4, height: 0.1)) > 8, "middle text missing")
        #expect(PixelDifference.mean(before, after, region: CGRect(x: 0.3, y: 0.88, width: 0.4, height: 0.1)) < 3, "an empty box was drawn")
    }

    @Test func tappedPagesDriveDeleteAndExtract() async throws {
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.write(SelfTestFixtures.makePDF(pages: 4, body: "Body"), to: url)
        let input = try ToolInputFile(url: url)
        let deleted = try await Corpus.run("pdf.delete", [input], editor: .pageSelection([0, 2]))
        #expect(TestSupport.pageTitles(try #require(PDFDocument(url: deleted.files[0].url))) == ["Page 2", "Page 4"])
        let kept = try await Corpus.run("pdf.extract", [input], editor: .pageSelection([1, 3]))
        #expect(TestSupport.pageTitles(try #require(PDFDocument(url: kept.files[0].url))) == ["Page 2", "Page 4"])
    }

    @Test func tappedPagesSplitThePDF() async throws {
        #expect(PDFToolkit.SplitMode.ranges(startingAt: [2, 5], pageCount: 8) == "1-2, 3-5, 6-8")
        #expect(PDFToolkit.SplitMode.ranges(startingAt: [0, 1, 3, 9], pageCount: 4) == "1, 2-3, 4", "page 1 and out-of-range taps are ignored")
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.write(SelfTestFixtures.makePDF(pages: 5, body: "Body"), to: url)
        let output = try await Corpus.run("pdf.split", [try ToolInputFile(url: url)], editor: .pageSelection([1, 3]))
        let parts = try output.files.map { try #require(PDFDocument(url: $0.url)) }.map(TestSupport.pageTitles)
        #expect(parts == [["Page 1"], ["Page 2", "Page 3"], ["Page 4", "Page 5"]])
    }

    @Test func exactResizeKeepsProportionsByDefault() async throws {
        let photo = try SelfTestFixtures.sample("astronaut-portrait.jpg") // 500 × 625
        let output = try await Corpus.run("image.resize", [try ToolInputFile(url: photo)],
                                          ["mode": .string("exact"), "width": .number(400), "height": .number(400), "saveAs": .string("png")])
        let image = try ImageToolkit.load(output.files[0].url)
        #expect(image.height == 400 && image.width == 320, "\(image.width)×\(image.height)")
    }

    @Test func trimWhitespaceHonorsPages() throws {
        let document = SelfTestFixtures.makePDF(pages: 3, body: "Some text")
        let trimmed = PDFToolkit.autoTrim(document, pages: [1])
        let full = document.page(at: 0)!.bounds(for: .cropBox)
        #expect(trimmed.page(at: 0)!.bounds(for: .cropBox) == full, "page 1 wasn't chosen and must stay whole")
        #expect(trimmed.page(at: 1)!.bounds(for: .cropBox).height < full.height, "page 2 should be trimmed")
    }

    @Test func conversionsKeepTheLookByDefault() throws {
        let docx = try ToolInputFile(url: try SelfTestFixtures.sample("sample.docx"))
        let model = ToolViewModel(tool: try tool("convert.docx.pdf"), inputs: [docx])
        #expect(model.values.string("layout") == DocumentConverter.Layout.original.rawValue)
        #expect(model.optionSections.flatMap(\.options).allSatisfy { ["layout"].contains($0.key) },
                "Page and font settings are folded until someone wants them")
    }
}
