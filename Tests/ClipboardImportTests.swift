import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// Controlled providers exercise the system callback contract, including a URL
/// that disappears immediately after the completion handler returns.
final class ClipboardTestProvider: NSItemProvider {
    let advertised: [String]
    var files: [String: URL]
    var requested: [String] = []
    var hold = false
    var pending: ((URL?, Error?) -> Void)?
    var deleteAfterCallback = false
    init(types: [String], files: [String: URL] = [:]) {
        self.advertised = types
        self.files = files
        super.init()
        suggestedName = "original.heic"
    }
    required init?(coder: NSCoder) { fatalError("unused") }
    override var registeredTypeIdentifiers: [String] { advertised }
    override func loadFileRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping (URL?, Error?) -> Void
    ) -> Progress {
        requested.append(typeIdentifier)
        if hold { pending = completionHandler }
        else {
            let url = files[typeIdentifier]
            completionHandler(url, url == nil ? Self.unavailable : nil)
            if deleteAfterCallback, let url { try? FileManager.default.removeItem(at: url) }
        }
        return Progress(totalUnitCount: 1)
    }
    static var unavailable: Error {
        NSError(domain: NSItemProvider.errorDomain, code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "Cannot load representation of type public.heic"])
    }
}

@main
struct ClipboardImportTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.dropFirst().first == "--temporary-directory" {
            print(FileManager.default.temporaryDirectory.path)
            return
        }
        let board = UIPasteboard.general
        let service = ImportService()
        let heic = UTType.heic.identifier
        let png = UTType.png.identifier
        let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = UIImage(cgImage: context.makeImage()!).pngData()!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.png")
        try data.write(to: source)

        // A failed HEIC file request must not hide readable image bytes.
        let unavailable = ClipboardTestProvider(types: [heic])
        board.reset(providers: [unavailable], data: [png: data])
        let fallbackURL = try await service.importFromPasteboard()
        precondition(fallbackURL.pathExtension == "png")
        let fallbackData = try Data(contentsOf: fallbackURL)
        precondition(fallbackData == data)
        try FileManager.default.removeItem(at: fallbackURL)
        let fallbackPreview = await service.pasteboardPreview(forChangeCount: board.changeCount)
        precondition(fallbackPreview.readableFileExtension == "png")

        // A second file representation works even if the first advertises HEIC.
        let alternate = ClipboardTestProvider(types: [heic, png], files: [png: source])
        alternate.deleteAfterCallback = true
        board.reset(providers: [alternate])
        let alternateURL = try await service.importFromPasteboard()
        precondition(alternate.requested == [heic, png])
        precondition(alternateURL.pathExtension == "png") // not suggestedName's .heic
        let alternateData = try Data(contentsOf: alternateURL)
        precondition(alternateData == data)
        precondition(!FileManager.default.fileExists(atPath: source.path))
        try FileManager.default.removeItem(at: alternateURL)
        try data.write(to: source)

        // A stale direct file URL must not be enabled by unrelated provider data.
        board.reset(data: [png: data])
        board.url = directory.appendingPathComponent("missing.heic")
        let missingFilePreview = await service.pasteboardPreview(forChangeCount: board.changeCount)
        precondition(missingFilePreview.readableFileExtension == nil)
        board.reset(data: [heic: Data()])
        let emptyPreview = await service.pasteboardPreview(forChangeCount: board.changeCount)
        precondition(emptyPreview.readableFileExtension == nil)

        // Advertising HEIC is insufficient; even hasImages must not enable paste.
        board.reset(providers: [unavailable])
        let failedPreview = await service.pasteboardPreview(forChangeCount: board.changeCount)
        precondition(failedPreview.readableFileExtension == nil)
        let model = HomeViewModel()
        precondition(model.pasteboardImportLabel == nil)
        await settle()
        precondition(model.pasteboardImportLabel == nil)
        model.refreshPasteboard()
        precondition(model.pasteboardImportLabel == nil)

        // Availability remains pending until the real representation loads.
        let delayed = ClipboardTestProvider(types: [png], files: [png: source])
        delayed.hold = true
        board.reset(providers: [delayed])
        model.refreshPasteboard()
        await waitUntil { delayed.pending != nil }
        precondition(model.pasteboardImportLabel == nil)
        delayed.pending?(source, nil)
        delayed.pending = nil
        await waitUntil { model.pasteboardImportLabel == "PNG" }

        // A subsequent provider failure disables this clipboard revision and
        // refresh/onAppear cannot accidentally re-enable its advertised type.
        delayed.hold = false
        delayed.files = [:]
        let failed = await model.importFromPasteboard()
        precondition(failed == nil)
        precondition(model.pasteboardImportLabel == nil)
        model.refreshPasteboard()
        precondition(model.pasteboardImportLabel == nil)

        // A late success from an old clipboard revision cannot enable a new one.
        let stale = ClipboardTestProvider(types: [png])
        stale.hold = true
        board.reset(providers: [stale])
        model.refreshPasteboard()
        await waitUntil { stale.pending != nil }
        board.reset(providers: [unavailable])
        model.refreshPasteboard()
        stale.pending?(source, nil)
        stale.pending = nil
        await settle()
        precondition(model.pasteboardImportLabel == nil)

        // Fresh readable clipboard contents re-enable paste normally.
        board.reset(data: [png: data])
        model.refreshPasteboard()
        await waitUntil { model.pasteboardImportLabel == "PNG" }
        let stalePreview = await service.pasteboardPreview(forChangeCount: board.changeCount - 1)
        precondition(stalePreview.readableFileExtension == nil)
        print("PASS: clipboard fallback, alternate format, callback lifetime, availability, failure caching, and stale results")

        if let fixtureDirectory = CommandLine.arguments.dropFirst().first {
            try await testThumbnails(in: URL(fileURLWithPath: fixtureDirectory), service: service)
        }
    }

    @MainActor
    static func testThumbnails(in directory: URL, service: ImportService) async throws {
        let board = UIPasteboard.general
        let fixtures = ["video.wmv", "video.webm", "video.avi", "video.mkv", "video.ts", "video.flv",
                        "image.jpg", "image.gif", "image.webp", "audio.opus", "audio.ogg", "audio.flac"]
        for name in fixtures {
            let url = directory.appendingPathComponent(name)
            let bytes = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber).int64Value
            board.reset()
            board.url = url
            let direct = await service.pasteboardPreview(forChangeCount: board.changeCount, maxPixelSize: 96)
            precondition(direct.thumbnail != nil, "Missing direct thumbnail for \(name)")
            precondition(direct.readableFileExtension == url.pathExtension)
            precondition(direct.fileSizeBytes == bytes)
            precondition(max(direct.thumbnail!.size.width, direct.thumbnail!.size.height) <= 96)
            if name.hasPrefix("video") || name.hasPrefix("audio") {
                precondition((direct.duration ?? 0) > 0, "Missing FFmpeg duration fallback for \(name)")
            }
            guard let type = UTType(filenameExtension: url.pathExtension)?.identifier else {
                preconditionFailure("Missing fixture UTType: \(name)")
            }
            let ephemeral = directory.appendingPathComponent("ephemeral.\(url.pathExtension)")
            try FileManager.default.copyItem(at: url, to: ephemeral)
            let provider = ClipboardTestProvider(types: [type], files: [type: ephemeral])
            provider.deleteAfterCallback = true
            let filesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: ImportStorage.directory.path))
            board.reset(providers: [provider])
            let provided = await service.pasteboardPreview(forChangeCount: board.changeCount, maxPixelSize: 96)
            precondition(provided.thumbnail != nil, "Missing provider thumbnail for \(name)")
            precondition(!FileManager.default.fileExists(atPath: ephemeral.path), "Fixture must expire in provider callback")
            let filesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: ImportStorage.directory.path))
            precondition(filesAfter == filesBefore,
                         "Preview leaked its provider copy for \(name)")
            board.reset(data: [type: try Data(contentsOf: url)])
            let binary = await service.pasteboardPreview(forChangeCount: board.changeCount, maxPixelSize: 96)
            precondition(binary.thumbnail != nil, "Missing data thumbnail for \(name)")
            print("PASS: \(name) clipboard thumbnails via direct file, expired provider, and raw data")
        }

        // Exercise the fallback sampler even on hosts whose native decoder supports Opus.
        let sample = try await MediaPreviewRenderer.renderAudioThumbnailSample(
            sourceURL: directory.appendingPathComponent("long.opus")
        )
        defer { try? FileManager.default.removeItem(at: sample) }
        let probe = FFmpegMediaProbe.probe(at: sample)!
        precondition((probe.format?.duration ?? 0) > 11 && (probe.format?.duration ?? 100) <= 12.1,
                     "A clipboard waveform must not decode an entire long recording")
        precondition(AudioWaveformThumbnail.image(from: sample, maxPixelSize: 96) != nil)

        // Cancelling a pending provider must not copy its file or publish a late thumbnail.
        let wmv = directory.appendingPathComponent("video.wmv")
        let type = UTType(filenameExtension: "wmv")!.identifier
        let delayed = ClipboardTestProvider(types: [type], files: [type: wmv])
        delayed.hold = true
        board.reset(providers: [delayed])
        let count = board.changeCount
        let request = Task { await service.pasteboardPreview(forChangeCount: count) }
        await waitUntil { delayed.pending != nil }
        request.cancel()
        delayed.pending?(wmv, nil)
        delayed.pending = nil
        let cancelled = await request.value
        precondition(cancelled.thumbnail == nil && cancelled.readableFileExtension == nil)
        precondition(FileManager.default.fileExists(atPath: wmv.path))

        // Home must publish the WMV poster to the row and ignore a prior revision's async data decoding.
        board.reset(data: [type: try Data(contentsOf: wmv)])
        let model = HomeViewModel()
        await waitUntil { model.pasteboardPreviewThumbnail != nil }
        precondition(model.pasteboardImportLabel == "WMV")
        let revision = board.changeCount
        let staleData = Task { await service.pasteboardPreview(forChangeCount: revision) }
        await Task.yield()
        board.reset()
        model.refreshPasteboard()
        let staleResult = await staleData.value
        precondition(staleResult.thumbnail == nil && staleResult.readableFileExtension == nil)
        precondition(model.pasteboardPreviewThumbnail == nil)
        print("PASS: bounded FFmpeg waveform, cancelled provider and original-file preservation")
    }

    @MainActor
    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        precondition(condition(), "Timed out waiting for clipboard callback")
    }

    static func settle() async {
        try? await Task.sleep(for: .milliseconds(20))
    }
}
