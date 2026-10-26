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
        // Leave evidence for every failure: what was on screen and what XCUITest could see.
        if let app, (testRun?.totalFailureCount ?? 0) > 0 {
            attach("Failure screen", app.screenshot())
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Failure UI hierarchy"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
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

    /// Waits for an element while answering system permission prompts the way a user would.
    /// (iOS asks for notification permission during a first conversion; the app stays inactive,
    /// and holds its result screen, until the prompt is answered.)
    @discardableResult
    func waitAnsweringSystemPrompts(for element: XCUIElement, _ timeout: TimeInterval, _ message: String) -> XCUIElement {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if element.exists { return element }
            let allow = springboard.alerts.buttons["Allow"]
            if allow.exists { allow.tap() }
            Thread.sleep(forTimeInterval: 0.5)
        }
        XCTAssertTrue(element.exists, message)
        return element
    }

    /// Opens the media format menu and picks a format, retrying if a tap lands while the screen settles.
    func chooseOutputFormat(_ name: String) {
        let menu = wait(for: app.buttons["Output format"], 20, "No output format menu")
        for _ in 0 ..< 3 {
            menu.tap()
            let choice = app.buttons[name].firstMatch
            if choice.waitForExistence(timeout: 4) {
                choice.tap()
                return
            }
        }
        XCTFail("The format menu didn't offer \(name)")
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
        if !header.waitForExistence(timeout: 20), row.exists, row.isHittable { row.tap() }
        wait(for: header, 30, "Quick Look didn't open \(fileName)")
        // Quick Look renders asynchronously. Opening isn't enough: the preview must show content.
        // Its web renderer can take most of a minute to start on a loaded CI runner.
        let shown = waitForVisibleContent(timeout: 60)
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
        // The action button is under the keyboard until it has slid away.
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "The keyboard didn't close")
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

    func testKeepMyResultsTurnsOnSavedHistory() {
        launch(["-MBRoute", "tab:history"])
        let keep = wait(for: app.buttons["Keep my results"], 10, "Session-only History should offer to keep results")
        attach("Session-only History", app.screenshot())
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 5), "The offer should go away once results are kept")
        let summary = app.descendants(matching: .any).containing(NSPredicate(format: "label CONTAINS 'Saved history is on'")).firstMatch
        XCTAssertTrue(summary.waitForExistence(timeout: 5), "History should say results are saved")
    }
}

final class MediaFlowUITests: ConverterUITestCase {
    func testConvertVideoRecordsHistory() {
        launch(["-MBRoute", "media", "-MBInputs", fixture("test-pattern.mp4")])
        let convert = wait(for: app.buttons["media.convert"], 30, "Video settings screen didn't open")
        // MP4 → MP4 with no changes has nothing to do (Convert stays disabled), so pick another format.
        chooseOutputFormat("MOV")
        XCTAssertTrue(convert.waitForEnabled(10), "Convert stays disabled after choosing MOV")
        attach("Video settings", app.screenshot())
        convert.tap()
        Thread.sleep(forTimeInterval: 4)
        attach("Converting", app.screenshot())
        waitAnsweringSystemPrompts(for: app.buttons["media.done"], 180, "Video conversion didn't finish")
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

    func testSettingsFromTheToolsTab() {
        launch()
        tapTab("Tools")
        wait(for: app.buttons["Open settings"].firstMatch, 10, "The Tools tab has no Settings button").tap()
        wait(for: app.buttons["settings.reportProblem"].firstMatch, 10, "Settings should offer Report a Problem under About")
        XCTAssertTrue(app.switches.firstMatch.exists, "Save History toggle missing")
        attach("Settings", app.screenshot())
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

/// Real imports through the iOS pickers, with files a person would have. Requires the simulator to be
/// seeded with `Scripts/SeedSimulator.sh` (CI does this before testing).
final class RealPickerUITests: ConverterUITestCase {
    /// In the Files picker: Browse → On My iPhone → MB Converter Samples, then tap each file and Open.
    func pickInFiles(_ names: [String]) {
        let browse = app.buttons["Browse"].firstMatch
        if browse.waitForExistence(timeout: 10) { browse.tap() }
        func item(_ name: String) -> XCUIElement {
            app.cells.containing(.staticText, identifier: (name as NSString).deletingPathExtension).firstMatch
        }
        // The picker remembers its last folder; navigate until the sample files are showing.
        func element(labelContaining text: String) -> XCUIElement {
            app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text))
                .allElementsBoundByIndex.first { $0.isHittable } ?? app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
        }
        var attempts = 0
        // Folder contents can take a few seconds to appear on a busy simulator.
        while !item(names[0]).waitForExistence(timeout: 6), attempts < 4 {
            attempts += 1
            // Match the folder cell by its full name: "MB Converter" alone also matches the app's own title.
            let folderCell = app.cells.matching(NSPredicate(format: "label CONTAINS 'MB Converter Samples'")).firstMatch
            let folder = folderCell.exists ? folderCell : element(labelContaining: "MB Converter Samples")
            if folder.exists, folder.isHittable { folder.tap(); continue }
            let onMyPhone = element(labelContaining: "On My iPhone")
            if onMyPhone.exists, onMyPhone.isHittable, !app.navigationBars["On My iPhone"].exists { onMyPhone.tap(); continue }
            if browse.exists { browse.tap() }
        }
        guard item(names[0]).exists else {
            XCTFail("The Files picker has no “MB Converter Samples” folder — run Scripts/SeedSimulator.sh first")
            return
        }
        let select = app.buttons["Select"].firstMatch
        if names.count > 1, select.waitForExistence(timeout: 3) { select.tap() }
        for name in names {
            wait(for: item(name), 10, "\(name) isn't in the picker").tap()
        }
        // Pickers that allow several files need an explicit Open, even for one.
        let open = app.buttons["Open"].firstMatch
        if open.waitForExistence(timeout: 2), open.isEnabled { open.tap() }
    }

    /// In the Photos picker (a separate system process XCUITest can't inspect), tap the newest item:
    /// the top-left cell of the grid.
    func pickInPhotos(opening trigger: XCUIElement, until opened: XCUIElement) {
        for attempt in 0 ..< 2 {
            // Wait until the picker sheet actually covers the app before tapping into it.
            let deadline = Date().addingTimeInterval(20)
            while trigger.isHittable, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
            Thread.sleep(forTimeInterval: 1.5) // grid layout settles
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.16, dy: 0.42)).tap()
            let add = app.buttons["Add"].firstMatch
            if add.waitForExistence(timeout: 2) { add.tap() }
            if opened.waitForExistence(timeout: 20) || attempt == 1 { return }
        }
    }

    func testImportPDFFromFilesThenCompress() {
        launch()
        wait(for: app.buttons["Import from Files"], 15, "No Files button on Home").tap()
        pickInFiles(["irs-w9-form.pdf"])
        let compress = app.buttons.containing(NSPredicate(format: "label CONTAINS 'Compress PDF'")).firstMatch
        wait(for: compress, 20, "The imported PDF's tools didn't appear").tap()
        runTool()
        XCTAssertTrue(resultFiles.firstMatch.label.contains("irs-w9-form"), resultFiles.firstMatch.label)
        previewFirstResult("Compressed W-9 from Files")
        app.buttons["result.finish"].tap()
        tapTab("History")
        wait(for: historyRows.firstMatch, 10, "Not in History")
    }

    func testMergeTwoPDFsPickedInFiles() {
        launch()
        tapTab("Tools")
        wait(for: app.buttons.containing(NSPredicate(format: "label CONTAINS 'Merge PDF'")).firstMatch, 10, "No Merge PDF").tap()
        wait(for: app.buttons["Files"].firstMatch, 10, "No Files button in the tool").tap()
        pickInFiles(["irs-w9-form.pdf", "fda-nutrition-label.pdf"])
        runTool()
        XCTAssertEqual(resultFiles.count, 1)
        previewFirstResult("Merged PDFs picked in Files")
    }

    func testConvertWordDocumentPickedInFilesToPDF() {
        launch(["-MBRoute", "tool:convert.docx.pdf"])
        wait(for: app.buttons["Files"].firstMatch, 15, "No Files button in the tool").tap()
        pickInFiles(["sample.docx"])
        runTool()
        previewFirstResult("Word → PDF from Files")
    }

    func testConvertPhotoFromPhotosLibrary() {
        launch()
        let tile = wait(for: app.buttons["Import an image from Photos"], 15, "No Photos tile")
        tile.tap()
        pickInPhotos(opening: tile, until: app.buttons["media.convert"])
        let convert = wait(for: app.buttons["media.convert"], 30, "The photo didn't open")
        // Photos arrive with machine names; people should see a readable one.
        let uuidTitle = app.staticTexts.matching(NSPredicate(format: "label MATCHES '^[0-9A-F]{8}-.*'")).firstMatch
        XCTAssertFalse(uuidTitle.exists, "The photo is shown under a generated ID: \(uuidTitle.label)")
        // JPEG → JPEG at full size has nothing to do; pick PNG.
        chooseOutputFormat("PNG")
        attach("Photo settings", app.screenshot())
        XCTAssertTrue(convert.waitForEnabled(10))
        convert.tap()
        waitAnsweringSystemPrompts(for: app.buttons["media.done"], 120, "Photo conversion didn't finish")
        attach("Photo result", app.screenshot())
        app.buttons["media.done"].tap()
        tapTab("History")
        wait(for: historyRows.firstMatch, 10, "The photo conversion isn't in History")
    }

    func testConvertVideoFromPhotosLibrary() {
        launch()
        let tile = wait(for: app.buttons["Import a video from Photos"], 15, "No Videos tile")
        tile.tap()
        pickInPhotos(opening: tile, until: app.buttons["media.convert"])
        let convert = wait(for: app.buttons["media.convert"], 40, "The video didn't open")
        chooseOutputFormat("MOV")
        XCTAssertTrue(convert.waitForEnabled(10))
        convert.tap()
        waitAnsweringSystemPrompts(for: app.buttons["media.done"], 180, "Video conversion didn't finish")
        attach("Video from Photos result", app.screenshot())
    }
}

/// Taps Settings → Diagnostics → Self-Test → Run and requires every check to pass (or, on the
/// simulator, skip only for missing hardware). The same button a developer uses on a phone.
final class SelfTestUITests: ConverterUITestCase {
    func testSelfTestScreenRunsEveryCheckClean() {
        launch()
        let settings = app.buttons["Open settings"].firstMatch
        wait(for: settings, 15, "No Settings button").tap()
        let entry = app.buttons["settings.selftest"].firstMatch
        var swipes = 0
        while !(entry.exists && entry.isHittable), swipes < 6 {
            app.swipeUp()
            swipes += 1
        }
        wait(for: entry, 10, "No Self-Test row in Settings (is this a SELF_TEST build?)").tap()
        wait(for: app.buttons["selftest.run"], 10, "Self-Test screen didn't open").tap()
        let finished = app.otherElements["selftest.finished"].firstMatch.exists ? app.otherElements["selftest.finished"].firstMatch : app.descendants(matching: .any)["selftest.finished"].firstMatch
        waitAnsweringSystemPrompts(for: finished, 1_200, "The self-test didn't finish")
        attach("Self-test results", app.screenshot())
        XCTAssertTrue(finished.label.contains(", 0 failed"), "Self-test summary: \(finished.label). Failed: \(finished.value as? String ?? "?")")
    }
}


/// Live previews react to edits on screen: what you see while dragging is what you'll export.
final class LivePreviewUITests: ConverterUITestCase {
    /// Max channel spread (0…255) inside an element's frame: color vs. gray.
    func chroma(of element: XCUIElement) -> Int {
        let screenshot = app.screenshot().image
        guard let cgImage = screenshot.cgImage else { return 0 }
        let scale = CGFloat(cgImage.width) / app.frame.width
        let frame = element.frame
        guard let region = cgImage.cropping(to: CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)) else { return 0 }
        let side = 48
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(region, in: CGRect(x: 0, y: 0, width: side, height: side))
        var best = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            best = max(best, max(r, g, b) - min(r, g, b))
        }
        return best
    }

    func testDraggingSaturationUpdatesThePreview() {
        launch(["-MBRoute", "tool:image.adjust", "-MBInputs", fixture("astronaut-portrait.jpg")])
        let preview = wait(for: app.descendants(matching: .any)["tool.preview"].firstMatch, 20, "No live preview on Filters & Adjust")
        wait(for: app.staticTexts["tool.preview.caption"], 20, "The preview never rendered")
        XCTAssertGreaterThan(chroma(of: preview), 60, "The portrait preview should start in color")
        attach("Preview before", app.screenshot())

        // Saturation is the third slider on this screen.
        let saturation = app.sliders.element(boundBy: 2)
        wait(for: saturation, 10, "No Saturation slider")
        // Scroll the options until the slider sits fully between the pinned preview and the floating
        // action bar; a swipe can overshoot it under the preview, so scroll back when it does.
        let actionBar = app.buttons["tool.run"]
        var swipes = 0
        while swipes < 8 {
            let frame = saturation.frame
            if frame.minY < preview.frame.maxY + 8 {
                app.scrollViews.firstMatch.swipeDown(velocity: .slow)
            } else if frame.maxY > actionBar.frame.minY - 8 || !saturation.isHittable {
                app.scrollViews.firstMatch.swipeUp(velocity: .slow)
            } else {
                break
            }
            swipes += 1
        }
        saturation.adjust(toNormalizedSliderPosition: 0)
        XCTAssertLessThan(saturation.normalizedSliderPosition, 0.05, "The drag didn't reach the Saturation slider")
        let deadline = Date().addingTimeInterval(10)
        while chroma(of: preview) > 14, Date() < deadline { Thread.sleep(forTimeInterval: 0.3) }
        attach("Preview after saturation 0", app.screenshot())
        XCTAssertLessThanOrEqual(chroma(of: preview), 14, "Dragging saturation to zero didn't turn the preview gray")
    }

    func testTrimHandlesScrubTheVideo() {
        // The trim timeline is on the tool screen as soon as the video is in.
        launch(["-MBRoute", "tool:video.trim", "-MBInputs", fixture("test-pattern.mp4")])
        let video = wait(for: app.descendants(matching: .any)["Video preview"].firstMatch, 20, "The trim editor isn't on the screen")
        Thread.sleep(forTimeInterval: 1)
        let before = app.screenshot().image
        let start = app.descendants(matching: .any)["Start"].firstMatch
        wait(for: start, 10, "No start handle")
        let from = start.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 0.2, thenDragTo: from.withOffset(CGVector(dx: 160, dy: 0)))
        Thread.sleep(forTimeInterval: 1)
        attach("Trim after dragging start", app.screenshot())
        XCTAssertGreaterThan(Self.difference(before, app.screenshot().image, in: video.frame, screenWidth: app.frame.width), 4,
                             "Dragging the start handle didn't move the video to that moment")
    }

    static func difference(_ a: UIImage, _ b: UIImage, in frame: CGRect, screenWidth: CGFloat) -> Double {
        func pixels(_ image: UIImage) -> [UInt8] {
            guard let cgImage = image.cgImage else { return [] }
            let scale = CGFloat(cgImage.width) / screenWidth
            guard let region = cgImage.cropping(to: CGRect(x: frame.minX * scale, y: frame.minY * scale, width: frame.width * scale, height: frame.height * scale)) else { return [] }
            var buffer = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let context = CGContext(data: &buffer, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 128,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            context?.draw(region, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            return buffer
        }
        let pa = pixels(a), pb = pixels(b)
        guard pa.count == pb.count, !pa.isEmpty else { return 0 }
        var total = 0.0
        for index in pa.indices where index % 4 != 3 { total += abs(Double(pa[index]) - Double(pb[index])) }
        return total / Double(32 * 32 * 3)
    }
}

/// The Meme Maker end to end, on the tool screen itself: tap a box and type, drag it, add another
/// box, make the meme. Screens are attached (and saved to $MB_AUDIT_DIR/ui when set, for audits).
final class MemeEditorUITests: ConverterUITestCase {
    func saveScreen(_ name: String) {
        let screenshot = app.screenshot()
        attach(name, screenshot)
        if let directory = ProcessInfo.processInfo.environment["MB_AUDIT_DIR"] {
            let folder = URL(fileURLWithPath: directory).appendingPathComponent("ui", isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
        }
    }

    /// Selects a text box and types into the field that appears for it.
    func type(_ text: String, intoBox index: Int) {
        let box = wait(for: app.descendants(matching: .any)["text.box.\(index)"].firstMatch, 15, "No text box \(index)")
        box.tap()
        let field = wait(for: app.descendants(matching: .any)["text.field"].firstMatch, 10, "Tapping the box didn't open typing")
        if !app.keyboards.firstMatch.waitForExistence(timeout: 3) { field.tap() }
        field.typeText(text)
    }

    func testTypeDragAndAddMemeText() {
        launch(["-MBRoute", "tool:image.meme", "-MBInputs", fixture("astronaut-portrait.jpg")])
        let run = wait(for: app.buttons["tool.run"], 20, "No action button")
        XCTAssertFalse(run.isEnabled, "With no text yet the button should say what to do, not run")
        saveScreen("meme-1-empty")

        type("Alex", intoBox: 0)
        type("Letter league", intoBox: 1)
        saveScreen("meme-2-typed")
        app.keyboards.buttons["done"].firstMatch.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5), "The keyboard didn't close")

        // Drag the top caption down to the middle of the photo.
        let top = app.descendants(matching: .any)["text.box.0"].firstMatch
        let before = top.frame
        let start = top.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        start.press(forDuration: 0.15, thenDragTo: start.withOffset(CGVector(dx: -40, dy: 160)))
        XCTAssertGreaterThan(top.frame.midY - before.midY, 100, "The text didn't follow the drag (\(before) → \(top.frame))")

        // A third box, anywhere.
        wait(for: app.buttons["text.add"], 5, "No Add text button").tap()
        XCTAssertTrue(app.descendants(matching: .any)["text.box.2"].firstMatch.waitForExistence(timeout: 5), "Add text didn't add a box")
        app.descendants(matching: .any)["text.field"].firstMatch.typeText("MOON")
        saveScreen("meme-3-arranged")

        if app.keyboards.firstMatch.exists { app.keyboards.buttons["done"].firstMatch.tap() }
        XCTAssertTrue(run.waitForExistence(timeout: 5) && run.isEnabled, "With text typed the button should run")
        runTool()
        saveScreen("meme-4-result")
        XCTAssertEqual(resultFiles.count, 1)
    }
}

/// Opt-in visual audit of every tool screen. Run the AuditTests dump first (it saves each tool's
/// inputs), then: TEST_RUNNER_MB_AUDIT_DIR=/tmp/mbaudit xcodebuild test -only-testing:ConverterUITests/ToolTourUITests
/// Screenshots land in $MB_AUDIT_DIR/ui-tour; Scripts/AuditSheets.sh makes contact sheets of them.
final class ToolTourUITests: ConverterUITestCase {
    func testScreenOfEveryTool() throws {
        guard let directory = ProcessInfo.processInfo.environment["MB_AUDIT_DIR"] else {
            throw XCTSkip("Set TEST_RUNNER_MB_AUDIT_DIR to run the tool tour")
        }
        continueAfterFailure = true
        let root = URL(fileURLWithPath: directory)
        let output = root.appendingPathComponent("ui-tour", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let tools = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent("\($0)/inputs.txt").path) }
            .sorted()
        XCTAssertGreaterThan(tools.count, 50, "Run the AuditTests dump first")
        for tool in tools {
            let inputs = (try? String(contentsOf: root.appendingPathComponent("\(tool)/inputs.txt"), encoding: .utf8)) ?? ""
            let files = inputs.split(separator: "\n").joined(separator: ",")
            launch(["-MBRoute", "tool:\(tool)"] + (files.isEmpty ? [] : ["-MBInputs", files]))
            if !app.buttons["tool.run"].waitForExistence(timeout: 20) {
                XCTFail("\(tool): the tool screen never appeared")
            }
            // Let the live preview render.
            _ = app.staticTexts["tool.preview.caption"].waitForExistence(timeout: 8)
            Thread.sleep(forTimeInterval: 1)
            try app.screenshot().pngRepresentation.write(to: output.appendingPathComponent("\(tool).png"))
            app.terminate()
        }
    }
}
