import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Finds the images drawn on PDF pages, where they sit, and decodes them the way a PDF
/// viewer shows them.
///
/// Embedded image streams can't be saved as-is: print PDFs routinely use CMYK JPEGs,
/// ICC/Indexed color, `Decode` arrays and separate soft masks (`SMask`), so the raw bytes
/// look inverted, dark or boxed-in. Each image XObject is instead re-hosted in a one-image
/// PDF and rendered by Core Graphics at its native pixel size into sRGB with alpha.
enum PDFPageImages {
    struct DecodedImage: Sendable {
        let data: Data
        let fileExtension: String
        let mimeType: String
        let pixelSize: CGSize
        let hasAlpha: Bool
    }

    struct PlacedImage: Sendable {
        let pageIndex: Int
        /// Where the image is painted, in page space (PDF points, origin bottom-left).
        /// `nil` for images that are only reachable through resources (patterns, unused XObjects).
        let rect: CGRect?
        let image: DecodedImage
    }

    /// Images in painting order per page. The same image XObject drawn twice on a page is reported once.
    static func images(
        in document: PDFDocument,
        pages: [Int]? = nil,
        minimumSide: Int = 16,
        includeUnplaced: Bool = false
    ) -> [PlacedImage] {
        var results: [PlacedImage] = []
        var cache: [UnsafeRawPointer: DecodedImage?] = [:]
        func decoded(_ stream: CGPDFStreamRef) -> DecodedImage? {
            let key = identity(stream)
            if let cached = cache[key] { return cached }
            let image = decode(stream, minimumSide: minimumSide)
            cache[key] = image
            return image
        }
        for index in pages ?? Array(0 ..< document.pageCount) {
            guard let page = document.page(at: index)?.pageRef else { continue }
            var seenOnPage: Set<UnsafeRawPointer> = []
            for placement in placements(on: page) {
                let key = identity(placement.stream)
                guard !seenOnPage.contains(key), let image = autoreleasepool(invoking: { decoded(placement.stream) }) else { continue }
                seenOnPage.insert(key)
                results.append(PlacedImage(pageIndex: index, rect: placement.rect, image: image))
            }
            guard includeUnplaced, let dictionary = page.dictionary else { continue }
            var resources: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { continue }
            var streams: [CGPDFStreamRef] = []
            var visited: Set<UnsafeRawPointer> = []
            collectImageStreams(in: resources, depth: 0, visited: &visited, into: &streams)
            for stream in streams where !seenOnPage.contains(identity(stream)) {
                seenOnPage.insert(identity(stream))
                if let image = autoreleasepool(invoking: { decoded(stream) }) {
                    results.append(PlacedImage(pageIndex: index, rect: nil, image: image))
                }
            }
        }
        return results
    }

    // MARK: - Placement (content stream scan)

    struct Placement {
        let rect: CGRect
        let stream: CGPDFStreamRef
    }

    private final class ScanState {
        var ctm: CGAffineTransform = .identity
        var stack: [CGAffineTransform] = []
        var placements: [Placement] = []
        var formPath: [UnsafeRawPointer] = []
    }

    private static let operatorTable: CGPDFOperatorTableRef = {
        let table = CGPDFOperatorTableCreate()!
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            guard let state = info.map({ Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }) else { return }
            state.stack.append(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            guard let state = info.map({ Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }) else { return }
            if let last = state.stack.popLast() { state.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            guard let state = info.map({ Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var values = [CGPDFReal](repeating: 0, count: 6)
            for index in stride(from: 5, through: 0, by: -1) {
                guard CGPDFScannerPopNumber(scanner, &values[index]) else { return }
            }
            let matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
            state.ctm = matrix.concatenating(state.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
            guard let state = info.map({ Unmanaged<ScanState>.fromOpaque($0).takeUnretainedValue() }) else { return }
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let name,
                  let object = CGPDFContentStreamGetResource(CGPDFScannerGetContentStream(scanner), "XObject", name)
            else { return }
            var stream: CGPDFStreamRef?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let dictionary = CGPDFStreamGetDictionary(stream) else { return }
            var subtype: UnsafePointer<Int8>?
            guard CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype else { return }
            switch String(cString: subtype) {
            case "Image":
                var stencil: CGPDFBoolean = 0
                if CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &stencil), stencil != 0 { return }
                let rect = CGRect(x: 0, y: 0, width: 1, height: 1).applying(state.ctm)
                state.placements.append(Placement(rect: rect.standardized, stream: stream))
            case "Form":
                let key = identity(stream)
                guard state.formPath.count < 12, !state.formPath.contains(key) else { return }
                var matrix = CGAffineTransform.identity
                var array: CGPDFArrayRef?
                if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array, CGPDFArrayGetCount(array) == 6 {
                    var values = [CGPDFReal](repeating: 0, count: 6)
                    for index in 0 ..< 6 { CGPDFArrayGetNumber(array, index, &values[index]) }
                    matrix = CGAffineTransform(a: values[0], b: values[1], c: values[2], d: values[3], tx: values[4], ty: values[5])
                }
                var resources: CGPDFDictionaryRef?
                CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources)
                let parent = CGPDFScannerGetContentStream(scanner)
                let content = CGPDFContentStreamCreateWithStream(stream, resources ?? dictionary, parent)
                let saved = (state.ctm, state.stack)
                state.ctm = matrix.concatenating(state.ctm)
                state.stack = []
                state.formPath.append(key)
                let nested = CGPDFScannerCreate(content, operatorTable, info)
                CGPDFScannerScan(nested)
                CGPDFScannerRelease(nested)
                CGPDFContentStreamRelease(content)
                state.formPath.removeLast()
                (state.ctm, state.stack) = saved
            default:
                break
            }
        }
        return table
    }()

    static func placements(on page: CGPDFPage) -> [Placement] {
        let state = ScanState()
        let content = CGPDFContentStreamCreateWithPage(page)
        let scanner = CGPDFScannerCreate(content, operatorTable, Unmanaged.passUnretained(state).toOpaque())
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(content)
        return withExtendedLifetime(state) { state.placements }
    }

    /// Image XObjects reachable from a resource dictionary, including forms and tiling patterns.
    private static func collectImageStreams(in resources: CGPDFDictionaryRef, depth: Int, visited: inout Set<UnsafeRawPointer>, into streams: inout [CGPDFStreamRef]) {
        guard depth < 8 else { return }
        for category in ["XObject", "Pattern"] {
            var dictionary: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(resources, category, &dictionary), let dictionary else { continue }
            var found: [CGPDFStreamRef] = []
            withUnsafeMutablePointer(to: &found) { pointer in
                CGPDFDictionaryApplyBlock(dictionary, { _, object, info in
                    var stream: CGPDFStreamRef?
                    if CGPDFObjectGetValue(object, .stream, &stream), let stream {
                        info!.assumingMemoryBound(to: [CGPDFStreamRef].self).pointee.append(stream)
                    }
                    return true
                }, pointer)
            }
            for stream in found {
                let key = identity(stream)
                guard !visited.contains(key), let dictionary = CGPDFStreamGetDictionary(stream) else { continue }
                visited.insert(key)
                var subtype: UnsafePointer<Int8>?
                if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype, String(cString: subtype) == "Image" {
                    var stencil: CGPDFBoolean = 0
                    if !(CGPDFDictionaryGetBoolean(dictionary, "ImageMask", &stencil) && stencil != 0) { streams.append(stream) }
                    continue
                }
                var nested: CGPDFDictionaryRef?
                if CGPDFDictionaryGetDictionary(dictionary, "Resources", &nested), let nested {
                    collectImageStreams(in: nested, depth: depth + 1, visited: &visited, into: &streams)
                }
            }
        }
    }

    // MARK: - Decoding

    /// Images above this are rendered scaled down so a single huge scan can't exhaust memory.
    static let maximumPixels = 48_000_000

    static func decode(_ stream: CGPDFStreamRef, minimumSide: Int = 16) -> DecodedImage? {
        guard let dictionary = CGPDFStreamGetDictionary(stream) else { return nil }
        var width: CGPDFInteger = 0
        var height: CGPDFInteger = 0
        guard CGPDFDictionaryGetInteger(dictionary, "Width", &width), CGPDFDictionaryGetInteger(dictionary, "Height", &height),
              width > 0, height > 0, max(width, height) >= minimumSide
        else { return nil }

        var format = CGPDFDataFormat.raw
        guard let encoded = CGPDFStreamCopyData(stream, &format) as Data? else { return nil }
        let size = CGSize(width: width, height: height)

        // Plain RGB/gray JPEGs need no interpretation: keep the original bytes (no generation loss).
        if format == .jpegEncoded, isPassThroughJPEG(dictionary), jpegMatches(encoded, size: size) {
            return DecodedImage(data: encoded, fileExtension: "jpg", mimeType: "image/jpeg", pixelSize: size, hasAlpha: false)
        }

        guard let pdf = try? SingleImagePDF.make(stream: stream, data: encoded, format: format, size: size),
              let rendered = render(pdf: pdf, size: size)
        else { return nil }
        let renderedSize = CGSize(width: rendered.image.width, height: rendered.image.height)
        if rendered.hasAlpha || format == .raw {
            guard let png = PDFRasterizer.encode(rendered.image, type: .png) else { return nil }
            return DecodedImage(data: png, fileExtension: "png", mimeType: "image/png", pixelSize: renderedSize, hasAlpha: rendered.hasAlpha)
        }
        guard let jpeg = PDFRasterizer.encode(rendered.image, type: .jpeg, quality: 0.93) else { return nil }
        return DecodedImage(data: jpeg, fileExtension: "jpg", mimeType: "image/jpeg", pixelSize: renderedSize, hasAlpha: false)
    }

    private static func isPassThroughJPEG(_ dictionary: CGPDFDictionaryRef) -> Bool {
        for key in ["SMask", "Mask", "Decode"] {
            var object: CGPDFObjectRef?
            if CGPDFDictionaryGetObject(dictionary, key, &object) { return false }
        }
        var name: UnsafePointer<Int8>?
        if CGPDFDictionaryGetName(dictionary, "ColorSpace", &name), let name {
            return ["DeviceRGB", "DeviceGray"].contains(String(cString: name))
        }
        return false
    }

    /// Guards against JPEG streams whose own header disagrees with the PDF (rare, but then let CG decide).
    private static func jpegMatches(_ data: Data, size: CGSize) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              (properties[kCGImagePropertyColorModel] as? String).map({ $0 == "RGB" || $0 == "Gray" }) ?? false
        else { return false }
        return CGFloat(width) == size.width && CGFloat(height) == size.height
    }

    private static func render(pdf: Data, size: CGSize) -> (image: CGImage, hasAlpha: Bool)? {
        guard let provider = CGDataProvider(data: pdf as CFData), let document = CGPDFDocument(provider), let page = document.page(at: 1) else { return nil }
        let scale = min(1, (Double(maximumPixels) / Double(size.width * size.height)).squareRoot())
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        context.drawPDFPage(page)
        guard let buffer = context.data?.assumingMemoryBound(to: UInt8.self), let image = context.makeImage() else { return nil }
        var hasAlpha = false
        var anyVisible = false
        for index in stride(from: 3, to: width * height * 4, by: 4) {
            let alpha = buffer[index]
            if alpha < 255 { hasAlpha = true }
            if alpha > 0 { anyVisible = true }
            if hasAlpha && anyVisible { break }
        }
        // Nothing drawn means Core Graphics couldn't interpret the image; don't hand back a blank file.
        guard anyVisible else { return nil }
        return (image, hasAlpha)
    }
}

/// Stable identity for a stream within its document (CGPDF caches resolved objects).
private func identity(_ stream: CGPDFStreamRef) -> UnsafeRawPointer {
    unsafeBitCast(stream, to: UnsafeRawPointer.self)
}

// MARK: - One-image PDF

/// Serializes an image XObject (and everything it references: soft masks, ICC profiles,
/// lookup tables) into a minimal PDF whose single page paints it at its pixel size.
enum SingleImagePDF {
    enum Failure: Error { case unsupported }

    static func make(stream: CGPDFStreamRef, data: Data, format: CGPDFDataFormat, size: CGSize) throws -> Data {
        var writer = ObjectWriter()
        let image = try writer.image(stream, data: data, format: format)
        let content = Data("q \(number(size.width)) 0 0 \(number(size.height)) 0 0 cm /Im0 Do Q".utf8)
        let contentID = writer.add(stream: "<< /Length \(content.count) >>", data: content)
        let pageID = writer.reserve()
        let pagesID = writer.add(object: "<< /Type /Pages /Kids [\(pageID) 0 R] /Count 1 >>")
        writer.set(pageID, object: "<< /Type /Page /Parent \(pagesID) 0 R /MediaBox [0 0 \(number(size.width)) \(number(size.height))] /Resources << /XObject << /Im0 \(image) 0 R >> >> /Contents \(contentID) 0 R >>")
        let catalogID = writer.add(object: "<< /Type /Catalog /Pages \(pagesID) 0 R >>")
        return writer.document(root: catalogID)
    }

    fileprivate static func number(_ value: CGFloat) -> String { number(Double(value)) }

    fileprivate static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        var text = String(format: "%.6f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    private struct ObjectWriter {
        private var bodies: [Data?] = []
        private var streams: [UnsafeRawPointer: Int] = [:]
        private var budget = 400_000_000

        mutating func reserve() -> Int {
            bodies.append(nil)
            return bodies.count
        }

        mutating func set(_ id: Int, object: String) {
            bodies[id - 1] = Data(object.utf8)
        }

        mutating func add(object: String) -> Int {
            bodies.append(Data(object.utf8))
            return bodies.count
        }

        mutating func add(stream dictionary: String, data: Data) -> Int {
            var body = Data(dictionary.utf8)
            body.append(Data("\nstream\n".utf8))
            body.append(data)
            body.append(Data("\nendstream".utf8))
            bodies.append(body)
            return bodies.count
        }

        /// The image itself, whose encoded bytes were already copied by the caller.
        mutating func image(_ stream: CGPDFStreamRef, data: Data, format: CGPDFDataFormat) throws -> Int {
            let id = reserve()
            streams[identity(stream)] = id
            try fill(id, stream: stream, data: data, format: format)
            return id
        }

        private mutating func fill(_ id: Int, stream: CGPDFStreamRef, data: Data, format: CGPDFDataFormat) throws {
            budget -= data.count
            guard budget > 0, let dictionary = CGPDFStreamGetDictionary(stream) else { throw Failure.unsupported }
            var entries = try self.entries(of: dictionary, skipping: ["Length", "Filter", "DecodeParms", "F", "FFilter", "FDecodeParms", "DL"], depth: 0)
            switch format {
            case .jpegEncoded:
                entries.append("/Filter /DCTDecode")
                if let parameters = try dctParameters(dictionary) { entries.append("/DecodeParms \(parameters)") }
            case .JPEG2000:
                entries.append("/Filter /JPXDecode")
            default:
                break
            }
            entries.append("/Length \(data.count)")
            var body = Data("<< \(entries.joined(separator: " ")) >>\nstream\n".utf8)
            body.append(data)
            body.append(Data("\nendstream".utf8))
            bodies[id - 1] = body
        }

        /// DCTDecode's own parameters (ColorTransform) when the filter chain carries them.
        private mutating func dctParameters(_ dictionary: CGPDFDictionaryRef) throws -> String? {
            var filterName: UnsafePointer<Int8>?
            var parms: CGPDFObjectRef?
            guard CGPDFDictionaryGetObject(dictionary, "DecodeParms", &parms), let parms else { return nil }
            if CGPDFDictionaryGetName(dictionary, "Filter", &filterName), let filterName, String(cString: filterName) == "DCTDecode" {
                return CGPDFObjectGetType(parms) == .dictionary ? try value(parms, depth: 1) : nil
            }
            var filters: CGPDFArrayRef?
            var parmArray: CGPDFArrayRef?
            guard CGPDFDictionaryGetArray(dictionary, "Filter", &filters), let filters,
                  CGPDFObjectGetValue(parms, .array, &parmArray), let parmArray
            else { return nil }
            for index in 0 ..< CGPDFArrayGetCount(filters) {
                var name: UnsafePointer<Int8>?
                var entry: CGPDFObjectRef?
                if CGPDFArrayGetName(filters, index, &name), let name, String(cString: name) == "DCTDecode",
                   CGPDFArrayGetObject(parmArray, index, &entry), let entry, CGPDFObjectGetType(entry) == .dictionary {
                    return try value(entry, depth: 1)
                }
            }
            return nil
        }

        private mutating func entries(of dictionary: CGPDFDictionaryRef, skipping: Set<String>, depth: Int) throws -> [String] {
            var pairs: [(String, CGPDFObjectRef)] = []
            withUnsafeMutablePointer(to: &pairs) { pointer in
                CGPDFDictionaryApplyBlock(dictionary, { key, object, info in
                    info!.assumingMemoryBound(to: [(String, CGPDFObjectRef)].self).pointee.append((String(cString: key), object))
                    return true
                }, pointer)
            }
            var result: [String] = []
            for (key, object) in pairs.sorted(by: { $0.0 < $1.0 }) where !skipping.contains(key) {
                result.append("\(Self.name(key)) \(try value(object, depth: depth + 1))")
            }
            return result
        }

        private mutating func value(_ object: CGPDFObjectRef, depth: Int) throws -> String {
            guard depth < 16 else { throw Failure.unsupported }
            switch CGPDFObjectGetType(object) {
            case .null:
                return "null"
            case .boolean:
                var flag: CGPDFBoolean = 0
                CGPDFObjectGetValue(object, .boolean, &flag)
                return flag != 0 ? "true" : "false"
            case .integer:
                var integer: CGPDFInteger = 0
                CGPDFObjectGetValue(object, .integer, &integer)
                return String(integer)
            case .real:
                var real: CGPDFReal = 0
                CGPDFObjectGetValue(object, .real, &real)
                return SingleImagePDF.number(real)
            case .name:
                var name: UnsafePointer<Int8>?
                CGPDFObjectGetValue(object, .name, &name)
                return Self.name(name.map { String(cString: $0) } ?? "")
            case .string:
                var string: CGPDFStringRef?
                guard CGPDFObjectGetValue(object, .string, &string), let string, let bytes = CGPDFStringGetBytePtr(string) else { return "<>" }
                let buffer = UnsafeBufferPointer(start: bytes, count: CGPDFStringGetLength(string))
                return "<" + buffer.map { String(format: "%02X", $0) }.joined() + ">"
            case .array:
                var array: CGPDFArrayRef?
                guard CGPDFObjectGetValue(object, .array, &array), let array else { return "[]" }
                var items: [String] = []
                for index in 0 ..< CGPDFArrayGetCount(array) {
                    var item: CGPDFObjectRef?
                    guard CGPDFArrayGetObject(array, index, &item), let item else { items.append("null"); continue }
                    items.append(try value(item, depth: depth + 1))
                }
                return "[" + items.joined(separator: " ") + "]"
            case .dictionary:
                var dictionary: CGPDFDictionaryRef?
                guard CGPDFObjectGetValue(object, .dictionary, &dictionary), let dictionary else { return "<< >>" }
                return "<< " + (try entries(of: dictionary, skipping: [], depth: depth)).joined(separator: " ") + " >>"
            case .stream:
                var stream: CGPDFStreamRef?
                guard CGPDFObjectGetValue(object, .stream, &stream), let stream else { return "null" }
                let key = identity(stream)
                if let existing = streams[key] { return "\(existing) 0 R" }
                let id = reserve()
                streams[key] = id
                var format = CGPDFDataFormat.raw
                guard let data = CGPDFStreamCopyData(stream, &format) as Data? else { throw Failure.unsupported }
                try fill(id, stream: stream, data: data, format: format)
                return "\(id) 0 R"
            @unknown default:
                throw Failure.unsupported
            }
        }

        private static func name(_ raw: String) -> String {
            var result = "/"
            for byte in raw.utf8 {
                if byte > 0x20, byte < 0x7F, !"#()<>[]{}/%".utf8.contains(byte) {
                    result.append(Character(UnicodeScalar(byte)))
                } else {
                    result += String(format: "#%02X", byte)
                }
            }
            return result
        }

        func document(root: Int) -> Data {
            var output = Data("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
            var offsets: [Int] = []
            for (index, body) in bodies.enumerated() {
                offsets.append(output.count)
                output.append(Data("\(index + 1) 0 obj\n".utf8))
                output.append(body ?? Data("null".utf8))
                output.append(Data("\nendobj\n".utf8))
            }
            let xref = output.count
            var table = "xref\n0 \(bodies.count + 1)\n0000000000 65535 f \n"
            for offset in offsets { table += String(format: "%010d 00000 n \n", offset) }
            table += "trailer\n<< /Size \(bodies.count + 1) /Root \(root) 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
            output.append(Data(table.utf8))
            return output
        }
    }
}
