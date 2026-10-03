import AVFoundation
import XCTest
@testable import Converter

@MainActor
final class MediaPreviewPlaybackTests: XCTestCase {
    func testTinySourceCropSurvivesReducedResolutionPreview() {
        // An 8-pixel selection at x=1 in 7680px source space becomes [1/6, 1.5] in a 1280px preview.
        let scale = 1280.0 / 7680
        let selection = CGRect(x: scale, y: scale, width: 8 * scale, height: 8 * scale)
        let rendered = EditedVideoPreview.pixelAlignedCrop(selection, in: CGSize(width: 1280, height: 720))
        XCTAssertTrue(rendered.contains(selection))
        XCTAssertGreaterThanOrEqual(rendered.width, 1)
        XCTAssertGreaterThanOrEqual(rendered.height, 1)
        let atEdge = EditedVideoPreview.pixelAlignedCrop(
            CGRect(x: 1279.5, y: 719.5, width: 0.5, height: 0.5), in: CGSize(width: 1280, height: 720)
        )
        XCTAssertEqual(atEdge, CGRect(x: 1279, y: 719, width: 1, height: 1))
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("preview-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: Int(buffer.frameLength))
        try file.write(from: buffer)
        return url
    }

    private func waitForPreparation(_ playback: MediaPreviewPlayback) async throws {
        for _ in 0..<200 {
            if !playback.isPreparing { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("Preview preparation timed out")
    }

    func testNativeSourceStaysNativeAndInactivePreparationDoesNotPlay() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = MediaPreviewPlayback()
        defer { playback.stop() }
        playback.setActive(false)
        playback.prepare(sourceURL: url, category: .audio)
        try await waitForPreparation(playback)
        XCTAssertNil(playback.errorMessage)
        let player = try XCTUnwrap(playback.player)
        let asset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertEqual(asset.url, url, "Native sources must not be unnecessarily converted")
        XCTAssertEqual(player.rate, 0, "Preparation finishing in the background must not start playback")
        playback.stop()
        XCTAssertNil(playback.player)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Releasing a preview must preserve its original")
    }

    func testDismissalDuringItemPreparationCannotInstallLatePlayer() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = MediaPreviewPlayback()
        playback.setActive(false)
        var startedBuilding = false
        playback.prepare(sourceURL: url, category: .audio) { preparedURL in
            startedBuilding = true
            // Simulate an API that returns its result despite task cancellation.
            try? await Task.sleep(for: .seconds(1))
            return AVPlayerItem(url: preparedURL)
        }
        for _ in 0..<100 where !startedBuilding { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(startedBuilding)
        playback.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(playback.player)
        XCTAssertFalse(playback.isPreparing)
        XCTAssertNil(playback.errorMessage)
    }

    func testFailedNativePlayerRetriesDecodedAudio() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = MediaPreviewPlayback()
        defer { playback.stop() }
        playback.setActive(false)
        var attempts = [URL]()
        playback.prepare(sourceURL: url, category: .audio) { preparedURL in
            attempts.append(preparedURL)
            if attempts.count == 1 {
                return AVPlayerItem(url: url.appendingPathExtension("missing"))
            }
            return AVPlayerItem(url: preparedURL)
        }
        for _ in 0..<200 {
            if attempts.count == 2 && !playback.isPreparing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(attempts.count, 2, "A native runtime decoder failure should trigger one fallback")
        XCTAssertEqual(attempts.first, url)
        XCTAssertNotEqual(attempts.last, url)
        XCTAssertNil(playback.errorMessage)
        XCTAssertNotNil(playback.player)
        XCTAssertEqual(playback.player?.rate, 0)
    }

    func testRepeatedItemFailureStopsAfterFallback() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let playback = MediaPreviewPlayback()
        defer { playback.stop() }
        playback.setActive(false)
        var attempts = 0
        playback.prepare(sourceURL: url, category: .audio) { _ in
            attempts += 1
            return AVPlayerItem(url: url.appendingPathExtension("missing"))
        }
        for _ in 0..<200 {
            if playback.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(attempts, 2, "An unreadable preview must not enter a retry loop")
        XCTAssertNotNil(playback.errorMessage)
        XCTAssertNil(playback.player)
        XCTAssertFalse(playback.isPreparing)
    }
}
