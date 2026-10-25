import Foundation
import PDFKit
#if canImport(MBGhostscriptBridge)
import MBGhostscriptBridge
#endif

/// Ghostscript (AGPL), for what PDFKit can't do well: compressing and converting PDFs to grayscale
/// while keeping text and vectors, PDF/A, rebuilding damaged files, exporting EPS/PostScript, and
/// reading EPS, PostScript and Illustrator files.
///
/// Every job runs with -dSAFER, and the bridge refuses to start processes, so a document can't touch
/// files or run commands beyond the paths passed here.
enum Ghostscript {
    struct Failure: LocalizedError {
        let code: Int32
        let log: String

        var errorDescription: String? {
            let detail = log.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("****") || $0.localizedCaseInsensitiveContains("error") }
            return detail.map { "Ghostscript couldn't process the file: \($0.trimmingCharacters(in: CharacterSet(charactersIn: "* ")))" }
                ?? "Ghostscript couldn't process the file (error \(code))."
        }
    }

    static var isAvailable: Bool {
        #if canImport(MBGhostscriptBridge)
        true
        #else
        false
        #endif
    }

    static var version: String {
        #if canImport(MBGhostscriptBridge)
        String(cString: mbgs_version())
        #else
        ""
        #endif
    }

    /// Set from another thread to stop a running job.
    final class CancelFlag: @unchecked Sendable {
        fileprivate let storage = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        init() { storage.initialize(to: 0) }
        deinit { storage.deallocate() }
        func cancel() { storage.pointee = 1 }
    }

    private final class LogSink {
        var data = Data()
    }

    /// Runs one job and returns what Ghostscript printed. Files must be absolute paths.
    /// `quiet: false` keeps Ghostscript's report of problems it repaired in the input.
    static func run(_ arguments: [String], quiet: Bool = true, cancel: CancelFlag? = nil) throws -> String {
        #if canImport(MBGhostscriptBridge)
        let argv = ["gs", "-dSAFER", "-dBATCH", "-dNOPAUSE"] + (quiet ? ["-dQUIET"] : []) + arguments
        let sink = LogSink()
        let context = Unmanaged.passUnretained(sink).toOpaque()
        let pointers = argv.map { strdup($0) }
        defer { pointers.forEach { free($0) } }
        let code: Int32 = pointers.map { UnsafePointer($0) }.withUnsafeBufferPointer { buffer in
            withExtendedLifetime(sink) {
                mbgs_run(Int32(buffer.count), buffer.baseAddress, { context, text, length in
                    guard let context, let text, length > 0 else { return }
                    Unmanaged<LogSink>.fromOpaque(context).takeUnretainedValue().data.append(UnsafeRawPointer(text).assumingMemoryBound(to: UInt8.self), count: Int(length))
                }, context, cancel.map { UnsafePointer($0.storage) })
            }
        }
        let log = String(decoding: sink.data, as: UTF8.self)
        if code == MBGS_CANCELLED { throw CancellationError() }
        guard code == 0 else { throw Failure(code: code, log: log) }
        return log
        #else
        throw DocumentError.unsupportedFormat("Ghostscript isn't included in this build")
        #endif
    }

    /// Runs Ghostscript work off the main actor; cancelling the task stops the job.
    static func cancellable<T: Sendable>(_ work: @escaping @Sendable (CancelFlag) throws -> T) async throws -> T {
        let flag = CancelFlag()
        return try await withTaskCancellationHandler {
            try await background { try work(flag) }
        } onCancel: {
            flag.cancel()
        }
    }

    // MARK: - PDF output

    enum Quality: String, Sendable {
        /// 300 dpi images.
        case printer
        /// 150 dpi images.
        case ebook
        /// 72 dpi images.
        case screen
    }

    /// Lines Ghostscript prints when it produced a file but couldn't read the input.
    private static let fatalMarkers = ["No pages will be processed", "Couldn't initialise file", "Unrecoverable error"]

    /// Rewrites `input` with pdfwrite. Throws unless the result opens with at least one page.
    @discardableResult
    static func writePDF(_ input: URL, to output: URL, password: String? = nil, options: [String] = [], quiet: Bool = true, cancel: CancelFlag? = nil) throws -> String {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".gs-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var arguments = ["-sDEVICE=pdfwrite", "-dDetectDuplicateImages=true", "-sOutputFile=\(temporary.path)"]
        if let password, !password.isEmpty { arguments.append("-sPDFPassword=\(password)") }
        let log = try run(arguments + options + [input.path], quiet: quiet, cancel: cancel)
        guard let document = PDFDocument(url: temporary), document.pageCount > 0,
              !fatalMarkers.contains(where: log.contains) else {
            throw Failure(code: -1, log: log.isEmpty ? "**** The file couldn't be read." : log)
        }
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: temporary, to: output)
        return log
    }

    /// Smaller PDF with text, vectors and links kept; images are resampled to the quality's resolution.
    static func compress(_ input: URL, to output: URL, quality: Quality, password: String? = nil, cancel: CancelFlag? = nil) throws {
        try writePDF(input, to: output, password: password, options: [
            "-dPDFSETTINGS=/\(quality.rawValue)", "-sColorConversionStrategy=LeaveColorUnchanged", "-dCompatibilityLevel=1.6"
        ], cancel: cancel)
    }

    /// Converts every color to gray, keeping text and vectors.
    static func grayscale(_ input: URL, to output: URL, password: String? = nil, cancel: CancelFlag? = nil) throws {
        try writePDF(input, to: output, password: password, options: [
            "-sColorConversionStrategy=Gray", "-dProcessColorModel=/DeviceGray"
        ], cancel: cancel)
    }

    /// PDF/A-1b, 2b or 3b (archival): fonts embedded, an sRGB output intent and XMP identification.
    /// PDF/A-1 has no transparency, so pages that use it are flattened to images.
    static func pdfA(_ input: URL, to output: URL, part: Int = 2, password: String? = nil, cancel: CancelFlag? = nil) throws {
        precondition((1 ... 3).contains(part))
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pdfa-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // The output intent comes from a PostScript prologue (Ghostscript's PDFA_def.ps), using the
        // sRGB profile in Ghostscript's own ROM file system.
        let prologue = scratch.appendingPathComponent("pdfa_def.ps")
        try Data(pdfAPrologue.utf8).write(to: prologue)
        let source = try printableLinks(input, password: password, in: scratch) ?? input
        try writePDF(source, to: output, password: password, options: [
            "-dPDFA=\(part)", "-dPDFACompatibilityPolicy=1", "-sColorConversionStrategy=RGB", "-sBlendConversionStrategy=Simple",
            prologue.path
        ], cancel: cancel)
    }

    private static let pdfAPrologue = """
    %!
    [/_objdef {icc_PDFA} /type /stream /OBJ pdfmark
    [{icc_PDFA} << /N 3 >> /PUT pdfmark
    [{icc_PDFA} (%rom%iccprofiles/srgb.icc) (r) file /PUT pdfmark
    [/_objdef {OutputIntent_PDFA} /type /dict /OBJ pdfmark
    [{OutputIntent_PDFA} << /Type /OutputIntent /S /GTS_PDFA1 /DestOutputProfile {icc_PDFA}
      /OutputConditionIdentifier (sRGB) /Info (sRGB IEC61966-2.1) >> /PUT pdfmark
    [{Catalog} << /OutputIntents [ {OutputIntent_PDFA} ] >> /PUT pdfmark

    """

    /// PDF/A only keeps annotations marked printable. Links often have no flags at all (PDFKit still
    /// reports them printable), and Ghostscript would drop them, so documents with links go through
    /// a PDFKit copy, which writes the print flag. Returns nil when there are no links.
    private static func printableLinks(_ input: URL, password: String?, in directory: URL) throws -> URL? {
        guard let document = PDFDocument(url: input) else { return nil }
        if document.isLocked, !(password.map { document.unlock(withPassword: $0) } ?? false) { return nil }
        var links = 0
        for index in 0 ..< document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] where annotation.type == "Link" {
                annotation.shouldPrint = true
                links += 1
            }
        }
        guard links > 0 else { return nil }
        let url = directory.appendingPathComponent("links.pdf")
        return document.write(to: url) ? url : nil
    }

    struct RepairReport: Sendable {
        /// What Ghostscript had to fix, in its words; empty when the file was already sound.
        let problems: [String]
    }

    /// Rebuilds a PDF from whatever Ghostscript can recover: a new cross-reference table, streams
    /// and objects. Most "damaged file" errors in other apps go away.
    static func repair(_ input: URL, to output: URL, password: String? = nil, cancel: CancelFlag? = nil) throws -> RepairReport {
        let log = try writePDF(input, to: output, password: password, quiet: false, cancel: cancel)
        return RepairReport(problems: reportedProblems(in: log))
    }

    /// The tab-indented lines under "The following errors/warnings were encountered…".
    static func reportedProblems(in log: String) -> [String] {
        var problems: [String] = []
        var inSection = false
        for line in log.components(separatedBy: "\n") {
            if line.hasPrefix("The following errors") || line.hasPrefix("The following warnings") {
                inSection = true
            } else if inSection, line.hasPrefix("\t") {
                let text = line.trimmingCharacters(in: .whitespaces)
                if !text.isEmpty, !problems.contains(text) { problems.append(text) }
            } else {
                inSection = false
            }
        }
        if problems.isEmpty, log.contains("errors that were repaired or ignored") {
            problems.append("Structural errors were repaired")
        }
        return problems
    }

    // MARK: - PostScript

    /// EPS, PostScript or Illustrator → PDF. EPS and AI pages are cropped to their artwork.
    static func postScriptToPDF(_ input: URL, to output: URL, crop: Bool, cancel: CancelFlag? = nil) throws {
        try writePDF(input, to: output, options: crop ? ["-dEPSCrop"] : [], cancel: cancel)
    }

    enum PostScriptFlavor: String, Sendable {
        case eps = "eps2write"
        case ps = "ps2write"
    }

    /// PDF → PostScript (one file, every page) or EPS (one file per page), written into `directory`
    /// in page order. Transparency is flattened at 300 dpi, which keeps files a sensible size.
    static func export(_ input: URL, as flavor: PostScriptFlavor, into directory: URL, password: String? = nil, cancel: CancelFlag? = nil) throws -> [URL] {
        let folder = directory.appendingPathComponent(".gs-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pattern = flavor == .eps ? "page-%05d.eps" : "document.ps"
        var arguments = ["-sDEVICE=\(flavor.rawValue)", "-r300", "-sOutputFile=\(folder.path)/\(pattern)"]
        if let password, !password.isEmpty { arguments.append("-sPDFPassword=\(password)") }
        let log = try run(arguments + [input.path], cancel: cancel)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
            .filter { ((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty, !fatalMarkers.contains(where: log.contains) else { throw Failure(code: -1, log: log) }
        return try files.map { file in
            let destination = directory.appendingPathComponent("\(UUID().uuidString).\(file.pathExtension)")
            try FileManager.default.moveItem(at: file, to: destination)
            return destination
        }
    }

    /// Renders pages of a PDF, EPS, PostScript or AI file to PNG, one file per page, in page order.
    /// `transparent` keeps the background clear (artwork); otherwise pages are on white.
    static func renderPNG(_ input: URL, dpi: Int, transparent: Bool, crop: Bool, firstPage: Int? = nil, lastPage: Int? = nil,
                          into directory: URL, cancel: CancelFlag? = nil) throws -> [URL] {
        let folder = directory.appendingPathComponent(".gs-render-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var arguments = ["-sDEVICE=\(transparent ? "pngalpha" : "png16m")", "-r\(dpi)", "-dTextAlphaBits=4", "-dGraphicsAlphaBits=4",
                         "-sOutputFile=\(folder.path)/page-%05d.png"]
        if crop { arguments.append("-dEPSCrop") }
        if let firstPage { arguments.append("-dFirstPage=\(firstPage)") }
        if let lastPage { arguments.append("-dLastPage=\(lastPage)") }
        let log = try run(arguments + [input.path], cancel: cancel)
        let pages = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !pages.isEmpty, !fatalMarkers.contains(where: log.contains) else { throw Failure(code: -1, log: log) }
        return try pages.map { page in
            let destination = directory.appendingPathComponent("\(UUID().uuidString).png")
            try FileManager.default.moveItem(at: page, to: destination)
            return destination
        }
    }

    /// True for documents whose fillable form fields pdfwrite would drop.
    static func hasFormFields(_ document: PDFDocument) -> Bool {
        (0 ..< document.pageCount).contains { index in
            document.page(at: index)?.annotations.contains { $0.type == "Widget" } ?? false
        }
    }
}

/// Structural checks for archival PDFs.
enum PDFArchival {
    /// Names of fonts used on any page without an embedded font program (PDF/A forbids these).
    static func unembeddedFonts(in document: CGPDFDocument) -> [String] {
        var missing: Set<String> = []
        for index in 1 ... max(document.numberOfPages, 1) {
            guard let page = document.page(at: index)?.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            var fonts: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(page, "Resources", &resources), let resources,
                  CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { continue }
            CGPDFDictionaryApplyBlock(fonts, { _, object, info in
                var font: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &font), let font else { return true }
                if !PDFArchival.isEmbedded(font) {
                    var name: UnsafePointer<CChar>?
                    CGPDFDictionaryGetName(font, "BaseFont", &name)
                    info!.assumingMemoryBound(to: Set<String>.self).pointee.insert(name.map { String(cString: $0) } ?? "unnamed")
                }
                return true
            }, &missing)
        }
        return missing.sorted()
    }

    fileprivate static func isEmbedded(_ font: CGPDFDictionaryRef) -> Bool {
        var subtype: UnsafePointer<CChar>?
        CGPDFDictionaryGetName(font, "Subtype", &subtype)
        let kind = subtype.map { String(cString: $0) } ?? ""
        // Type 3 fonts are drawn with ordinary content operators: nothing to embed.
        if kind == "Type3" { return true }
        if kind == "Type0" {
            var descendants: CGPDFArrayRef?
            var descendant: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
                  CGPDFArrayGetDictionary(descendants, 0, &descendant), let descendant else { return false }
            return isEmbedded(descendant)
        }
        var descriptor: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(font, "FontDescriptor", &descriptor), let descriptor else { return false }
        var stream: CGPDFStreamRef?
        return CGPDFDictionaryGetStream(descriptor, "FontFile", &stream) || CGPDFDictionaryGetStream(descriptor, "FontFile2", &stream)
            || CGPDFDictionaryGetStream(descriptor, "FontFile3", &stream)
    }
}
