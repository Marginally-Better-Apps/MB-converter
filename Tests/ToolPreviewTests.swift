import CoreGraphics
import ImageIO
import Foundation
import Testing
@testable import Converter

/// Live previews must render for every previewable tool, follow option changes, and show what
/// Export will actually produce.
@Suite(.serialized, .timeLimit(.minutes(5)))
@MainActor
struct ToolPreviewTests {
    static let previewable = ToolCatalog.all.filter { $0.previewKind != nil }.map(\.id.rawValue)

    /// Waits for the model to settle after a change.
    private func settle(_ model: ToolPreviewModel, timeout: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await Task.sleep(for: .milliseconds(50))
        while model.isUpdating, Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!model.isUpdating, "Preview never settled")
    }

    @Test(arguments: previewable)
    func rendersForRealInput(_ id: String) async throws {
        let tool = try #require(ToolCatalog.tool(ToolID(rawValue: id)))
        let inputs = try await SelfTestPlan.inputs(for: tool)
        let model = ToolPreviewModel()
        model.schedule(tool: tool, inputs: inputs, options: SelfTestPlan.options(for: tool, inputs: inputs), editor: SelfTestPlan.editorState(for: tool))
        try await settle(model)
        if SelfTestPlan.isSimulatorLimitation(tool), model.result == nil { return }
        let result = try #require(model.result, "\(id): no preview (\(model.message ?? "no message"))")
        #expect(model.message == nil, "\(id): \(model.message ?? "")")
        #expect(!result.caption.isEmpty, "\(id): preview has no caption")
        switch tool.previewKind {
        case .image, .pdf: #expect(!result.images.isEmpty, "\(id): no picture")
        case .animation: #expect(result.frames.count > 1, "\(id): animation has \(result.frames.count) frames")
        case .video, .audio: #expect(result.mediaURL.map { FileManager.default.fileExists(atPath: $0.path) } == true, "\(id): no media")
        case nil: Issue.record("not previewable")
        }
        model.tearDown()
    }

    @Test func previewFollowsSliderChanges() async throws {
        let tool = try #require(ToolCatalog.tool("image.adjust"))
        let inputs = try await SelfTestPlan.inputs(for: tool)
        var options = SelfTestPlan.options(for: tool, inputs: inputs)
        let model = ToolPreviewModel()
        model.schedule(tool: tool, inputs: inputs, options: options, editor: .none)
        try await settle(model)
        let before = try #require(model.result?.images.first)
        #expect(Self.maxChroma(before) > 60, "The portrait should start in color")

        options["saturation"] = .number(0)
        model.schedule(tool: tool, inputs: inputs, options: options, editor: .none)
        try await settle(model)
        let after = try #require(model.result?.images.first)
        #expect(Self.maxChroma(after) < 12, "Saturation 0 should make the preview gray (chroma \(Self.maxChroma(after)))")
    }

    @Test func previewMatchesTheExportedFile() async throws {
        let tool = try #require(ToolCatalog.tool("image.adjust"))
        let inputs = try await SelfTestPlan.inputs(for: tool)
        var options = SelfTestPlan.options(for: tool, inputs: inputs)
        options["filter"] = .string("sepia")
        options["contrast"] = .number(130)
        let model = ToolPreviewModel()
        model.schedule(tool: tool, inputs: inputs, options: options, editor: .none)
        try await settle(model)
        let preview = try #require(model.result?.images.first)
        let exported = try await tool.run(ToolContext(inputs: inputs, options: options))
        let output = try ImageToolkit.load(try #require(exported.files.first).url)
        #expect(Look.difference(preview, output) < 3, "Preview and export differ by \(Look.difference(preview, output))")
    }

    @Test func pdfPreviewShowsTheWatermarkText() async throws {
        let tool = try #require(ToolCatalog.tool("pdf.watermark"))
        let inputs = try await SelfTestPlan.inputs(for: tool)
        var options = SelfTestPlan.options(for: tool, inputs: inputs)
        options["opacity"] = .number(100)
        let model = ToolPreviewModel()
        model.schedule(tool: tool, inputs: inputs, options: options, editor: .none)
        try await settle(model)
        let first = try #require(model.result?.images.first)
        options["text"] = .string("A MUCH LONGER DRAFT WATERMARK")
        model.schedule(tool: tool, inputs: inputs, options: options, editor: .none)
        try await settle(model)
        let second = try #require(model.result?.images.first)
        #expect(Look.difference(first, second) > 0.5, "Changing the watermark text didn't change the preview")
    }

    @Test func missingInputExplainsInsteadOfFailing() async throws {
        let tool = try #require(ToolCatalog.tool("image.text"))
        let inputs = try await SelfTestPlan.inputs(for: tool)
        var options = SelfTestPlan.options(for: tool, inputs: inputs)
        options["text"] = .string("")
        let model = ToolPreviewModel()
        model.schedule(tool: tool, inputs: inputs, options: options, editor: .none)
        try await settle(model)
        #expect(model.message != nil, "An empty caption should explain what's needed")
    }

    static func maxChroma(_ image: CGImage) -> Int {
        let pixels = ImageStats.pixels(image, side: 64)
        var best = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            best = max(best, max(r, g, b) - min(r, g, b))
        }
        return best
    }
}

