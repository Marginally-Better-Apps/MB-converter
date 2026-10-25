#if SELF_TEST
import AVFoundation
import Foundation
import Observation
import PDFKit
import UIKit
import VideoToolbox
import WebKit

/// One check the self-test runs: a catalog tool on real input, or a focused end-to-end check.
struct SelfTestCase: Identifiable, Sendable {
    enum Group: String, CaseIterable, Sendable {
        case tools = "Every Tool"
        case pdfFidelity = "PDF Fidelity"
        case media = "Video & Audio Engine"
        case device = "Device Features"
        case app = "App"
    }

    let id: String
    let title: String
    let group: Group
    let run: @MainActor @Sendable () async throws -> SelfTestCase.Outcome

    struct Outcome: Sendable {
        var problems: [String] = []
        var outputs: [URL] = []
        var note: String?
    }

    /// Thrown when a check can't run in this environment (e.g. Vision features on the simulator).
    struct Skip: Error, Sendable {
        let reason: String
    }
}

enum SelfTestStatus: Equatable, Sendable {
    case pending, running
    case passed(note: String?)
    case failed(problems: [String])
    case skipped(reason: String)

    var isFinished: Bool {
        switch self {
        case .pending, .running: false
        default: true
        }
    }
}

struct SelfTestResult: Identifiable, Sendable {
    let id: String
    var status: SelfTestStatus = .pending
    var duration: TimeInterval = 0
    var outputs: [URL] = []
}

/// Runs the checks one by one and keeps a shareable report. The same catalog runs in
/// `ConverterTests`, so what passes in CI is what this screen runs on a phone.
@MainActor
@Observable
final class SelfTestRunner {
    let cases: [SelfTestCase]
    private(set) var results: [String: SelfTestResult] = [:]
    private(set) var isRunning = false
    private(set) var startedAt: Date?
    private(set) var finishedAt: Date?
    private var task: Task<Void, Never>?

    init(cases: [SelfTestCase]? = nil) {
        self.cases = cases ?? SelfTestCatalog.all
        reset()
    }

    var completedCount: Int { results.values.filter { $0.status.isFinished }.count }
    var passedCount: Int { results.values.filter { if case .passed = $0.status { true } else { false } }.count }
    var failedCount: Int { results.values.filter { if case .failed = $0.status { true } else { false } }.count }
    var skippedCount: Int { results.values.filter { if case .skipped = $0.status { true } else { false } }.count }
    var progress: Double { cases.isEmpty ? 0 : Double(completedCount) / Double(cases.count) }

    func result(for id: String) -> SelfTestResult { results[id] ?? SelfTestResult(id: id) }

    func reset() {
        results = Dictionary(uniqueKeysWithValues: cases.map { ($0.id, SelfTestResult(id: $0.id)) })
        startedAt = nil
        finishedAt = nil
    }

    func start(only ids: Set<String>? = nil) {
        guard !isRunning else { return }
        reset()
        isRunning = true
        startedAt = Date()
        task = Task { [weak self] in
            guard let self else { return }
            for testCase in cases where ids?.contains(testCase.id) ?? true {
                if Task.isCancelled { break }
                await run(testCase)
            }
            isRunning = false
            finishedAt = Date()
        }
    }

    func cancel() {
        task?.cancel()
        isRunning = false
    }

    /// Runs one case and records its result. Also used directly by the test suite.
    @discardableResult
    func run(_ testCase: SelfTestCase) async -> SelfTestResult {
        results[testCase.id]?.status = .running
        let started = Date()
        var result = SelfTestResult(id: testCase.id)
        do {
            let outcome = try await testCase.run()
            result.outputs = outcome.outputs
            result.status = outcome.problems.isEmpty ? .passed(note: outcome.note) : .failed(problems: outcome.problems)
        } catch let skip as SelfTestCase.Skip {
            result.status = .skipped(reason: skip.reason)
        } catch {
            result.status = .failed(problems: [error.localizedDescription])
        }
        result.duration = Date().timeIntervalSince(started)
        results[testCase.id] = result
        return result
    }

    // MARK: Report

    var reportText: String {
        let device = UIDevice.current
        let info = Bundle.main.infoDictionary ?? [:]
        var lines = [
            "MB Converter self-test",
            "App \(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?")) · \(device.model) · \(device.systemName) \(device.systemVersion)\(Self.isSimulator ? " (Simulator)" : "")",
            "FFmpeg \(FFmpegRuntimeInfo.current.ffmpegVersion) · \(FFmpegRuntimeInfo.current.license) · ImageMagick \(Magick.version)",
            "Started \(startedAt?.formatted(date: .abbreviated, time: .standard) ?? "—") · \(passedCount) passed, \(failedCount) failed, \(skippedCount) skipped of \(cases.count)",
            ""
        ]
        for group in SelfTestCase.Group.allCases {
            let groupCases = cases.filter { $0.group == group }
            guard !groupCases.isEmpty else { continue }
            lines.append("## \(group.rawValue)")
            for testCase in groupCases {
                let result = result(for: testCase.id)
                let time = String(format: "%.1fs", result.duration)
                switch result.status {
                case .passed(let note): lines.append("PASS  \(testCase.title) · \(time)\(note.map { " · \($0)" } ?? "")")
                case .failed(let problems):
                    lines.append("FAIL  \(testCase.title) · \(time)")
                    lines += problems.map { "      ↳ \($0)" }
                case .skipped(let reason): lines.append("SKIP  \(testCase.title) · \(reason)")
                case .pending, .running: lines.append("—     \(testCase.title)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    static var isSimulator: Bool {
        #if targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }
}

// MARK: - Catalog

enum SelfTestCatalog {
    @MainActor
    static var all: [SelfTestCase] { toolCases + pdfFidelity + media + device + app }

    /// IDs of the focused (non-tool) checks, for parameterized tests.
    static var checkIDs: [String] { (pdfFidelity + media + device + app).map(\.id) }

    @MainActor
    static var toolCases: [SelfTestCase] {
        SelfTestPlan.tools.map { tool in
            SelfTestCase(id: "tool.\(tool.id.rawValue)", title: "\(tool.category.title): \(tool.title)", group: .tools) {
                do {
                    let result = try await SelfTestPlan.check(tool)
                    return SelfTestCase.Outcome(problems: result.problems, outputs: result.outputs, note: result.summary)
                } catch where SelfTestPlan.isSimulatorLimitation(tool) {
                    throw SelfTestCase.Skip(reason: "Needs a physical device (\(error.localizedDescription))")
                }
            }
        }
    }

    // MARK: PDF fidelity

    static let pdfFidelity: [SelfTestCase] = [
        SelfTestCase(id: "pdf.cmyk-mask", title: "CMYK JPEG with soft mask extracts as seen", group: .pdfFidelity) {
            let document = try SelfTestFixtures.require(PDFDocument(data: try SelfTestFixtures.cmykMaskedPDF()))
            let extracted = PDFImageExtractor.extract(document)
            guard let image = extracted.first else { return .init(problems: ["no image extracted"]) }
            let pixels = try PixelProbe(image.data)
            var problems: [String] = []
            let green = pixels.at(0.2, 0.75), white = pixels.at(0.8, 0.75), hole = pixels.at(0.8, 0.2)
            if !(green.g > 120 && green.r < 90) { problems.append("CMYK green came out \(green)") }
            if !(white.r > 225 && white.g > 225 && white.b > 225) { problems.append("CMYK white came out \(white)") }
            if hole.a != 0 { problems.append("masked corner isn't transparent (alpha \(hole.a))") }
            let url = SelfTestFixtures.tempURL(image.fileExtension)
            try image.data.write(to: url)
            return .init(problems: problems, outputs: [url])
        },
        SelfTestCase(id: "pdf.jpx-photos", title: "USGS report: CMYK JPEG 2000 photos extract", group: .pdfFidelity) {
            let url = try SelfTestFixtures.sample("usgs-streamstats.pdf")
            let document = try SelfTestFixtures.require(PDFDocument(url: url))
            let images = PDFImageExtractor.extract(document)
            var problems: [String] = images.count >= 2 ? [] : ["found \(images.count) images"]
            var outputs: [URL] = []
            for image in images {
                let file = SelfTestFixtures.tempURL(image.fileExtension)
                try image.data.write(to: file)
                outputs.append(file)
                problems += await OutputValidator.problems(in: file)
            }
            return .init(problems: problems, outputs: outputs, note: "\(images.count) images")
        },
        SelfTestCase(id: "pdf.redact-wrapped", title: "Redaction catches phrases wrapped across lines", group: .pdfFidelity) {
            let document = SelfTestFixtures.makePDF(pages: 1, size: CGSize(width: 260, height: 400), body: "The applicant’s account at East Carroll Parish office was closed.")
            let items = PDFStamper.redactionItems(for: ["applicant's account", "East Carroll Parish office"], in: document)
            let data = PDFStamper.apply(items, to: document)
            let text = (PDFDocument(data: data)?.string ?? "").lowercased()
            var problems: [String] = []
            if text.contains("applicant") { problems.append("curly-quote phrase survived") }
            if text.contains("carroll") { problems.append("wrapped phrase survived") }
            if !text.contains("closed") { problems.append("unredacted text was lost") }
            let url = SelfTestFixtures.tempURL("pdf")
            try data.write(to: url)
            return .init(problems: problems, outputs: [url])
        },
        SelfTestCase(id: "pdf.exact-html", title: "PDF → HTML exact copy looks like the page", group: .pdfFidelity) {
            let source = try SelfTestFixtures.sample("irs-w4-form.pdf")
            let document = try SelfTestFixtures.require(PDFDocument(url: source))
            let url = SelfTestFixtures.tempURL("html")
            try PDFHTMLExporter.write(document, to: url)
            let web = try await WebSnapshot.firstPage(of: url)
            let page = try SelfTestFixtures.require(PDFRasterizer.image(page: try SelfTestFixtures.require(document.page(at: 0)), dpi: 96))
            let difference = Look.difference(web, page)
            return .init(problems: difference < 12 ? [] : ["WebKit render differs from the PDF by \(Int(difference))"], outputs: [url],
                         note: "difference \(String(format: "%.1f", difference))")
        },
        SelfTestCase(id: "pdf.word-pictures", title: "PDF → Word keeps the report's pictures", group: .pdfFidelity) {
            let source = try SelfTestFixtures.sample("usgs-streamstats.pdf")
            let url = SelfTestFixtures.tempURL("docx")
            try await DocumentConverter.convert(input: source, from: .pdf, to: .docx, output: url)
            let back = try DocumentConverter.read(url, format: .docx)
            var problems: [String] = []
            if back.allImages.count < 2 { problems.append("kept \(back.allImages.count) pictures") }
            if !back.plainText.contains("StreamStats") { problems.append("lost the text “StreamStats”") }
            return .init(problems: problems, outputs: [url], note: "\(back.allImages.count) pictures")
        }
    ]

    // MARK: Media engine

    static let media: [SelfTestCase] = [
        videoCase("video.h264", "H.264 MP4 (VideoToolbox)", .mp4_h264),
        videoCase("video.hevc", "HEVC MP4 (VideoToolbox)", .mp4_hevc),
        videoCase("video.webm", "WebM (VP9 + Opus)", .webm),
        videoCase("video.av1", "AV1 MP4 (SVT-AV1)", .mp4_av1),
        SelfTestCase(id: "video.target-size", title: "H.264 target size lands within 12% (x264 two-pass)", group: .media) {
            let source = try await SelfTestFixtures.video(seconds: 6, width: 640, height: 360)
            let media = try await MediaInspector.inspect(url: source)
            let target: Int64 = 260_000
            let config = ConversionConfig(outputFormat: .mp4_h264, targetSizeBytes: target)
            guard config.usesTwoPassVideoEncoding else { return .init(problems: ["two-pass H.264 isn't available in this runtime"]) }
            let result = try await VideoConverter().convert(input: media, config: config, progress: { _ in })
            let error = abs(Double(result.sizeOnDisk - target)) / Double(target)
            return .init(problems: error < 0.12 ? [] : ["\(result.sizeOnDisk) bytes for a \(target)-byte target (\(Int(error * 100))% off)"],
                         outputs: [result.url], note: "\(result.sizeOnDisk / 1000) KB for 260 KB")
        },
        audioCase("audio.mp3", "MP3", .mp3),
        audioCase("audio.aac", "AAC (M4A)", .m4a),
        audioCase("audio.flac", "FLAC", .flac),
        audioCase("audio.opus", "Opus", .opus),
        SelfTestCase(id: "video.real-clip", title: "Real H.264/AAC clip converts to MOV", group: .media) {
            let media = try await MediaInspector.inspect(url: try SelfTestFixtures.sample("test-pattern.mp4"))
            let result = try await VideoConverter().convert(input: media, config: ConversionConfig(outputFormat: .mov), progress: { _ in })
            return .init(problems: await OutputValidator.problems(in: result.url), outputs: [result.url])
        }
    ]

    private static func videoCase(_ id: String, _ title: String, _ format: OutputFormat) -> SelfTestCase {
        SelfTestCase(id: id, title: title, group: .media) {
            guard CodecCapability.canEncode(format) else { return .init(problems: ["\(format.displayName) encoder isn't in this runtime"]) }
            let media = try await MediaInspector.inspect(url: try await SelfTestFixtures.video(seconds: 2))
            let result = try await VideoConverter().convert(input: media, config: ConversionConfig(outputFormat: format), progress: { _ in })
            var problems = await OutputValidator.problems(in: result.url)
            if !((result.duration ?? 0) > 1.5) { problems.append("duration \(result.duration ?? 0)s, expected about 2s") }
            return .init(problems: problems, outputs: [result.url], note: [result.videoCodec, result.audioCodec].compactMap { $0 }.joined(separator: " + "))
        }
    }

    private static func audioCase(_ id: String, _ title: String, _ format: OutputFormat) -> SelfTestCase {
        SelfTestCase(id: id, title: title, group: .media) {
            let media = try await MediaInspector.inspect(url: try await SelfTestFixtures.audio(seconds: 2))
            let result = try await AudioConverter().convert(input: media, config: ConversionConfig(outputFormat: format), progress: { _ in }, encodingStats: nil)
            var problems = await OutputValidator.problems(in: result.url)
            if !((result.duration ?? 0) > 1.5) { problems.append("duration \(result.duration ?? 0)s, expected about 2s") }
            return .init(problems: problems, outputs: [result.url], note: result.audioCodec)
        }
    }

    // MARK: Device features

    static let device: [SelfTestCase] = [
        SelfTestCase(id: "device.vision-text", title: "Vision reads text (Live Text engine)", group: .device) {
            let lines = try TextRecognizer.recognize(SelfTestFixtures.textImage("Hello Converter"), languages: ["en-US"])
            let text = TextRecognizer.text(from: lines)
            return .init(problems: text.contains("Hello Converter") ? [] : ["read “\(text)”"])
        },
        SelfTestCase(id: "device.hardware-hevc", title: "Hardware HEVC encoder is available", group: .device) {
            guard !SelfTestRunner.isSimulator else { throw SelfTestCase.Skip(reason: "The simulator has no media engine") }
            return .init(problems: VideoToolboxSupport.hasHardwareHEVCEncoder ? [] : ["VideoToolbox reports no hardware HEVC encoder"])
        }
    ]

    // MARK: App

    static let app: [SelfTestCase] = [
        SelfTestCase(id: "app.history", title: "Tool results are recorded in History", group: .app) {
            let tool = try SelfTestFixtures.require(ToolCatalog.tool("pdf.reverse"))
            let model = ToolViewModel(tool: tool, inputs: try await SelfTestPlan.inputs(for: tool))
            guard let run = await model.run() else { return .init(problems: [model.errorMessage ?? "the tool failed"]) }
            defer { ConversionHistoryStore.shared.removeEntry(id: run.id) }
            guard let entry = ConversionHistoryStore.shared.toolEntry(withId: run.id) else { return .init(problems: ["no History entry"]) }
            var problems: [String] = []
            if entry.files.isEmpty || !entry.files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) { problems.append("History has no copy of the result") }
            if !ConversionHistoryStore.shared.items.contains(where: { $0.id == run.id }) { problems.append("the entry isn't listed") }
            return .init(problems: problems)
        },
        SelfTestCase(id: "app.preview-standins", title: "Results Quick Look can't show get a readable preview", group: .app) {
            let odt = SelfTestFixtures.tempURL("odt")
            try ODTWriter.write(SelfTestFixtures.sampleDocument, options: .default, to: odt)
            let item = QuickLookStandIn.item(for: odt)
            guard let standIn = item.previewItemURL ?? nil else { return .init(problems: ["no stand-in"]) }
            let html = (try? String(contentsOf: standIn, encoding: .utf8)) ?? ""
            return .init(problems: html.contains("Sample Title") ? [] : ["stand-in doesn't contain the document"], outputs: [standIn])
        }
    ]
}

// MARK: - Helpers

enum VideoToolboxSupport {
    /// Asks VideoToolbox for an HEVC encoder that must be hardware accelerated.
    static var hasHardwareHEVCEncoder: Bool {
        guard #available(iOS 17.4, *) else { return true }
        let specification = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true] as CFDictionary
        var encoderID: CFString?
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(width: 1920, height: 1080, codecType: kCMVideoCodecType_HEVC,
                                                                 encoderSpecification: specification, encoderIDOut: &encoderID,
                                                                 supportedPropertiesOut: &properties)
        return status == noErr
    }
}

/// Perceptual comparison: mean per-channel difference (0…255) at a small common size, on white.
enum Look {
    static func difference(_ a: CGImage, _ b: CGImage, side: Int = 96) -> Double {
        let pa = ImageStats.pixels(a, side: side), pb = ImageStats.pixels(b, side: side)
        var total = 0.0
        for index in pa.indices where index % 4 != 3 { total += abs(Double(pa[index]) - Double(pb[index])) }
        return total / Double(side * side * 3)
    }
}

/// Renders an HTML file in WebKit and captures the first `.page` section.
@MainActor
enum WebSnapshot {
    static func firstPage(of url: URL, width: CGFloat = 840) async throws -> CGImage {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: 1200))
        let delegate = LoadDelegate()
        view.navigationDelegate = delegate
        view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        try await delegate.finished()
        try await Task.sleep(for: .milliseconds(300))
        let frame = try await view.evaluateJavaScript(
            "(() => { const r = document.querySelector('.page').getBoundingClientRect(); return [r.x, r.y, r.width, r.height]; })()"
        ) as? [Double] ?? []
        guard frame.count == 4 else { throw SelfTestFixtures.Failure("No page in the HTML") }
        view.frame.size.height = max(1200, frame[1] + frame[3] + 20)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])
        let image = try await view.takeSnapshot(configuration: configuration)
        return try SelfTestFixtures.require(image.cgImage)
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Error>?
        private var done = false

        func finished() async throws {
            if done { return }
            try await withCheckedThrowingContinuation { self.continuation = $0 }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            done = true
            continuation?.resume(throwing: error)
            continuation = nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            self.webView(webView, didFail: navigation, withError: error)
        }
    }
}
#endif
