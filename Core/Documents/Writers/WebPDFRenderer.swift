import Foundation
import UIKit
import WebKit

/// Paginates HTML (or any file WebKit can display, including Office documents) into a PDF.
@MainActor
final class WebPDFRenderer: NSObject, WKNavigationDelegate {
    struct PageSetup {
        var pageRect: CGRect
        var margin: CGFloat
        var pageNumbers: Bool
        var title: String?
        var author: String?

        init(pageRect: CGRect, margin: CGFloat, pageNumbers: Bool = false, title: String? = nil, author: String? = nil) {
            self.pageRect = pageRect
            self.margin = margin
            self.pageNumbers = pageNumbers
            self.title = title
            self.author = author
        }

        init(options: DocumentExportOptions, title: String?, author: String?) {
            self.init(pageRect: options.pageRect, margin: options.marginPoints, pageNumbers: options.pageNumbers, title: options.title ?? title, author: options.author ?? author)
        }
    }

    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Error>?

    private init(width: CGFloat) {
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: max(width, 200), height: 800), configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    static func renderHTML(_ html: String, baseURL: URL? = nil, setup: PageSetup) async throws -> Data {
        let renderer = WebPDFRenderer(width: setup.pageRect.width - setup.margin * 2)
        try await renderer.load { $0.loadHTMLString(html, baseURL: baseURL) }
        return try await renderer.paginate(setup: setup)
    }

    /// Loads a local file (HTML, DOCX, XLSX, PPTX, RTF, SVG…) with WebKit's built-in viewers.
    static func renderFile(_ url: URL, setup: PageSetup) async throws -> Data {
        let renderer = WebPDFRenderer(width: setup.pageRect.width - setup.margin * 2)
        try await renderer.load { $0.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        return try await renderer.paginate(setup: setup)
    }

    /// Loads a remote page (URL to PDF).
    static func renderRemote(_ url: URL, setup: PageSetup) async throws -> Data {
        let renderer = WebPDFRenderer(width: max(setup.pageRect.width - setup.margin * 2, 390))
        try await renderer.load { $0.load(URLRequest(url: url, timeoutInterval: 30)) }
        return try await renderer.paginate(setup: setup)
    }

    /// Renders a page or file to a single image the size of its content (URL/SVG to image).
    static func snapshotFile(_ url: URL, width: CGFloat, remote: Bool = false) async throws -> UIImage {
        let renderer = WebPDFRenderer(width: width)
        if remote {
            try await renderer.load { $0.load(URLRequest(url: url, timeoutInterval: 30)) }
        } else {
            try await renderer.load { $0.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) }
        }
        return try await renderer.snapshot()
    }

    /// Renders an SVG at its own aspect ratio, `longSide` pixels on its longer side, keeping
    /// transparency. (Snapshotting the SVG file itself captures a page-sized canvas instead.)
    static func renderSVG(_ url: URL, longSide: CGFloat = 2_048) async throws -> CGImage {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("svg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("image.svg"))
        let page = folder.appendingPathComponent("index.html")
        try Data("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1"><style>html,body{margin:0;padding:0;background:transparent}img{display:block}</style></head>
        <body><img id="art" src="image.svg"></body></html>
        """.utf8).write(to: page)

        let renderer = WebPDFRenderer(width: 400)
        renderer.webView.isOpaque = false
        renderer.webView.backgroundColor = .clear
        renderer.webView.scrollView.backgroundColor = .clear
        try await renderer.load { $0.loadFileURL(page, allowingReadAccessTo: folder) }
        let natural = (try? await renderer.webView.evaluateJavaScript("[document.getElementById('art').naturalWidth, document.getElementById('art').naturalHeight]") as? [Double]) ?? []
        guard natural.count == 2 else { throw DocumentError.unreadable("The SVG couldn't be read.") }
        // SVGs without a size render at the browser default of 300 × 150.
        let intrinsic = natural[0] > 0 && natural[1] > 0 ? CGSize(width: natural[0], height: natural[1]) : CGSize(width: 300, height: 150)
        let screenScale = renderer.webView.window?.screen.scale ?? UITraitCollection.current.displayScale
        let scale = longSide / max(intrinsic.width, intrinsic.height) / max(screenScale, 1)
        let size = CGSize(width: (intrinsic.width * scale).rounded(), height: (intrinsic.height * scale).rounded())
        _ = try? await renderer.webView.evaluateJavaScript("var a = document.getElementById('art'); a.style.width = '\(size.width)px'; a.style.height = '\(size.height)px'; 0")
        renderer.webView.frame = CGRect(origin: .zero, size: size)
        // Wait for WebKit to lay the image out at its new size (slow machines take a while).
        for _ in 0 ..< 40 {
            let laidOut = (try? await renderer.webView.evaluateJavaScript("document.getElementById('art').getBoundingClientRect().width") as? Double) ?? 0
            if abs(laidOut - size.width) < 1 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        guard let image = try await renderer.webView.takeSnapshot(configuration: configuration).cgImage else {
            throw DocumentError.writeFailed("The SVG couldn't be rendered.")
        }
        return image
    }

    private func load(_ start: (WKWebView) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation
            start(webView)
        }
        // Wait for images and web fonts so pagination measures final layout.
        for _ in 0 ..< 50 {
            let ready = (try? await webView.evaluateJavaScript(
                "document.readyState === 'complete' && Array.from(document.images).every(i => i.complete)"
            ) as? Bool) ?? true
            if ready { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 150_000_000)
    }

    private func paginate(setup: PageSetup) async throws -> Data {
        let renderer = FooterPageRenderer(pageNumbers: setup.pageNumbers)
        renderer.addPrintFormatter(webView.viewPrintFormatter(), startingAtPageAt: 0)
        let paper = setup.pageRect
        let footerReserve: CGFloat = setup.pageNumbers ? 24 : 0
        let printable = paper.insetBy(dx: setup.margin, dy: setup.margin)
        renderer.footerHeight = footerReserve
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")

        let format = UIGraphicsPDFRendererFormat()
        var info: [String: Any] = [kCGPDFContextCreator as String: "MB Converter"]
        if let title = setup.title { info[kCGPDFContextTitle as String] = title }
        if let author = setup.author { info[kCGPDFContextAuthor as String] = author }
        format.documentInfo = info
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: paper, format: format)
        let pageCount = max(renderer.numberOfPages, 1)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: pageCount))
        let data = pdfRenderer.pdfData { context in
            for index in 0 ..< pageCount {
                context.beginPage()
                renderer.drawPage(at: index, in: paper)
            }
        }
        guard !data.isEmpty else { throw DocumentError.writeFailed("The page renderer produced no output.") }
        return data
    }

    private func snapshot() async throws -> UIImage {
        let height = (try? await webView.evaluateJavaScript("Math.max(document.body.scrollHeight, document.documentElement.scrollHeight)") as? Double) ?? 800
        let width = (try? await webView.evaluateJavaScript("Math.max(document.body.scrollWidth, document.documentElement.scrollWidth)") as? Double) ?? Double(webView.bounds.width)
        let size = CGSize(width: min(max(width, 1), 8000), height: min(max(height, 1), 16000))
        webView.frame = CGRect(origin: .zero, size: size)
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(origin: .zero, size: size)
        configuration.afterScreenUpdates = true
        return try await webView.takeSnapshot(configuration: configuration)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        continuation?.resume()
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: DocumentError.unreadable(error.localizedDescription))
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: DocumentError.unreadable(error.localizedDescription))
        continuation = nil
    }
}

private final class FooterPageRenderer: UIPrintPageRenderer {
    let pageNumbers: Bool

    init(pageNumbers: Bool) {
        self.pageNumbers = pageNumbers
        super.init()
    }

    override func drawFooterForPage(at pageIndex: Int, in footerRect: CGRect) {
        guard pageNumbers else { return }
        let text = "\(pageIndex + 1)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 9),
            .foregroundColor: UIColor.darkGray
        ]
        let size = text.size(withAttributes: attributes)
        text.draw(at: CGPoint(x: footerRect.midX - size.width / 2, y: footerRect.maxY - size.height - 4), withAttributes: attributes)
    }
}
