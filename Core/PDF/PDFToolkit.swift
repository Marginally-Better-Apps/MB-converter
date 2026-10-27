import CoreGraphics
import Foundation
import PDFKit
import UIKit

/// Structural PDF operations: everything that rearranges pages or document properties
/// without re-rendering page content.
enum PDFToolkit {
    // MARK: - Opening & saving

    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw DocumentError.unreadable("“\(url.lastPathComponent)” isn't a readable PDF.")
        }
        if document.isLocked {
            guard let password, !password.isEmpty else { throw DocumentError.passwordRequired }
            guard document.unlock(withPassword: password) else { throw DocumentError.wrongPassword }
        }
        return document
    }

    static func write(_ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        try? FileManager.default.removeItem(at: url)
        guard document.write(to: url, withOptions: options) else {
            throw DocumentError.writeFailed("PDFKit couldn't save the document.")
        }
    }

    /// Copies pages into a fresh, unencrypted document. Copying (rather than moving)
    /// keeps the source intact and strips encryption from unlocked inputs.
    static func document(from source: PDFDocument, pageIndices: [Int]) -> PDFDocument {
        let output = PDFDocument()
        for index in pageIndices {
            guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
            output.insert(page, at: output.pageCount)
        }
        copyAttributes(from: source, to: output)
        return output
    }

    static func copyAttributes(from source: PDFDocument, to destination: PDFDocument) {
        guard var attributes = source.documentAttributes else { return }
        attributes[PDFDocumentAttribute.modificationDateAttribute] = Date()
        destination.documentAttributes = attributes
    }

    // MARK: - Page operations

    static func merge(_ documents: [PDFDocument]) -> PDFDocument {
        let output = PDFDocument()
        for document in documents {
            for index in 0 ..< document.pageCount {
                if let page = document.page(at: index)?.copy() as? PDFPage {
                    output.insert(page, at: output.pageCount)
                }
            }
        }
        if let first = documents.first { copyAttributes(from: first, to: output) }
        return output
    }

    enum SplitMode: Hashable {
        /// One output per comma-separated group, e.g. "1-3, 4-6".
        case ranges(String)
        case everyNPages(Int)
        case eachPage
        /// Splits into chunks no larger than this many bytes (approximate).
        case maxFileSize(bytes: Int64)
        /// A new file begins at each of these pages (0-based); the first file always starts at page 0.
        case startingAt([Int])

        /// The 1-based page ranges a set of tapped starting pages makes, e.g. [2, 5] of 8 → "1-2, 3-5, 6-8".
        static func ranges(startingAt starts: [Int], pageCount: Int) -> String {
            let bounds = [0] + Set(starts).filter { $0 > 0 && $0 < pageCount }.sorted() + [pageCount]
            return zip(bounds, bounds.dropFirst()).map { start, end in
                end - start == 1 ? "\(start + 1)" : "\(start + 1)-\(end)"
            }.joined(separator: ", ")
        }
    }

    static func split(_ source: PDFDocument, mode: SplitMode) throws -> [PDFDocument] {
        let count = source.pageCount
        guard count > 0 else { throw DocumentError.empty("The PDF has no pages.") }
        switch mode {
        case .ranges(let text):
            return try PageRangeParser.parseGroups(text, pageCount: count).map { document(from: source, pageIndices: $0) }
        case .everyNPages(let n):
            guard n > 0 else { throw DocumentError.invalidOption("Choose at least 1 page per file.") }
            return stride(from: 0, to: count, by: n).map { start in
                document(from: source, pageIndices: Array(start ..< min(start + n, count)))
            }
        case .eachPage:
            return (0 ..< count).map { document(from: source, pageIndices: [$0]) }
        case .startingAt(let starts):
            return try split(source, mode: .ranges(SplitMode.ranges(startingAt: starts, pageCount: count)))
        case .maxFileSize(let limit):
            guard limit > 0 else { throw DocumentError.invalidOption("Choose a size limit above zero.") }
            var outputs: [PDFDocument] = []
            var current: [Int] = []
            for index in 0 ..< count {
                let candidate = current + [index]
                let size = document(from: source, pageIndices: candidate).dataRepresentation()?.count ?? 0
                if Int64(size) > limit, !current.isEmpty {
                    outputs.append(document(from: source, pageIndices: current))
                    current = [index]
                } else {
                    current = candidate
                }
            }
            if !current.isEmpty { outputs.append(document(from: source, pageIndices: current)) }
            return outputs
        }
    }

    /// A single page in an organized output: an existing page (with extra rotation) or a blank page.
    struct PageEdit: Hashable, Identifiable, Sendable {
        let id: UUID
        /// Index into the source document, or nil for an inserted blank page.
        var sourceIndex: Int?
        /// Additional clockwise rotation in degrees (multiple of 90).
        var rotation: Int

        init(id: UUID = UUID(), sourceIndex: Int?, rotation: Int = 0) {
            self.id = id
            self.sourceIndex = sourceIndex
            self.rotation = rotation
        }

        static func identity(pageCount: Int) -> [PageEdit] {
            (0 ..< pageCount).map { PageEdit(sourceIndex: $0) }
        }
    }

    static func organize(_ source: PDFDocument, edits: [PageEdit]) throws -> PDFDocument {
        guard !edits.isEmpty else { throw DocumentError.invalidOption("Keep at least one page.") }
        let output = PDFDocument()
        let fallbackSize = source.page(at: 0).map { PDFRasterizer.displaySize(of: $0) } ?? PageSize.regionalDefault.points
        for edit in edits {
            let page: PDFPage
            if let sourceIndex = edit.sourceIndex {
                guard let copy = source.page(at: sourceIndex)?.copy() as? PDFPage else { continue }
                page = copy
            } else {
                page = blankPage(size: fallbackSize)
            }
            page.rotation = normalizedRotation(page.rotation + edit.rotation)
            output.insert(page, at: output.pageCount)
        }
        copyAttributes(from: source, to: output)
        return output
    }

    static func blankPage(size: CGSize) -> PDFPage {
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: size), for: .mediaBox)
        page.setBounds(CGRect(origin: .zero, size: size), for: .cropBox)
        return page
    }

    static func normalizedRotation(_ degrees: Int) -> Int {
        let snapped = Int((Double(degrees) / 90).rounded()) * 90
        return ((snapped % 360) + 360) % 360
    }

    static func rotate(_ source: PDFDocument, by degrees: Int, pages: Set<Int>? = nil) -> PDFDocument {
        let edits = (0 ..< source.pageCount).map { index in
            PageEdit(sourceIndex: index, rotation: pages == nil || pages!.contains(index) ? degrees : 0)
        }
        return (try? organize(source, edits: edits)) ?? source
    }

    static func deletePages(_ source: PDFDocument, remove: Set<Int>) throws -> PDFDocument {
        let keep = (0 ..< source.pageCount).filter { !remove.contains($0) }
        guard !keep.isEmpty else { throw DocumentError.invalidOption("You can't delete every page.") }
        return document(from: source, pageIndices: keep)
    }

    static func reverse(_ source: PDFDocument) -> PDFDocument {
        document(from: source, pageIndices: Array((0 ..< source.pageCount).reversed()))
    }

    /// Pages whose rendered content is (nearly) all white.
    static func blankPageIndices(_ source: PDFDocument, threshold: Double = 0.995) -> Set<Int> {
        var result: Set<Int> = []
        for index in 0 ..< source.pageCount {
            guard let page = source.page(at: index) else { continue }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard text.isEmpty, (page.annotations.isEmpty) else { continue }
            guard let image = PDFRasterizer.image(page: page, dpi: 24, grayscale: true) else { continue }
            if whiteFraction(image) >= threshold { result.insert(index) }
        }
        return result
    }

    private static func whiteFraction(_ image: CGImage) -> Double {
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let white = pixels.filter { $0 > 245 }.count
        return Double(white) / Double(max(pixels.count, 1))
    }

    // MARK: - Crop

    struct CropInsets: Hashable, Sendable {
        var top: CGFloat
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat

        static func uniform(_ value: CGFloat) -> CropInsets {
            CropInsets(top: value, left: value, bottom: value, right: value)
        }
    }

    /// Adjusts the crop box (non-destructive; content outside remains in the file).
    static func crop(_ source: PDFDocument, insets: CropInsets, pages: Set<Int>? = nil) throws -> PDFDocument {
        let output = document(from: source, pageIndices: Array(0 ..< source.pageCount))
        for index in 0 ..< output.pageCount where pages == nil || pages!.contains(index) {
            guard let page = output.page(at: index) else { continue }
            let box = page.bounds(for: .cropBox)
            let cropped = CGRect(
                x: box.minX + insets.left,
                y: box.minY + insets.bottom,
                width: box.width - insets.left - insets.right,
                height: box.height - insets.top - insets.bottom
            )
            guard cropped.width >= 36, cropped.height >= 36 else {
                throw DocumentError.invalidOption("Those margins would crop page \(index + 1) away entirely.")
            }
            page.setBounds(cropped, for: .cropBox)
        }
        return output
    }

    /// Finds the bounding box of visible content (for auto-trim of whitespace).
    static func contentBounds(of page: PDFPage) -> CGRect? {
        let box = page.bounds(for: .cropBox)
        guard page.rotation == 0, let image = PDFRasterizer.image(page: page, dpi: 50, grayscale: true) else { return nil }
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 255, count: width * height)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0 ..< height {
            for x in 0 ..< width where pixels[y * width + x] < 235 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let scaleX = box.width / CGFloat(width)
        let scaleY = box.height / CGFloat(height)
        // Bitmap rows run top-down in memory.
        return CGRect(
            x: box.minX + CGFloat(minX) * scaleX,
            y: box.minY + CGFloat(height - 1 - maxY) * scaleY,
            width: CGFloat(maxX - minX + 1) * scaleX,
            height: CGFloat(maxY - minY + 1) * scaleY
        )
    }

    /// Trims empty margins on `pages` (nil = every page).
    static func autoTrim(_ source: PDFDocument, pages: Set<Int>? = nil, padding: CGFloat = 18) -> PDFDocument {
        let output = document(from: source, pageIndices: Array(0 ..< source.pageCount))
        for index in 0 ..< output.pageCount where pages?.contains(index) ?? true {
            guard let page = output.page(at: index), let content = contentBounds(of: page) else { continue }
            let box = page.bounds(for: .cropBox)
            let padded = content.insetBy(dx: -padding, dy: -padding).intersection(box)
            if padded.width >= 36, padded.height >= 36 { page.setBounds(padded, for: .cropBox) }
        }
        return output
    }

    // MARK: - Security

    struct Permissions: Hashable, Sendable {
        var allowPrinting = true
        var allowCopying = true
        var allowEditing = true

        /// Bitmask matching `PDFAccessPermissions` (an NS_ENUM, so combined manually).
        var rawValue: UInt {
            var bits: UInt = 1 << 5 // accessibility extraction is always allowed
            if allowPrinting { bits |= (1 << 0) | (1 << 1) }
            if allowCopying { bits |= 1 << 4 }
            if allowEditing { bits |= (1 << 2) | (1 << 3) | (1 << 6) | (1 << 7) }
            return bits
        }
    }

    static func protect(_ source: PDFDocument, userPassword: String, ownerPassword: String?, permissions: Permissions = Permissions(), to url: URL) throws {
        guard !userPassword.isEmpty else { throw DocumentError.invalidOption("Enter a password to protect the PDF.") }
        // A distinct owner password is required for permissions to mean anything.
        let owner = ownerPassword?.nilIfBlank ?? (userPassword + "-owner-" + UUID().uuidString.prefix(8))
        let copy = document(from: source, pageIndices: Array(0 ..< source.pageCount))
        try write(copy, to: url, options: [
            .userPasswordOption: userPassword,
            .ownerPasswordOption: owner,
            .accessPermissionsOption: NSNumber(value: permissions.rawValue)
        ])
    }

    /// Writes an unencrypted copy of a PDF that was opened with its password.
    static func removePassword(_ source: PDFDocument, to url: URL) throws {
        let copy = document(from: source, pageIndices: Array(0 ..< source.pageCount))
        try write(copy, to: url)
    }

    // MARK: - Metadata

    struct Metadata: Hashable, Sendable {
        var title: String?
        var author: String?
        var subject: String?
        var keywords: String?
        var creator: String?
    }

    static func metadata(of document: PDFDocument) -> Metadata {
        let attributes = document.documentAttributes ?? [:]
        let keywords: String? = (attributes[PDFDocumentAttribute.keywordsAttribute] as? [String])?.joined(separator: ", ")
            ?? attributes[PDFDocumentAttribute.keywordsAttribute] as? String
        return Metadata(
            title: attributes[PDFDocumentAttribute.titleAttribute] as? String,
            author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
            subject: attributes[PDFDocumentAttribute.subjectAttribute] as? String,
            keywords: keywords,
            creator: attributes[PDFDocumentAttribute.creatorAttribute] as? String
        )
    }

    static func setMetadata(_ metadata: Metadata, on document: PDFDocument, clearOthers: Bool = false) {
        var attributes = clearOthers ? [:] : (document.documentAttributes ?? [:])
        func set(_ key: PDFDocumentAttribute, _ value: Any?) {
            if let value { attributes[key] = value } else { attributes.removeValue(forKey: key) }
        }
        set(PDFDocumentAttribute.titleAttribute, metadata.title?.nilIfBlank)
        set(PDFDocumentAttribute.authorAttribute, metadata.author?.nilIfBlank)
        set(PDFDocumentAttribute.subjectAttribute, metadata.subject?.nilIfBlank)
        set(PDFDocumentAttribute.creatorAttribute, metadata.creator?.nilIfBlank)
        let keywords = metadata.keywords?.split(separator: ",").compactMap { String($0).nilIfBlank }
        set(PDFDocumentAttribute.keywordsAttribute, (keywords?.isEmpty ?? true) ? nil : keywords)
        attributes[PDFDocumentAttribute.modificationDateAttribute] = Date()
        document.documentAttributes = attributes
    }

    // MARK: - Content extraction

    static func text(of document: PDFDocument, pages: [Int]? = nil, pageSeparators: Bool = true) -> String {
        let indices = pages ?? Array(0 ..< document.pageCount)
        return indices.compactMap { index -> String? in
            guard let text = document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return pageSeparators && indices.count > 1 ? "— Page \(index + 1) —\n\(text)" : text
        }.joined(separator: "\n\n")
    }

    static func hasTextLayer(_ document: PDFDocument, sampleLimit: Int = 5) -> Bool {
        for index in 0 ..< min(document.pageCount, sampleLimit) {
            if let text = document.page(at: index)?.string, text.trimmingCharacters(in: .whitespacesAndNewlines).count > 8 { return true }
        }
        return false
    }

    /// Bakes annotations and form fields into page content.
    static func flatten(_ source: PDFDocument, to url: URL) throws {
        let copy = document(from: source, pageIndices: Array(0 ..< source.pageCount))
        try write(copy, to: url, options: [.burnInAnnotationsOption: true])
    }
}
