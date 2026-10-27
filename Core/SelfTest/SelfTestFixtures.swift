#if SELF_TEST
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UIKit
import UniformTypeIdentifiers

/// Inputs for the self-test and the automated test suite: synthesized files (so tests know exactly
/// what's in them) plus real-world samples bundled in `App/SelfTestSamples`.
/// Shared by Settings → Diagnostics → Self-Test and `ConverterTests`, so both exercise the same thing.
enum SelfTestFixtures {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func require<T>(_ value: T?, _ message: String = "A fixture couldn't be created.") throws -> T {
        guard let value else { throw Failure(message) }
        return value
    }

    static var directory: URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SelfTest", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func tempURL(_ ext: String) -> URL {
        directory.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    static func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Bundled real-world samples

    static func sample(_ name: String) throws -> URL {
        guard let url = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "SelfTestSamples") else {
            throw Failure("Missing bundled sample \(name)")
        }
        // Work on a copy: tools may rename or delete their inputs' siblings.
        let copy = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let destination = copy.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    // MARK: Documents and images

    /// A PDF whose pages each say "Page N" (plus optional body text), for structural tests.
    /// With `picture`, page 1 also carries a photo with a transparent cut-out (embedded with an SMask).
    static func makePDF(pages: Int, size: CGSize = CGSize(width: 612, height: 792), body: String? = nil, picture: Bool = false, blankPage: Bool = false) -> PDFDocument {
        let photo = picture ? transparentPicture() : nil
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size)).pdfData { context in
            for index in 0 ..< pages {
                context.beginPage()
                let title = "Page \(index + 1)" as NSString
                title.draw(at: CGPoint(x: 72, y: 72), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
                if let body {
                    (body as NSString).draw(in: CGRect(x: 72, y: 130, width: size.width - 144, height: 200), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
                }
                if index == 0, let photo {
                    photo.draw(in: CGRect(x: 72, y: 360, width: 240, height: 180))
                }
            }
            if blankPage { context.beginPage() }
        }
        return PDFDocument(data: data)!
    }

    /// Orange and teal halves with a transparent circle punched out of the middle.
    static func transparentPicture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 240), format: format).image { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 160, height: 240))
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 160, y: 0, width: 160, height: 240))
            context.cgContext.setBlendMode(.clear)
            context.cgContext.fillEllipse(in: CGRect(x: 110, y: 70, width: 100, height: 100))
        }
    }

    /// Solid-color image with an optional colored square.
    static func makeImage(width: Int, height: Int, color: UIColor = .systemBlue, square: UIColor? = .white) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            if let square {
                square.setFill()
                context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 2))
            }
        }.cgImage!
    }

    static func writeImage(_ image: CGImage, format: ImageToolkit.OutputFormat = .png) throws -> URL {
        let url = tempURL(format.fileExtension)
        try ImageToolkit.encode(image, as: format).write(to: url)
        return url
    }

    /// Image containing rendered text, for OCR.
    static func textImage(_ text: String, size: CGSize = CGSize(width: 1200, height: 300)) -> CGImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            (text as NSString).draw(at: CGPoint(x: 40, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 72, weight: .semibold), .foregroundColor: UIColor.black])
        }.cgImage!
    }

    static let sampleDocument = RichDocument(
        metadata: DocumentMetadata(title: "Sample Title", author: "Grace Hopper"),
        blocks: [
            .heading(level: 1, runs: [Run("Sample Title")]),
            .paragraph(runs: [Run("Plain "), Run("bold", .bold), Run(" and "), Run("italic", .italic), Run(" with a "), Run("link", RunStyle(link: "https://example.com")), Run(".")]),
            .heading(level: 2, runs: [Run("Lists")]),
            .list(ordered: false, items: [
                [.paragraph(runs: [Run("Apples")])],
                [.paragraph(runs: [Run("Pears")]), .list(ordered: true, items: [[.paragraph(runs: [Run("Nested one")])], [.paragraph(runs: [Run("Nested two")])]])]
            ]),
            .table(TableBlock(textRows: [["Name", "Qty"], ["Bolts", "42"], ["Nuts & washers", "7"]], hasHeaderRow: true)),
            .quote([.paragraph(runs: [Run("To be or not to be.")])]),
            .code("let x = 1 < 2"),
            .paragraph(runs: [Run("Unicode: Ünïcödé — “quotes” 😀 & <tags>")])
        ]
    )

    /// Vector EPS artwork: a blue 200×120 pt card with white "Hello EPS" text and a black diagonal.
    /// The bounding box sits at (50, 40) so cropping to it is observable.
    static let epsArtwork = """
    %!PS-Adobe-3.0 EPSF-3.0
    %%BoundingBox: 50 40 250 160
    %%EndComments
    0.1 0.3 0.8 setrgbcolor 50 40 200 120 rectfill
    /Helvetica-Bold findfont 28 scalefont setfont
    1 1 1 setrgbcolor 64 85 moveto (Hello EPS) show
    0 0 0 setrgbcolor 4 setlinewidth 50 40 moveto 250 160 lineto stroke
    showpage
    %%EOF
    """

    /// A two-page US Letter PostScript document with searchable text on each page.
    static func postScriptDocument(pages: Int = 2) -> String {
        var text = "%!PS-Adobe-3.0\n%%Pages: \(pages)\n%%EndComments\n/Helvetica findfont 24 scalefont setfont\n"
        for page in 1 ... pages {
            text += "%%Page: \(page) \(page)\n<< /PageSize [612 792] >> setpagedevice\n"
            text += "0.8 0.1 0.1 setrgbcolor 72 600 200 100 rectfill\n0 0 0 setrgbcolor 72 700 moveto (PostScript page \(page)) show\nshowpage\n"
        }
        return text + "%%EOF\n"
    }

    /// A PDF whose cross-reference pointer is wrong and whose last 20 KB are missing, as from an
    /// interrupted download.
    static func damagedPDF() throws -> URL {
        let data = try Data(contentsOf: try sample("usgs-streamstats.pdf"))
        let cut = data.prefix(data.count - 20_000)
        let url = tempURL("pdf")
        try (cut + Data("\nstartxref\n12345\n%%EOF\n".utf8)).write(to: url)
        return url
    }

    /// The print-PDF case from the field: a CMYK JPEG (Adobe-inverted, with /Decode) plus a soft mask
    /// whose top-right quarter is transparent, drawn at (100, 400) sized 200×200.
    static func cmykMaskedPDF() throws -> Data {
        var pdf = RawPDF()
        let size = 64
        var mask = Data(repeating: 255, count: size * size)
        for row in 0 ..< size / 2 { for column in size / 2 ..< size { mask[row * size + column] = 0 } }
        let maskID = pdf.add(stream: "/Type /XObject /Subtype /Image /Width \(size) /Height \(size) /ColorSpace /DeviceGray /BitsPerComponent 8", mask)
        let jpeg = try RawPDF.cmykJPEG(width: size, height: size)
        let imageID = pdf.add(stream: "/Type /XObject /Subtype /Image /Width \(size) /Height \(size) /ColorSpace /DeviceCMYK /BitsPerComponent 8 /Decode [1 0 1 0 1 0 1 0] /Filter /DCTDecode /SMask \(maskID) 0 R", jpeg)
        return pdf.document(pages: [(content: "q 200 0 0 200 100 400 cm /Im0 Do Q", xObjects: ["Im0": imageID])])
    }
}

// MARK: - Raw PDF construction

struct RawPDF {
    private var objects: [Data] = []

    @discardableResult
    mutating func add(_ object: String) -> Int {
        objects.append(Data(object.utf8))
        return objects.count
    }

    @discardableResult
    mutating func add(stream dictionary: String, _ data: Data) -> Int {
        var body = Data("<< \(dictionary) /Length \(data.count) >>\nstream\n".utf8)
        body.append(data)
        body.append(Data("\nendstream".utf8))
        objects.append(body)
        return objects.count
    }

    /// Finishes a document with one page per (content, XObject map) pair.
    mutating func document(pages: [(content: String, xObjects: [String: Int])], size: CGSize = CGSize(width: 612, height: 792)) -> Data {
        let fontID = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let pagesID = objects.count + 1 + pages.count * 2
        var pageIDs: [Int] = []
        for page in pages {
            let contentID = add(stream: "", Data(page.content.utf8))
            let xObjects = page.xObjects.map { "/\($0.key) \($0.value) 0 R" }.joined(separator: " ")
            pageIDs.append(add("<< /Type /Page /Parent \(pagesID) 0 R /MediaBox [0 0 \(Int(size.width)) \(Int(size.height))] /Resources << /Font << /F1 \(fontID) 0 R >> /XObject << \(xObjects) >> >> /Contents \(contentID) 0 R >>"))
        }
        let actualPages = add("<< /Type /Pages /Kids [\(pageIDs.map { "\($0) 0 R" }.joined(separator: " "))] /Count \(pageIDs.count) >>")
        precondition(actualPages == pagesID)
        let root = add("<< /Type /Catalog /Pages \(pagesID) 0 R >>")
        var output = Data("%PDF-1.6\n".utf8)
        var offsets: [Int] = []
        for (index, body) in objects.enumerated() {
            offsets.append(output.count)
            output.append(Data("\(index + 1) 0 obj\n".utf8))
            output.append(body)
            output.append(Data("\nendobj\n".utf8))
        }
        let xref = output.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        output.append(Data(table.utf8))
        return output
    }

    /// A CMYK JPEG like Photoshop writes (Adobe APP14, inverted samples — PDFs pair these with
    /// `/Decode [1 0 1 0 1 0 1 0]`): left half pure green (C+Y), right half white.
    static func cmykJPEG(width: Int, height: Int) throws -> Data {
        let context = try SelfTestFixtures.require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpaceCreateDeviceCMYK(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [0, 0, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceCMYK(), components: [1, 0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        let image = try SelfTestFixtures.require(context.makeImage())
        let data = NSMutableData()
        let destination = try SelfTestFixtures.require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw SelfTestFixtures.Failure("Couldn't encode the CMYK JPEG.") }
        return data as Data
    }
}

/// Reads RGBA pixels (top-left origin) from encoded image data.
struct PixelProbe {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init(_ data: Data) throws {
        let source = try SelfTestFixtures.require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try SelfTestFixtures.require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let context = try SelfTestFixtures.require(CGContext(data: &buffer, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// (r, g, b, a) at a fractional position, x/y in 0…1 from the top-left.
    func at(_ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int, a: Int) {
        let px = min(width - 1, Int(x * Double(width)))
        let py = min(height - 1, Int(y * Double(height)))
        let index = (py * width + px) * 4
        let alpha = Int(bytes[index + 3])
        func unpremultiply(_ value: UInt8) -> Int { alpha == 0 ? 0 : min(255, Int(value) * 255 / alpha) }
        return (unpremultiply(bytes[index]), unpremultiply(bytes[index + 1]), unpremultiply(bytes[index + 2]), alpha)
    }
}


// MARK: - Media

extension SelfTestFixtures {
    static func video(seconds: Double = 2, withAudio: Bool = true, width: Int = 320, height: Int = 240) async throws -> URL {
        let url = SelfTestFixtures.tempURL("mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height
        ])
        writer.add(videoInput)
        var audioInput: AVAssetWriterInput?
        if withAudio {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
            ])
            input.expectsMediaDataInRealTime = false
            // Store audio as one block ahead of the video instead of interleaving: AVAssetWriter's
            // interleaving made slow (CI) simulators hold video back near the end of the clip forever.
            input.mediaDataLocation = .beforeMainMediaDataNotInterleaved
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.engineFailed("writer") }
        writer.startSession(atSourceTime: .zero)

        let fps = 15
        let frameCount = Int(seconds * Double(fps))
        if let audioInput {
            var sine = SineGenerator(frequency: 440, totalSamples: Int(seconds * 44_100))
            try await sine.append(to: audioInput, upTo: sine.totalSamples)
            audioInput.markAsFinished()
        }
        for frame in 0 ..< frameCount {
            // Fail loudly instead of hanging if the encoder never accepts another frame.
            var waited = 0
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
                waited += 1
                if waited > 5_000 { throw ConversionError.engineFailed("Video writer stalled at frame \(frame)") }
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            // A gradient with a moving bright square, so every frame has real picture content.
            let base = CVPixelBufferGetBaseAddress(pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
            let squareX = (frame * 8) % max(1, width - 40)
            for y in 0 ..< height {
                let row = base + y * stride
                for x in 0 ..< width {
                    let inSquare = x >= squareX && x < squareX + 40 && y >= height / 3 && y < height / 3 + 40
                    row[x * 4] = inSquare ? 255 : UInt8(x * 255 / max(1, width))      // B
                    row[x * 4 + 1] = inSquare ? 255 : UInt8(y * 255 / max(1, height)) // G
                    row[x * 4 + 2] = inSquare ? 255 : UInt8((frame * 9) % 255)       // R
                    row[x * 4 + 3] = 255
                }
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: CMTimeScale(fps)))
        }
        videoInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.engineFailed("writer") }
        return url
    }

    static func audio(seconds: Double = 2, frequency: Double = 440) async throws -> URL {
        let url = SelfTestFixtures.tempURL("m4a")
        let writer = try AVAssetWriter(url: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? ConversionError.engineFailed("writer") }
        writer.startSession(atSourceTime: .zero)
        var sine = SineGenerator(frequency: frequency, totalSamples: Int(seconds * 44_100))
        try await sine.append(to: input, upTo: sine.totalSamples)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.engineFailed("writer") }
        return url
    }
}

/// Streams a mono 16-bit sine wave into an AAC writer input in chunks.
struct SineGenerator {
    let frequency: Double
    let totalSamples: Int
    private(set) var written = 0
    private let sampleRate = 44_100
    private var format: CMAudioFormatDescription?

    init(frequency: Double, totalSamples: Int) {
        self.frequency = frequency
        self.totalSamples = totalSamples
        var description = AudioStreamBasicDescription(
            mSampleRate: 44_100, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }

    mutating func append(to input: AVAssetWriterInput, upTo limit: Int) async throws {
        while written < min(limit, totalSamples) {
            let count = min(4_096, min(limit, totalSamples) - written)
            var samples = [Int16](repeating: 0, count: count)
            for index in 0 ..< count {
                samples[index] = Int16(sin(2 * .pi * frequency * Double(written + index) / Double(sampleRate)) * 8_000)
            }
            var block: CMBlockBuffer?
            let byteCount = count * 2
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: byteCount) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: format!, sampleCount: count, presentationTimeStamp: CMTime(value: Int64(written), timescale: CMTimeScale(sampleRate)), packetDescriptions: nil, sampleBufferOut: &sample)
            var waited = 0
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(1))
                waited += 1
                if waited > 5_000 { throw ConversionError.engineFailed("Audio writer stalled") }
            }
            input.append(sample!)
            written += count
        }
    }
}
#endif
