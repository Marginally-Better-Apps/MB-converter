import Foundation

// Host-only regressions. The HTTP transport is deterministic; downloads,
// storage, media inspection and the optional native FFmpeg probe are production code.
private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+j4WQAAAAASUVORK5CYII=")!
    static let html = Data("<!DOCTYPE html><html><head><title>Download redirect...</title></head><body><script>window.location.replace('/download');</script></body></html>".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        var finalURL = url
        var status = 200
        var headers = ["Content-Type": "image/png"]
        var body = Self.png
        var failure: Error?
        switch url.lastPathComponent {
        case "redirect-page.avi":
            headers = ["Content-Type": "text/html; charset=UTF-8", "Content-Disposition": "attachment; filename=video.avi"]
            body = Self.html
        case "xhtml.avi": headers = ["Content-Type": "application/xhtml+xml"]; body = Self.html
        case "json.avi": headers = ["Content-Type": "application/problem+json"]; body = Data("{}".utf8)
        case "xml.avi": headers = ["Content-Type": "application/xml"]; body = Data("<Error>Denied</Error>".utf8)
        case "missing.png": status = 404
        case "partial.png": status = 206
        case "range.png": headers["Content-Range"] = "bytes 0-67/100"
        case "no-content.png": status = 204; body = Data()
        case "empty.png": body = Data()
        case "short.png": headers["Content-Length"] = String(body.count + 20)
        case "long.png": headers["Content-Length"] = "1"
        case "oversized.png": headers["Content-Length"] = String(RemoteFileDownloader.maxBytes + 1)
        case "disconnected.png": failure = URLError(.networkConnectionLost)
        case "sized.png": headers["Content-Length"] = String(body.count)
        case "compressed.png":
            // AsyncBytes contains decoded bytes even when the wire body is compressed.
            headers["Content-Encoding"] = "gzip"
            headers["Content-Length"] = "20"
        case "binary.png": headers = ["Content-Type": "application/octet-stream"]
        case "no-mime.png": headers = [:]
        case "disposition": headers = ["Content-Disposition": "attachment; filename*=UTF-8''tiny%20image.png"]
        case "redirect.php": finalURL = URL(string: "https://cdn.example.test/tiny.png")!; headers = [:]
        case "unknown.bin": headers = ["Content-Type": "application/octet-stream"]
        case "disguised.avi": headers = ["Content-Type": "video/x-msvideo"]; body = Self.html
        case "garbage.avi": headers = [:]; body = Data([0, 1, 2, 3, 4, 5])
        case "large.wav": headers = ["Content-Type": "audio/wav"]; body = Self.wave()
        default: break
        }
        let response = HTTPURLResponse(url: finalURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        if let failure {
            client?.urlProtocol(self, didFailWithError: failure)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    static func wave() -> Data {
        let samples: UInt32 = 160_000
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + samples * 2); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        text("data"); u32(samples * 2); data.append(Data(count: Int(samples * 2)))
        return data
    }
}

// Only the UIKit diagnostics sink is replaced in the macOS test driver.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()
    func record(error: Error, context: String, metadata: [String: String] = [:]) {}
}

@main
struct RemoteImportTests {
    static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) rethrows {
        if try !condition() { fatalError(label) }
    }

    static func importFiles() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: ImportStorage.directory, includingPropertiesForKeys: nil))
    }

    static func main() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let downloader = RemoteFileDownloader(session: session)

        for path in ["redirect-page.avi", "xhtml.avi", "json.avi", "xml.avi", "missing.png", "partial.png", "range.png",
                     "no-content.png", "empty.png", "short.png", "long.png", "oversized.png", "disconnected.png", "unknown.bin"] {
            let before = try importFiles()
            do {
                _ = try await downloader.download("https://example.test/\(path)")
                fatalError("Accepted invalid response: \(path)")
            } catch let error as ImportError {
                switch (path, error) {
                case ("redirect-page.avi", .remoteResponseNotMedia), ("xhtml.avi", .remoteResponseNotMedia),
                     ("json.avi", .remoteResponseNotMedia), ("xml.avi", .remoteResponseNotMedia),
                     ("oversized.png", .fileTooLarge), ("unknown.bin", .couldNotDetermineRemoteFileType): break
                case (_, .networkFailed):
                    require(!["redirect-page.avi", "xhtml.avi", "json.avi", "xml.avi", "oversized.png", "unknown.bin"].contains(path), "Wrong rejection for \(path)")
                default: fatalError("Unexpected error for \(path): \(error)")
                }
            }
            try require(importFiles() == before, "Failed response left an import behind: \(path)")
        }

        for value in ["", "   ", "file:///tmp/video.mp4", "ftp://example.test/video.mp4", "https:///", "https:"] {
            do {
                _ = try await downloader.download(value)
                fatalError("Accepted invalid URL: \(value)")
            } catch ImportError.invalidRemoteURL {}
        }

        for path in ["tiny.png", "sized.png", "compressed.png", "binary.png", "no-mime.png", "disposition", "redirect.php", "download.php"] {
            var updates: [RemoteDownloadProgress] = []
            let url = try await downloader.download("https://example.test/\(path)") { updates.append($0) }
            defer { try? FileManager.default.removeItem(at: url) }
            require(url.pathExtension == "png", "Wrong inferred extension: \(path)")
            try require(Data(contentsOf: url) == FixtureURLProtocol.png, "Download changed bytes: \(path)")
            let media = try await MediaInspector.inspect(url: url)
            require(media.category == .image && media.dimensions == CGSize(width: 1, height: 1), "Tiny valid image must remain importable")
            require(updates.first?.bytesReceived == 0 && updates.last?.fractionCompleted == 1, "Download progress must complete: \(path)")
        }

        for path in ["disguised.avi", "garbage.avi"] {
            let url = try await downloader.download("https://example.test/\(path)")
            defer { try? FileManager.default.removeItem(at: url) }
            do {
                _ = try await MediaInspector.inspect(url: url)
                fatalError("Invalid video reached the conversion flow: \(path)")
            } catch ConversionError.invalidInput {}
        }

        var waveUpdates: [RemoteDownloadProgress] = []
        let wave = try await downloader.download("example.test/large.wav") { waveUpdates.append($0) }
        defer { try? FileManager.default.removeItem(at: wave) }
        try require(Data(contentsOf: wave) == FixtureURLProtocol.wave(), "Multiple chunks must preserve every byte")
        let audio = try await MediaInspector.inspect(url: wave)
        require(audio.category == .audio && (audio.duration ?? 0) > 3, "Valid audio must remain importable")
        require(waveUpdates.count >= 3 && waveUpdates.last?.totalBytes == Int64(FixtureURLProtocol.wave().count), "Unknown-length progress")

        let beforeCancellation = try importFiles()
        let cancelled = Task {
            try await downloader.download("https://example.test/large.wav") { update in
                if update.bytesReceived > 0 { withUnsafeCurrentTask { $0?.cancel() } }
            }
        }
        do {
            _ = try await cancelled.value
            fatalError("Cancelled download returned an input")
        } catch is CancellationError {} catch ImportError.networkFailed {} // URLSession may report URLError.cancelled.
        try require(importFiles() == beforeCancellation, "Cancelled download left a partial import")

        // The optional host FFmpeg framework exercises the real AVI/WebM fallback.
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path)
            let media = try await MediaInspector.inspect(url: url)
            require(media.category == .video && media.dimensions == CGSize(width: 64, height: 48), "Valid video rejected: \(path)")
        }
        print("Remote imports passed: HTTP errors, web pages, empty/partial downloads, cleanup, cancellation, extension inference, progress, invalid video rejection and valid media.")
    }
}
