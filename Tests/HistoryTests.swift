import Foundation
import PDFKit
import Testing
@testable import Converter

/// Tool runs land in History like media conversions do, and stay usable from there.
@Suite(.serialized) @MainActor
struct ToolHistoryTests {
    private func sampleRun() throws -> ToolRun {
        let folder = ToolStorage.newRunDirectory()
        let pdf = folder.appendingPathComponent("Report-reversed.pdf")
        try PDFToolkit.write(TestSupport.makePDF(pages: 2), to: pdf)
        let input = try ToolInputFile(url: try ToolInputFactory.makeSync(.pdf))
        return ToolRun(toolID: "pdf.reverse", inputs: [input], output: ToolOutput(files: [pdf], summary: "2 pages"))
    }

    @Test func finishedToolRunsAreRecordedAndSurviveTheTemporaryFiles() throws {
        let store = ConversionHistoryStore.shared
        let run = try sampleRun()
        store.record(run, title: "Reverse Pages")
        defer { store.removeEntry(id: run.id) }

        let entry = try #require(store.toolEntry(withId: run.id))
        #expect(entry.title == "Reverse Pages")
        #expect(entry.files.count == 1)
        #expect(entry.files[0] != run.output.files[0].url, "History must keep its own copy")
        #expect(store.items.first?.id == run.id, "Newest item comes first")

        // The run's temporary output can be cleaned up; History still opens.
        try FileManager.default.removeItem(at: run.output.files[0].url)
        let reopened = entry.run
        #expect(reopened.fromHistory)
        #expect(PDFDocument(url: reopened.output.files[0].url)?.pageCount == 2)
    }

    @Test func recordingTheSameRunTwiceKeepsOneEntry() throws {
        let store = ConversionHistoryStore.shared
        let run = try sampleRun()
        store.record(run, title: "Reverse Pages")
        store.record(run, title: "Reverse Pages")
        defer { store.removeEntry(id: run.id) }
        #expect(store.toolEntries.filter { $0.id == run.id }.count == 1)
    }

    @Test func renamesOnTheResultScreenFollowIntoHistory() throws {
        let store = ConversionHistoryStore.shared
        let run = try sampleRun()
        store.record(run, title: "Reverse Pages")
        defer { store.removeEntry(id: run.id) }
        store.renameToolOutput(runID: run.id, from: "Report-reversed.pdf", to: "Final.pdf")
        let entry = try #require(store.toolEntry(withId: run.id))
        #expect(entry.files.map(\.lastPathComponent) == ["Final.pdf"])
        #expect(FileManager.default.fileExists(atPath: entry.files[0].path))
    }

    @Test func deletingRemovesTheFiles() throws {
        let store = ConversionHistoryStore.shared
        let run = try sampleRun()
        store.record(run, title: "Reverse Pages")
        let folder = try #require(store.toolEntry(withId: run.id)).folder
        store.removeEntry(id: run.id)
        #expect(store.toolEntry(withId: run.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func turningOnSavedHistoryKeepsThisSessionsToolRuns() throws {
        let store = ConversionHistoryStore.shared
        let wasEnabled = ConversionHistoryUserDefaults.isEnabled
        ConversionHistoryUserDefaults.isEnabled = false
        store.refreshForCurrentSettings()
        defer {
            ConversionHistoryUserDefaults.isEnabled = wasEnabled
            store.refreshForCurrentSettings()
        }
        let run = try sampleRun()
        store.record(run, title: "Reverse Pages")
        #expect(store.persistSessionHistory())
        ConversionHistoryUserDefaults.isEnabled = true
        store.refreshForCurrentSettings()
        let entry = try #require(store.toolEntry(withId: run.id))
        #expect(entry.folder.path.contains("Application Support"), "Saved history lives in Application Support, got \(entry.folder.path)")
        #expect(FileManager.default.fileExists(atPath: entry.files[0].path))
        store.removeEntry(id: run.id)
    }

    @Test func runningAToolFromTheToolScreenRecordsIt() async throws {
        let tool = try #require(ToolCatalog.tool("pdf.reverse"))
        let input = try ToolInputFile(url: try ToolInputFactory.makeSync(.pdf))
        let model = ToolViewModel(tool: tool, inputs: [input])
        let run = try #require(await model.run())
        defer { ConversionHistoryStore.shared.removeEntry(id: run.id) }
        let entry = try #require(ConversionHistoryStore.shared.toolEntry(withId: run.id))
        #expect(entry.inputNames == [input.displayName])
        #expect(entry.toolID == "pdf.reverse")
    }
}

extension ToolInputFactory {
    static func makeSync(_ format: FileFormat) throws -> URL {
        precondition(format == .pdf, "Only PDFs are synthesized synchronously")
        let url = TestSupport.tempURL("pdf")
        try PDFToolkit.write(TestSupport.makePDF(pages: 3, body: "Quarterly numbers."), to: url)
        return url
    }
}

/// Result previews never land on Quick Look's blank "can't preview" screen.
@Suite @MainActor struct PreviewStandInTests {
    @Test func openDocumentAndRareImagesGetReadableStandIns() throws {
        let odt = TestSupport.tempURL("odt")
        try ODTWriter.write(TestSupport.sampleDocument, options: .default, to: odt)
        let item = QuickLookStandIn.item(for: odt)
        let standIn = try #require(item.previewItemURL ?? nil)
        #expect(standIn.pathExtension == "html")
        #expect(item.previewItemTitle == odt.lastPathComponent, "The sheet still shows the real file name")
        #expect(try String(contentsOf: standIn, encoding: .utf8).contains("Sample Title"))

        let qoi = TestSupport.tempURL("qoi")
        try ImageToolkit.encode(TestSupport.makeImage(width: 40, height: 30), as: .qoi).write(to: qoi)
        let image = try #require(QuickLookStandIn.item(for: qoi).previewItemURL ?? nil)
        #expect(image.pathExtension == "png")

        let png = try TestSupport.writeImage(TestSupport.makeImage(width: 40, height: 30))
        #expect(QuickLookStandIn.item(for: png).previewItemURL == png, "Formats Quick Look handles are shown as-is")
    }
}
