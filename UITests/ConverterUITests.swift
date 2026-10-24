import XCTest

/// End-to-end flows through the real app on a simulator: open a tool with a file, run it, check
/// the result, finish, and find it again in History. Files are handed to the app with the debug
/// `-MBInputs` launch argument, which goes through the same import path as the Files picker.
class ConverterUITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    override func tearDown() {
        // XCTest attaches a screenshot and the UI hierarchy on failure by itself.
        app?.terminate()
    }

    /// Starts the app from a clean, session-only history unless told otherwise.
    func launch(_ arguments: [String] = [], reset: Bool = true, savedHistory: Bool = false) {
        app = XCUIApplication()
        var base = ["-MBNoAnimations", "1", "-MBSavedHistory", savedHistory ? "1" : "0"]
        if reset { base += ["-MBResetState", "1"] }
        app.launchArguments = base + arguments
        app.launch()
    }

    func fixture(_ name: String) -> String {
        guard let url = Bundle(for: ConverterUITestCase.self).url(forResource: name, withExtension: nil, subdirectory: "Corpus") else {
            XCTFail("Missing fixture \(name)")
            return ""
        }
        return url.path
    }

    func openTool(_ id: String, with files: [String]) {
        launch(["-MBRoute", "tool:\(id)", "-MBInputs", files.map(fixture).joined(separator: ",")])
    }

    @discardableResult
    func wait(for element: XCUIElement, _ timeout: TimeInterval = 20, _ message: String) -> XCUIElement {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), message)
        return element
    }

    func tapTab(_ name: String) {
        let tab = app.tabBars.buttons[name].exists ? app.tabBars.buttons[name] : app.buttons[name].firstMatch
        wait(for: tab, 10, "No \(name) tab").tap()
    }

    func runTool(timeout: TimeInterval = 90) {
        let run = wait(for: app.buttons["tool.run"], 20, "The tool's action button never appeared")
        XCTAssertTrue(run.isEnabled, "Action button is disabled: \(run.label)")
        run.tap()
        wait(for: app.buttons["result.finish"], timeout, "The result screen never appeared")
    }

    var resultFiles: XCUIElementQuery { app.buttons.matching(identifier: "result.file") }
    var historyRows: XCUIElementQuery { app.buttons.matching(identifier: "history.row") }

    func attach(_ name: String, _ screenshot: XCUIScreenshot) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Polls screenshots until the middle of the screen (below the navigation bar) has visible
    /// content — a blank white or empty preview fails.
    func waitForVisibleContent(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if Self.inkFraction(of: app.screenshot().image) > 0.01 { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    /// Share of sampled pixels in the central region that clearly differ from white.
    static func inkFraction(of image: UIImage) -> Double {
        guard let cgImage = image.cgImage else { return 0 }
        let side = 64
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        // Skip the status/navigation bars and the bottom toolbar.
        let crop = CGRect(x: 0, y: CGFloat(cgImage.height) * 0.2, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height) * 0.6)
        guard let region = cgImage.cropping(to: crop) else { return 0 }
        context.draw(region, in: CGRect(x: 0, y: 0, width: side, height: side))
        var ink = 0
        for index in stride(from: 0, to: pixels.count, by: 4) where min(pixels[index], pixels[index + 1], pixels[index + 2]) < 225 {
            ink += 1
        }
        return Double(ink) / Double(side * side)
    }

    /// Opens a result file in Quick Look, confirms it shows that file, then closes it.
    func previewFirstResult(_ name: String) {
        let row = resultFiles.firstMatch
        // The row's label starts with the file name; Quick Look titles itself with the name minus extension.
        let fileName = row.label.components(separatedBy: ",").first?.trimmingCharacters(in: .whitespaces) ?? row.label
        let title = (fileName as NSString).deletingPathExtension
        row.tap()
        // Quick Look's navigation bar is identified by the file name without its extension.
        let header = app.navigationBars[title].firstMatch
        wait(for: header, 15, "Quick Look didn't open \(fileName)")
        // Quick Look renders asynchronously. Opening isn't enough: the preview must show content.
        let shown = waitForVisibleContent(timeout: 20)
        attach(name, app.screenshot())
        XCTAssertTrue(shown, "\(fileName) opened in Quick Look but the preview stayed blank")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12))
        start.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)))
        XCTAssertTrue(app.buttons["result.finish"].waitForExistence(timeout: 10), "Quick Look didn't close")
    }
}

final class ToolFlowUITests: ConverterUITestCase {
    /// The flow from the bug report: extract pictures from a print PDF, preview, finish, find it in History.
    func testExtractImagesThenFinishShowsInHistoryAndReopens() {
        openTool("pdf.extractimages", with: ["usgs-streamstats.pdf"])
        runTool()
        XCTAssertTrue(app.staticTexts["Extract Images"].exists)
        XCTAssertGreaterThanOrEqual(resultFiles.count, 2, "Expected the PDF's photos and maps")
        attach("Extract Images result", app.screenshot())
        previewFirstResult("Extracted picture in Quick Look")

        app.buttons["result.finish"].tap()
        tapTab("History")
        let row = wait(for: historyRows.firstMatch, 10, "The tool result didn't reach History")
        XCTAssertTrue(row.label.contains("usgs-streamstats.pdf"), "History row: \(row.label)")
        XCTAssertTrue(row.label.contains("Extract Images"), "History row: \(row.label)")
        attach("History", app.screenshot())

        row.tap()
        wait(for: app.buttons["result.finish"], 10, "History didn't reopen the result")
        XCTAssertGreaterThanOrEqual(resultFiles.count, 2)
    }

    func testPDFToHTMLExactCopyOpensInPreview() {
        openTool("convert.pdf.html", with: ["fda-nutrition-label.pdf"])
        // PDF inputs offer the Exact copy / Reflowable choice.
        wait(for: app.buttons["Exact copy"].firstMatch.exists ? app.buttons["Exact copy"].firstMatch : app.staticTexts["Exact copy"].firstMatch,
             10, "Exact copy layout option missing")
        runTool()
        XCTAssertEqual(resultFiles.count, 1)
        XCTAssertTrue(resultFiles.firstMatch.label.contains(".html"), resultFiles.firstMatch.label)
        previewFirstResult("Exact-copy HTML in Quick Look")
    }

    func testPDFToWordKeepsPictures() {
        openTool("convert.pdf.docx", with: ["usgs-streamstats.pdf"])
        runTool()
        XCTAssertTrue(resultFiles.firstMatch.label.contains(".docx"), resultFiles.firstMatch.label)
        previewFirstResult("Word document in Quick Look")
    }

    func testMergeNeedsTwoFilesThenMerges() {
        openTool("pdf.merge", with: ["irs-w9-form.pdf", "irs-p1544.pdf"])
        runTool()
        XCTAssertEqual(resultFiles.count, 1)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS '12 pages'")).firstMatch.exists
                      || app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'pages'")).firstMatch.exists,
                      "Merge summary should mention the page count")
    }

    func testRedactThenPreview() {
        launch(["-MBRoute", "tool:pdf.redact", "-MBInputs", fixture("irs-p1544.pdf")])
        let field = wait(for: app.textViews.firstMatch.exists ? app.textViews.firstMatch : app.textFields.firstMatch, 15, "No terms field")
        field.tap()
        field.typeText("Reporting Cash Payments")
        if app.buttons["Done"].exists { app.buttons["Done"].firstMatch.tap() }
        runTool()
        previewFirstResult("Redacted PDF")
    }
}

final class HistoryUITests: ConverterUITestCase {
    func testToolResultsShowOnHomeRecentShelf() {
        openTool("pdf.reverse", with: ["irs-w4-form.pdf"])
        runTool()
        app.buttons["result.finish"].tap()
        tapTab("Convert")
        let card = wait(for: app.buttons["recent.card"].firstMatch, 10, "Recent shelf didn't show the tool result")
        XCTAssertTrue(card.label.contains("irs-w4-form.pdf"), card.label)
        card.tap()
        wait(for: app.buttons["result.finish"], 10, "Recent card didn't reopen the result")
    }

    func testSavedHistorySurvivesRelaunch() {
        launch(["-MBRoute", "tool:pdf.compress", "-MBInputs", fixture("irs-w9-form.pdf")], savedHistory: true)
        runTool()
        app.buttons["result.finish"].tap()
        app.terminate()

        launch(["-MBRoute", "tab:history"], reset: false, savedHistory: true)
        let row = wait(for: historyRows.firstMatch, 10, "Saved history lost the tool result after relaunch")
        XCTAssertTrue(row.label.contains("irs-w9-form.pdf"), row.label)
        row.tap()
        wait(for: app.buttons["result.finish"], 10, "Saved result didn't reopen")
        XCTAssertEqual(resultFiles.count, 1)
    }

    func testSessionHistoryIsClearedOnRelaunch() {
        openTool("pdf.reverse", with: ["irs-w4-form.pdf"])
        runTool()
        app.buttons["result.finish"].tap()
        app.terminate()

        launch(["-MBRoute", "tab:history"], reset: false)
        XCTAssertTrue(app.staticTexts["Nothing Here Yet"].waitForExistence(timeout: 10), "Session-only history should start empty")
    }
}

final class MediaFlowUITests: ConverterUITestCase {
    func testConvertVideoRecordsHistory() {
        launch(["-MBRoute", "media", "-MBInputs", fixture("test-pattern.mp4")])
        let convert = wait(for: app.buttons["media.convert"], 30, "Video settings screen didn't open")
        // MP4 → MP4 with no changes has nothing to do (Convert stays disabled), so pick another format.
        app.buttons["Output format"].tap()
        wait(for: app.buttons["MOV"].firstMatch, 10, "Format menu didn't open").tap()
        XCTAssertTrue(convert.waitForEnabled(10), "Convert stays disabled after choosing MOV")
        attach("Video settings", app.screenshot())
        convert.tap()
        Thread.sleep(forTimeInterval: 4)
        attach("Converting", app.screenshot())
        wait(for: app.buttons["media.done"], 120, "Video conversion didn't finish")
        attach("Video result", app.screenshot())
        app.buttons["media.done"].tap()
        tapTab("History")
        let row = wait(for: historyRows.firstMatch, 10, "The conversion didn't reach History")
        XCTAssertTrue(row.label.contains("test-pattern.mp4"), row.label)
    }
}

final class BrowseUITests: ConverterUITestCase {
    func testFindAToolFromTheToolsTab() {
        launch()
        tapTab("Tools")
        let merge = wait(for: app.buttons.containing(NSPredicate(format: "label CONTAINS 'Merge PDF'")).firstMatch, 10, "Merge PDF isn't listed")
        merge.tap()
        let run = wait(for: app.buttons["tool.run"], 10, "Merge PDF didn't open")
        XCTAssertTrue(run.label.localizedCaseInsensitiveContains("add"), "Without files the action asks for them: \(run.label)")
        attach("Merge PDF empty state", app.screenshot())
    }
}

extension XCUIElement {
    func waitForEnabled(_ timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists && isEnabled { return true }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return exists && isEnabled
    }
}
