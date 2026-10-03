import Foundation
import PDFKit
import ImageIO
import UniformTypeIdentifiers

@main struct ExtendedConversionTests {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "Hello conversion & <Unicode> café\nSecond paragraph\n"
        let source = root.appendingPathComponent("original.txt")
        try Data(text.utf8).write(to: source)
        var input = media(source, category: .document)
        for format in [OutputFormat.docx, .odt, .rtf, .html, .pdf, .markdown] {
            let result = try await DocumentConverter().convert(input: input, config: .init(outputFormat: format), progress: { _ in }, encodingStats: nil)
            defer { try? FileManager.default.removeItem(at: result.url) }
            if format == .docx {
                let page = try await DocumentConverter().convert(input: media(result.url, category: .document), config: .init(outputFormat: .jpg), progress: { _ in }, encodingStats: nil)
                defer { try? FileManager.default.removeItem(at: page.url) }
                precondition(CGImageSourceCreateWithURL(page.url as CFURL, nil) != nil, "Word page image is a readable JPEG")
            }
            if format == .pdf {
                guard let pdf = PDFDocument(url: result.url), pdf.pageCount == 1, pdf.string?.contains("Hello conversion") == true else { fatalError("PDF must contain searchable text") }
            }
            let roundtrip = try await DocumentConverter().convert(input: media(result.url, category: .document), config: .init(outputFormat: .txt), progress: { _ in }, encodingStats: nil)
            defer { try? FileManager.default.removeItem(at: roundtrip.url) }
            let output = try String(contentsOf: roundtrip.url, encoding: .utf8)
            precondition(output.contains("Hello conversion") && output.contains("café"), "\(format) must preserve text and Unicode")
        }
        let pdfResult = try await DocumentConverter().convert(input: media(source, category: .document), config: .init(outputFormat: .pdf), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: pdfResult.url) }
        let merged = try DocumentConverter().mergePDFs([pdfResult.url, pdfResult.url], progress: { _ in })
        defer { try? FileManager.default.removeItem(at: merged.url) }
        precondition(PDFDocument(url: merged.url)?.pageCount == 2, "PDF merge preserves all pages")
        var selected = ConversionConfig(outputFormat: .pdf)
        selected.document.pages = "2"; selected.document.rotation = .clockwise90
        let rotated = try await DocumentConverter().convert(input: media(merged.url, category: .document), config: selected, progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: rotated.url) }
        let rotatedPDF = PDFDocument(url: rotated.url)!
        precondition(rotatedPDF.pageCount == 1 && rotatedPDF.page(at: 0)!.bounds(for: .mediaBox).width == 792, "Selected pages and rotation are honored")
        let pageImages = try await DocumentConverter().convert(input: media(merged.url, category: .document), config: .init(outputFormat: .png), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: pageImages.url) }
        precondition(pageImages.outputFormat == .zip && pageImages.url.pathExtension == "zip", "Multiple page images must share as ZIP")
        let imageBytes = try FileArchive.read("page-1.png", from: pageImages.url)
        precondition(CGImageSourceCreateWithData(imageBytes as CFData, nil) != nil, "PDF page export produces actual images")
        let pageImage = try await DocumentConverter().convert(input: media(pdfResult.url, category: .document), config: .init(outputFormat: .png), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: pageImage.url) }
        let scanned = try await DocumentConverter().convert(input: media(pageImage.url, category: .image), config: .init(outputFormat: .pdf), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: scanned.url) }
        precondition(PDFDocument(url: scanned.url)?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false, "OCR fixture must have no text layer")
        var compressedConfig = ConversionConfig(outputFormat: .pdf); compressedConfig.document.compress = true
        let compressed = try await DocumentConverter().convert(input: media(pdfResult.url, category: .document), config: compressedConfig, progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: compressed.url) }
        precondition(PDFDocument(url: compressed.url)?.pageCount == 1, "Compressed PDF is readable")
        precondition(compressed.sizeOnDisk <= pdfResult.sizeOnDisk, "Compression must not enlarge an unchanged PDF")
        let recognized = try await DocumentConverter().convert(input: media(scanned.url, category: .document), config: .init(outputFormat: .txt), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: recognized.url) }
        let recognizedText = try String(contentsOf: recognized.url, encoding: .utf8)
        precondition(recognizedText.contains("Hello conversion"), "Scanned PDF OCR must recover actual text")
        let gzip = root.appendingPathComponent("original.gz")
        try FileArchive.deflateFile(source, to: gzip)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip"); process.arguments = ["-dc", gzip.path]
        let pipe = Pipe(); process.standardOutput = pipe; try process.run()
        let unzipped = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        precondition(process.terminationStatus == 0 && unzipped == Data(text.utf8), "Gzip interoperates with the system decoder")
        let indices = try DocumentConverter.pageIndices("3, 1-2, 2", count: 3)
        precondition(indices == [2,0,1], "Page order and deduplication")
        do { _ = try DocumentConverter.pageIndices("0-200000", count: 3); fatalError("Invalid pages accepted") } catch ConversionError.invalidInput { }
        let csv = root.appendingPathComponent("source.csv")
        try Data("name,notes\r\n\"café, one\",\"line 1\nline 2 and \"\"quotes\"\"\"\r\n".utf8).write(to: csv)
        input = media(csv, category: .data)
        let json = try await DataConverter().convert(input: input, config: .init(outputFormat: .json), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: json.url) }
        let objects = try JSONSerialization.jsonObject(with: Data(contentsOf: json.url)) as! [[String: String]]
        precondition(objects[0]["name"] == "café, one" && objects[0]["notes"] == "line 1\nline 2 and \"quotes\"")
        let tsv = try await DataConverter().convert(input: media(json.url, category: .data), config: .init(outputFormat: .tsv), progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: tsv.url) }
        let parsed = try DataConverter.parse(String(contentsOf: tsv.url, encoding: .utf8), delimiter: "\t")
        precondition(parsed[1].contains("café, one"))
        do { _ = try DataConverter.parse("a,b\n\"unclosed", delimiter: ","); fatalError("Malformed CSV accepted") } catch ConversionError.invalidInput { }
        let zip = root.appendingPathComponent("files.zip")
        try FileArchive.zip([.init(name: "original.txt", url: source)], to: zip)
        let restored = try FileArchive.read("original.txt", from: zip)
        precondition(restored == Data(text.utf8), "ZIP compression must preserve exact bytes")
        do { _ = try FileArchive.read("original.txt", from: zip, limit: 1); fatalError("Expansion limit ignored") } catch ConversionError.invalidInput { }
        do { try FileArchive.zip([.init(name: "../escape", url: source)], to: root.appendingPathComponent("bad.zip")); fatalError("Unsafe archive name accepted") } catch ConversionError.invalidInput { }
        let converter = DocumentConverter(); converter.cancel()
        do { _ = try await converter.convert(input: media(source, category: .document), config: .init(outputFormat: .pdf), progress: { _ in }, encodingStats: nil); fatalError("Cancelled conversion completed") } catch ConversionError.cancelled { }
        print("Document, data, ZIP and cancellation tests passed")
    }
    static func media(_ url: URL, category: MediaCategory) -> MediaFile {
        MediaFile(url: url, originalFilename: url.lastPathComponent, category: category,
                  sizeOnDisk: Int64((try? Data(contentsOf: url).count) ?? 0), containerFormat: url.pathExtension.lowercased())
    }
}
