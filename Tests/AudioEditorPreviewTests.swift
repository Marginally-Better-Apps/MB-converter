import AVFoundation
import SwiftUI
import XCTest
@testable import Converter

@MainActor
final class AudioEditorPreviewTests: XCTestCase {
    private func fixture(waveform: Bool = false) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("audio-editor-\(UUID()).wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480_000)!
        buffer.frameLength = 480_000
        for channel in 0..<2 {
            buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength))
            if waveform {
                for index in 0..<Int(buffer.frameLength) {
                    let time = Double(index) / 48_000
                    buffer.floatChannelData![channel][index] = Float(sin(time * 440 * 2 * .pi) * (0.1 + 0.8 * abs(sin(time * 1.5))))
                }
            }
        }
        try file.write(from: buffer)
        return url
    }

    func testPreviewReuseSeekAndCleanup() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = AudioEditorPreview()
        defer { preview.invalidate() }
        let edits = AudioEditSettings(trimStart: 2, trimEnd: 8, volume: 0.5, speed: 2, channels: .right)
        preview.play(sourceURL: url, duration: 10, edits: edits, position: 2, onPositionChange: { _ in })
        for _ in 0..<200 {
            if !preview.isPreparing { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(preview.errorMessage)
        XCTAssertFalse(preview.isPreparing)
        let player = try XCTUnwrap(preview.playback.player)
        let asset = try XCTUnwrap(player.currentItem?.asset as? AVURLAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        preview.pause()
        preview.play(sourceURL: url, duration: 10, edits: edits, position: 4, onPositionChange: { _ in })
        XCTAssertTrue(preview.playback.player === player, "Unchanged previews should reuse their player and PCM file")
        preview.seek(to: 5, edits: edits)
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(preview.playback.isPlaying)
        XCTAssertEqual(player.currentTime().seconds, 1.5, accuracy: 0.01, "Source playhead must map through trim and speed")
        preview.invalidate()
        XCTAssertNil(preview.playback.player)
        XCTAssertFalse(FileManager.default.fileExists(atPath: asset.url.path))
    }

    func testCancelledPreviewCannotStartLate() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let preview = AudioEditorPreview()
        preview.play(sourceURL: url, duration: 10, edits: AudioEditSettings(speed: 0.5),
                     position: 0, onPositionChange: { _ in })
        preview.invalidate()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(preview.isPreparing)
        XCTAssertFalse(preview.playback.isPlaying)
        XCTAssertNil(preview.playback.player)
        XCTAssertNil(preview.errorMessage)
    }

    func testEditorAppearance() async throws {
        let url = try fixture(waveform: true)
        defer { try? FileManager.default.removeItem(at: url) }
        for dark in [false, true] {
            let editor = AudioEditorView(url: url, filename: "Evening walk.wav", duration: 10,
                                         settings: .constant(AudioEditSettings(trimStart: 1, trimEnd: 9)))
                .preferredColorScheme(dark ? .dark : .light)
            let controller = UIHostingController(rootView: editor)
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
            window.rootViewController = controller
            window.makeKeyAndVisible()
            try await Task.sleep(for: .milliseconds(400))
            controller.view.layoutIfNeeded()
            let image = UIGraphicsImageRenderer(bounds: controller.view.bounds).image { _ in
                controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = dark ? "Audio editor dark" : "Audio editor light"
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertGreaterThan(image.size.height, 800)
            window.isHidden = true
        }
    }
}
