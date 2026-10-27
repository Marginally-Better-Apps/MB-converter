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

    @Test func historyIsSavedByDefaultButAnExplicitChoiceWins() {
        let defaults = UserDefaults.standard
        let key = ConversionHistoryUserDefaults.isEnabledKey
        let stored = defaults.object(forKey: key)
        defer {
            defaults.set(stored, forKey: key)
            ConversionHistoryStore.shared.refreshForCurrentSettings()
        }
        defaults.removeObject(forKey: key)
        #expect(ConversionHistoryUserDefaults.isEnabled, "A fresh install keeps results")
        ConversionHistoryUserDefaults.isEnabled = false
        #expect(!ConversionHistoryUserDefaults.isEnabled, "Someone who turned it off stays off")
    }

    @Test func keepMyResultsTurnsSavedHistoryOnAndKeepsThisSession() throws {
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
        #expect(store.enableSavedHistory())
        #expect(ConversionHistoryUserDefaults.isEnabled)
        let entry = try #require(store.toolEntry(withId: run.id), "This session's result is kept")
        #expect(entry.folder.path.contains("Application Support"))
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

/// History rows lead with the file you got and sit under Today, Yesterday or Earlier.
@Suite struct HistoryRowTests {
    private func toolItem(at date: Date, files: [String] = ["Report-compressed.pdf"], inputs: [String] = ["Report.pdf"]) -> HistoryItem {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("history-row-tests", isDirectory: true)
        return .tool(ToolHistoryEntry(
            id: UUID(), createdAt: date, toolID: "pdf.compress", title: "Compress PDF", inputNames: inputs,
            files: files.map { folder.appendingPathComponent($0) }, summary: nil, text: nil
        ))
    }

    @Test func rowsNameTheOutputAndTheTool() {
        let item = toolItem(at: .now, inputs: ["IMG_0234.HEIC", "IMG_0235.HEIC", "IMG_0236.HEIC"])
        #expect(item.outputName == "Report-compressed.pdf")
        #expect(item.actionSummary.hasPrefix("Compress PDF"))
        #expect(item.sourceLine(timeOnly: true).hasPrefix("From IMG_0234.HEIC + 2 more · "))

        let several = toolItem(at: .now, files: ["a.png", "b.png", "c.png"])
        #expect(several.outputName == "a.png + 2 more")
        #expect(several.actionSummary.contains("3 files"))

        let made = toolItem(at: .now, files: [], inputs: [])
        #expect(made.outputName == "Compress PDF", "Nothing saved: the tool's name stands in")
        #expect(!made.sourceLine(timeOnly: true).contains("From"))
    }

    @Test func conversionsAreNamedLikeTheirExport() throws {
        let input = MediaFile(url: URL(fileURLWithPath: "/tmp/in.heic"), originalFilename: "IMG_0234.HEIC", category: .image,
                              sizeOnDisk: 10, dimensions: CGSize(width: 4, height: 3), containerFormat: "heic")
        let result = ConversionResult(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).jpg"), outputFormat: .jpg, sizeOnDisk: 2048)
        let item = HistoryItem.conversion(ConversionHistoryEntry(
            id: UUID(), createdAt: .now, input: input, config: ConversionConfig(outputFormat: .jpg), result: result
        ))
        #expect(item.outputName == "IMG_0234.jpg")
        #expect(item.actionSummary.hasPrefix("HEIC to \(OutputFormat.jpg.displayName)"))
        #expect(item.sourceLine(timeOnly: true).hasPrefix("From IMG_0234.HEIC"))
    }

    @Test func groupsByDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 9)))
        let items = [
            toolItem(at: now.addingTimeInterval(-60 * 60)),            // 8 AM today
            toolItem(at: now.addingTimeInterval(-10 * 60 * 60)),       // 11 PM yesterday
            toolItem(at: now.addingTimeInterval(-30 * 60 * 60)),       // 3 AM yesterday
            toolItem(at: now.addingTimeInterval(-3 * 24 * 60 * 60))    // three days ago
        ]
        let groups = HistoryDay.group(items, now: now, calendar: calendar)
        #expect(groups.map(\.day) == [.today, .yesterday, .earlier])
        #expect(groups.map(\.items.count) == [1, 2, 1])
        #expect(groups[1].items.map(\.id) == [items[1].id, items[2].id], "Newest first within a day")
        #expect(HistoryDay.group([], now: now, calendar: calendar).isEmpty)
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

/// Imported files keep names people recognize: on the settings screen, results and History.
@Suite struct ImportNamingTests {
    @Test func importsKeepTheirOriginalName() throws {
        let source = TestSupport.tempURL("pdf")
        try Data("x".utf8).write(to: source)
        let named = source.deletingLastPathComponent().appendingPathComponent("Quarterly Report.pdf")
        try? FileManager.default.removeItem(at: named)
        try FileManager.default.moveItem(at: source, to: named)
        let copy = try ImportStorage.copyFile(at: named, fallbackExtension: "pdf")
        #expect(copy.lastPathComponent == "Quarterly Report.pdf")
        // Two imports of the same name never collide.
        let second = try ImportStorage.copyFile(at: named, fallbackExtension: "pdf")
        #expect(second != copy && second.lastPathComponent == "Quarterly Report.pdf")
    }

    @Test func machineGeneratedNamesBecomeReadable() {
        let date = Date(timeIntervalSince1970: 1_793_000_000)
        let name = ImportStorage.displayBaseName("0FE7FDEB-94A1-4C2B-9D3E-7A6B0BD95629.jpeg", kind: "Photo", now: date)
        #expect(name.hasPrefix("Photo ") && name.contains(" at "), "Got \(name)")
        #expect(!name.contains(":") && !name.contains("/"), "File-name-safe: \(name)")
        #expect(ImportStorage.displayBaseName("IMG_1234.HEIC", kind: "Photo") == "IMG_1234")
        #expect(ImportStorage.displayBaseName(nil, kind: "Pasted", now: date).hasPrefix("Pasted "))
    }
}
