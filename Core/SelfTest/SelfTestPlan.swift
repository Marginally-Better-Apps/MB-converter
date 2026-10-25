#if SELF_TEST
import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// How each catalog tool is exercised: which input files, which option values a person would
/// type, and what its output must look like. Used by the in-app self-test and `ConverterTests`.
enum SelfTestPlan {
    /// Tools that need the network or an interactive hand-off are covered by UI tests instead.
    static let networkTools: Set<String> = ["util.webpdf", "util.webimage"]

    static var tools: [ToolDefinition] {
        ToolCatalog.all.filter { !$0.opensMediaConverter && !networkTools.contains($0.id.rawValue) }
    }

    /// Option values for tools whose defaults intentionally wait for user input.
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

    /// Tools that only work on hardware the simulator doesn't emulate. On a device they must pass.
    static let deviceOnlyTools: Set<String> = ["image.removebg", "image.blurfaces"]

    static func editorState(for tool: ToolDefinition) -> ToolEditorState {
        switch tool.editor {
        case .pdfMarkup:
            .overlays([PDFOverlayItem(pageIndex: 0, frame: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.05), kind: .text("Approved", fontSize: 14, colorHex: 0, bold: true))])
        case .imageCrop:
            .crop(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5))
        case .mediaRange:
            .range(start: 0.2, end: 1.0)
        default:
            .none
        }
    }

    @MainActor
    static func options(for tool: ToolDefinition, inputs: [ToolInputFile]) -> ToolOptionValues {
        var options = ToolOptionValues(defaults: tool.options)
        for option in tool.options {
            if case .dynamicChoice(let provider) = option.kind { options[option.key] = .string(provider(inputs).first?.value ?? "") }
        }
        for (key, value) in overrides[tool.id.rawValue] ?? [:] { options[key] = value }
        return options
    }

    // MARK: Inputs

    /// The files a person would plausibly hand this tool, using real samples where they matter.
    static func inputs(for tool: ToolDefinition) async throws -> [ToolInputFile] {
        switch tool.id.rawValue {
        case "image.blurfaces", "image.removebg":
            return [try ToolInputFile(url: try SelfTestFixtures.sample("astronaut-portrait.jpg"))]
        case "image.ocr":
            return [try ToolInputFile(url: try SelfTestFixtures.writeImage(SelfTestFixtures.textImage("Hello Converter")))]
        case "pdf.removeblank":
            let url = SelfTestFixtures.tempURL("pdf")
            try PDFToolkit.write(SelfTestFixtures.makePDF(pages: 2, body: "Quarterly numbers.", blankPage: true), to: url)
            return [try ToolInputFile(url: url)]
        case "image.animated":
            // `formats` is a set; pick the animated input explicitly rather than whichever comes first.
            return [try ToolInputFile(url: try await input(.gif))]
        case "pdf.extractimages":
            return [try ToolInputFile(url: try SelfTestFixtures.sample("usgs-streamstats.pdf"))]
        case "pdf.flatten":
            return [try ToolInputFile(url: try SelfTestFixtures.sample("irs-w4-form.pdf"))]
        case "video.addaudio":
            return [try ToolInputFile(url: try await input(.mp4)), try ToolInputFile(url: try await input(.m4a))]
        default:
            guard tool.input.acceptsFiles else { return [] }
            let format = try SelfTestFixtures.require(preferredOrder.first(where: tool.input.accepts) ?? tool.input.formats.first,
                                                      "\(tool.title) accepts no known input")
            var files: [ToolInputFile] = []
            for _ in 0 ..< max(tool.input.minCount, 1) {
                files.append(try ToolInputFile(url: try await input(format)))
            }
            return files
        }
    }

    static let preferredOrder: [FileFormat] = [.pdf, .docx, .xlsx, .csv, .png, .jpeg, .mp4, .m4a, .markdown, .json, .xml, .pptx, .odt, .ods, .rtf, .html, .txt, .epub, .svg, .zip]

    /// A real input file for any format a tool might need.
    static func input(_ format: FileFormat) async throws -> URL {
        switch format {
        case .pdf:
            let url = SelfTestFixtures.tempURL("pdf")
            try PDFToolkit.write(SelfTestFixtures.makePDF(pages: 3, body: "Quarterly numbers for Page review. Account 555-0100.", picture: true), to: url)
            return url
        case .docx, .odt, .rtf, .pptx, .xlsx, .ods:
            return try SelfTestFixtures.sample("sample.\(format.fileExtension)")
        case .markdown: return try write("# Notes\n\nSome **bold** text.\n\n- one\n- two\n", "md")
        case .txt: return try write("Plain text file.\n\nSecond paragraph.", "txt")
        case .html: return try write("<h1>Title</h1><p>Hello <b>web</b>.</p><table><tr><th>A</th></tr><tr><td>1</td></tr></table>", "html")
        case .csv: return try write("name,qty\nBolts,42\nNuts,7\n", "csv")
        case .tsv: return try write("name\tqty\nBolts\t42\n", "tsv")
        case .json: return try write(#"[{"name":"Bolts","qty":42},{"name":"Nuts","qty":7}]"#, "json")
        case .xml: return try write("<items><item><name>Bolts</name><qty>42</qty></item><item><name>Nuts</name><qty>7</qty></item></items>", "xml")
        case .svg: return try write(##"<svg xmlns="http://www.w3.org/2000/svg" width="120" height="80"><rect width="120" height="80" fill="#0b5fa5"/><circle cx="60" cy="40" r="20" fill="white"/></svg>"##, "svg")
        case .epub:
            let url = SelfTestFixtures.tempURL("epub")
            try EPUBWriter.write(SelfTestFixtures.sampleDocument, to: url)
            return url
        case .avif, .jxl, .jp2, .psd, .tga, .ico, .pnm, .pcx, .qoi, .dds, .sgi, .xpm, .hdr, .eps:
            let output = try SelfTestFixtures.require(ImageToolkit.OutputFormat(fileFormat: format))
            let url = SelfTestFixtures.tempURL(output.fileExtension)
            try ImageToolkit.encode(SelfTestFixtures.makeImage(width: 320, height: 240), as: output).write(to: url)
            return url
        case .png, .jpeg, .heic, .webp, .tiff, .bmp:
            return try SelfTestFixtures.writeImage(SelfTestFixtures.makeImage(width: 320, height: 240), format: ImageToolkit.OutputFormat(fileFormat: format) ?? .png)
        case .gif:
            let url = SelfTestFixtures.tempURL("gif")
            // A real animation: four differently colored frames.
            let frames = [UIColor.systemBlue, .systemOrange, .systemGreen, .systemPink].map { SelfTestFixtures.makeImage(width: 96, height: 96, color: $0) }
            try ImageToolkit.animatedGIF(frames, frameDelay: 0.1).write(to: url)
            return url
        case .mp4, .mov, .m4v, .mkv, .webm, .avi:
            return try await SelfTestFixtures.video(seconds: 1.5)
        case .mp3, .m4a, .wav, .aac, .flac, .ogg, .opus:
            return try await SelfTestFixtures.audio(seconds: 1.5)
        case .zip:
            return try ToolStorage.zip([try write("a", "txt"), try write("b", "txt")], named: "bundle", in: ToolStorage.newRunDirectory())
        }
    }

    private static func write(_ text: String, _ ext: String) throws -> URL {
        let url = SelfTestFixtures.tempURL(ext)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: Expectations

    /// A distinctive word from each text-bearing input that every text-bearing output should keep.
    static func textMarkers(for inputs: [ToolInputFile]) -> [String] {
        inputs.compactMap { input -> String? in
            let text: String
            switch input.format.family {
            case .spreadsheet:
                guard let workbook = try? SpreadsheetConverter.read(input.url, format: input.format) else { return nil }
                text = workbook.asDocument(includeSheetTitles: false).plainText
            case .pdf, .document, .presentation:
                guard let document = try? DocumentConverter.read(input.url, format: input.format) else { return nil }
                text = document.plainText
            default:
                return nil
            }
            return text.components(separatedBy: CharacterSet.letters.inverted).first { $0.count >= 5 }
        }
    }

    /// Runs a tool the way the tool screen does and checks everything it produced.
    /// Returns the problems found (empty = pass) and the output files.
    @MainActor
    static func check(_ tool: ToolDefinition) async throws -> (problems: [String], outputs: [URL], summary: String?) {
        let inputs = try await inputs(for: tool)
        let context = ToolContext(inputs: inputs, options: options(for: tool, inputs: inputs), editor: editorState(for: tool))
        let output = try await tool.run(context)
        var problems: [String] = []
        if output.files.isEmpty, output.text?.isEmpty ?? true { problems.append("produced no files") }

        let markers = textMarkers(for: inputs)
        var expectations = OutputValidator.Expectations()
        // One output per page/sheet: each word only has to survive somewhere in the set.
        expectations.text = output.files.count == 1 ? markers : []
        for file in output.files {
            if file.byteCount == 0 { problems.append("\(file.name) is empty") }
            problems += await OutputValidator.problems(in: file.url, expecting: expectations)
        }
        if output.files.count > 1 {
            let combined = output.files.compactMap { OutputValidator.text(of: $0.url) }.joined(separator: "\n").lowercased()
            if !combined.isEmpty {
                for marker in markers where !combined.contains(marker.lowercased()) {
                    problems.append("no output kept the text “\(marker)”")
                }
            }
        }
        problems += try specificProblems(tool, inputs: inputs, output: output)
        return (problems, output.files.map(\.url), output.summary)
    }

    /// Checks that only make sense for one tool: the output must show the tool actually did its job.
    private static func specificProblems(_ tool: ToolDefinition, inputs: [ToolInputFile], output: ToolOutput) throws -> [String] {
        func image(_ url: URL) throws -> CGImage { try ImageToolkit.load(url) }
        switch tool.id.rawValue {
        case "image.ocr":
            return (output.text ?? "").localizedCaseInsensitiveContains("Hello Converter") ? [] : ["recognized “\(output.text ?? "")” instead of “Hello Converter”"]
        case "image.removebg":
            guard let url = output.files.first?.url else { return ["no output"] }
            // The portrait's black studio corner must become transparent; the astronaut must stay.
            let pixels = try PixelProbe(try Data(contentsOf: url))
            var problems: [String] = []
            if pixels.at(0.03, 0.03).a > 40 { problems.append("background corner is still opaque (alpha \(pixels.at(0.03, 0.03).a))") }
            if pixels.at(0.6, 0.6).a < 200 { problems.append("the person was removed too (alpha \(pixels.at(0.6, 0.6).a))") }
            return problems
        case "image.blurfaces":
            guard let url = output.files.first?.url else { return ["no output"] }
            // The face (upper middle of the portrait) must change; the moon backdrop must not.
            let before = try image(inputs[0].url), after = try image(url)
            let face = CGRect(x: 0.5, y: 0.15, width: 0.2, height: 0.18)
            let faceChange = PixelDifference.mean(before, after, region: face)
            let backdropChange = PixelDifference.mean(before, after, region: CGRect(x: 0.05, y: 0.3, width: 0.15, height: 0.15))
            var problems: [String] = []
            if faceChange < 6 { problems.append("the face wasn't blurred (mean change \(Int(faceChange)))") }
            if backdropChange > 4 { problems.append("areas outside the face changed (mean change \(Int(backdropChange)))") }
            return problems
        case "pdf.removeblank":
            guard let url = output.files.first?.url, let pdf = PDFDocument(url: url) else { return ["no PDF"] }
            return pdf.pageCount == 2 ? [] : ["kept \(pdf.pageCount) pages; expected the blank one removed (2)"]
        case "pdf.extractimages":
            return output.files.count >= 2 ? [] : ["found \(output.files.count) pictures in the USGS report; expected its photo and map"]
        case "pdf.flatten":
            guard let url = output.files.first?.url, let pdf = PDFDocument(url: url) else { return ["no PDF"] }
            let widgets = (0 ..< pdf.pageCount).flatMap { pdf.page(at: $0)?.annotations ?? [] }.filter { $0.type == "Widget" }
            return widgets.isEmpty ? [] : ["\(widgets.count) form fields survived flattening"]
        case "pdf.redact":
            guard let url = output.files.first?.url, let text = PDFDocument(url: url)?.string else { return ["no PDF"] }
            return text.contains("555-0100") ? ["the redacted number is still in the text"] : []
        default:
            return []
        }
    }

    /// Whether a failure is the simulator lacking hardware rather than a bug.
    static func isSimulatorLimitation(_ tool: ToolDefinition) -> Bool {
        #if targetEnvironment(simulator)
        deviceOnlyTools.contains(tool.id.rawValue)
        #else
        false
        #endif
    }
}

/// Mean per-channel difference (0…255) between two same-size images within a normalized region.
enum PixelDifference {
    static func mean(_ a: CGImage, _ b: CGImage, region: CGRect, side: Int = 48) -> Double {
        func crop(_ image: CGImage) -> CGImage? {
            image.cropping(to: CGRect(x: region.minX * CGFloat(image.width), y: region.minY * CGFloat(image.height),
                                      width: region.width * CGFloat(image.width), height: region.height * CGFloat(image.height)).integral)
        }
        guard let ca = crop(a), let cb = crop(b) else { return 255 }
        let pa = ImageStats.pixels(ca, side: side), pb = ImageStats.pixels(cb, side: side)
        var total = 0.0
        for index in pa.indices where index % 4 != 3 { total += abs(Double(pa[index]) - Double(pb[index])) }
        return total / Double(side * side * 3)
    }
}
#endif
