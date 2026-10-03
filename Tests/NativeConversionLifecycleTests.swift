import AVFoundation
import UIKit
import SwiftUI
import AVKit
import XCTest
@testable import Converter

@MainActor
final class NativeConversionLifecycleTests: XCTestCase {
    func testVideoFirstFrameConvertsThroughOfferedRoute() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let input = try await MediaInspector.inspect(url: source)
        let config = ConversionConfig(outputFormat: .png)
        let engine = try ConversionRouter.converter(for: input, config: config)
        let result = try await engine.convert(input: input, config: config, progress: { _ in }, encodingStats: nil)
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertNotNil(UIImage(contentsOfFile: result.url.path))
        XCTAssertEqual(result.dimensions, input.dimensions)
    }

    func testInlinePlaybackResumesAtPausedPositionWithoutWaitingForAnotherSeek() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let playback = TrimVideoPlayback()
        defer { playback.stop() }
        var playhead = 0.0
        playback.prepare(url: source, onPositionChange: { playhead = $0 })
        let player = try XCTUnwrap(playback.player)
        let range = VideoTrimRange(start: 0.25, end: 1.75)
        playback.play(from: range.start, range: range)
        let deadline = Date().addingTimeInterval(5)
        while player.currentTime().seconds < 0.5, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThanOrEqual(player.currentTime().seconds, 0.5)
        for _ in 0..<3 {
            playback.pause()
            let pausedTime = player.currentTime().seconds
            XCTAssertEqual(player.rate, 0)
            XCTAssertEqual(playhead, pausedTime, accuracy: 1.0 / 600,
                           "Pause must publish the actual cursor, not an old periodic sample")
            playback.play(from: playhead, range: range)
            XCTAssertEqual(player.rate, 1,
                           "Resume should set the rate immediately without an asynchronous seek")
            XCTAssertEqual(player.currentTime().seconds, pausedTime, accuracy: 0.02)
        }
    }

    func testInlinePlaybackStopsAtTrimEndAndReplaysFromStart() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let playback = TrimVideoPlayback()
        defer { playback.stop() }
        var positions: [Double] = []
        playback.prepare(url: source, onPositionChange: { positions.append($0) })
        let range = VideoTrimRange(start: 0.5, end: 1.5)
        playback.play(from: 1, range: range)
        let deadline = Date().addingTimeInterval(5)
        while playback.isPlaying, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(try XCTUnwrap(positions.first), 1, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(positions.last), 1.5, accuracy: 0.01)
        XCTAssertTrue(positions.allSatisfy { $0 >= 1 && $0 <= 1.5 })
        XCTAssertGreaterThan(positions.count, 2, "Playback should advance the timeline playhead")
        positions.removeAll()
        playback.play(from: range.end, range: range)
        XCTAssertEqual(try XCTUnwrap(positions.first), range.start, accuracy: 0.01)
        playback.pause()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.player?.rate, 0, "An in-flight seek must not restart a paused player")
    }

    func testInlinePlaybackPausesForScrubbingAndCleansUp() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let playback = TrimVideoPlayback()
        defer { playback.stop() }
        playback.prepare(url: source, onPositionChange: { _ in })
        let range = VideoTrimRange(start: 0.5, end: 1.5)
        playback.play(from: 0.75, range: range)
        playback.pause()
        playback.seek(to: 1.25, range: range)
        let deadline = Date().addingTimeInterval(5)
        while abs((playback.player?.currentTime().seconds ?? 0) - 1.25) > 0.02, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(try XCTUnwrap(playback.player).currentTime().seconds, 1.25, accuracy: 0.02)
        XCTAssertFalse(playback.isPlaying)
        XCTAssertEqual(playback.player?.rate, 0)
        playback.stop()
        XCTAssertNil(playback.player)
        XCTAssertFalse(playback.isPlaying)
    }

    func testTrimExportsSelectedDurationAndCanBeTrimmedAgain() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let originalBytes = try Data(contentsOf: source)
        let media = try await MediaInspector.inspect(url: source)
        let model = OutputConfigViewModel(input: media)
        model.selectedFormat = .webm
        model.mediaRotation = .clockwise90
        model.isMirrored = true
        model.cropRegion = CropRegion(x: 0, y: 0, width: 80, height: 120)
        let output = try await model.trimVideo(sourceURL: source) {
            try await VideoTrimmer.trimmedMedia(sourceURL: source, range: VideoTrimRange(start: 0.5, end: 1.5))
        }
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertEqual(model.input.duration ?? 0, 1, accuracy: 0.05)
        XCTAssertEqual(model.input.dimensions, media.dimensions)
        XCTAssertEqual(model.input.id, media.id)
        XCTAssertEqual(model.input.originalFilename, media.originalFilename)
        XCTAssertEqual(model.selectedFormat, .webm)
        XCTAssertEqual(model.mediaRotation, .clockwise90)
        XCTAssertTrue(model.isMirrored)
        XCTAssertEqual(model.cropRegion, CropRegion(x: 0, y: 0, width: 80, height: 120))
        XCTAssertEqual(try Data(contentsOf: source), originalBytes)
        // Exercise the final converter as well as native trimming: the selected
        // duration must survive the handoff and the crop/rotation must still apply.
        let converted = try await VideoConverter().convert(input: model.input, config: model.makeConfig(), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: converted.url) }
        XCTAssertEqual(converted.duration ?? 0, 1, accuracy: 0.1)
        XCTAssertEqual(converted.dimensions, CGSize(width: 80, height: 120))
        let repeated = try await model.trimVideo(sourceURL: output) {
            try await VideoTrimmer.trimmedMedia(sourceURL: output, range: VideoTrimRange(start: 0.25, end: 0.75))
        }
        defer { try? FileManager.default.removeItem(at: repeated) }
        XCTAssertEqual(model.input.duration ?? 0, 0.5, accuracy: 0.05)
        XCTAssertFalse(model.isTrimmingVideo)
    }

    func testConcurrentTrimSaveDoesNotReplaceSourceTwice() async throws {
        let source = MediaFile(url: URL(fileURLWithPath: "/tmp/source.mov"), originalFilename: "source.mov",
                               category: .video, sizeOnDisk: 100, duration: 2, containerFormat: "mov")
        let model = OutputConfigViewModel(input: source)
        let output = ImportStorage.url(originalName: nil, fallbackExtension: "mov")
        try Data([1, 2, 3]).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        let started = expectation(description: "export started")
        var resume: CheckedContinuation<URL, Never>?
        var exports = 0
        let task = Task { @MainActor in
            try await model.trimVideo(sourceURL: source.url) {
                exports += 1
                let url = await withCheckedContinuation { resume = $0; started.fulfill() }
                return MediaFile(url: url, originalFilename: "temporary.mov", category: .video,
                                 sizeOnDisk: 3, duration: 1, containerFormat: "mov")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isTrimmingVideo)
        XCTAssertFalse(model.canConvert)
        do {
            _ = try await model.trimVideo(sourceURL: source.url) {
                exports += 1
                return source
            }
            XCTFail("A second save started while the first was pending")
        } catch { }
        resume?.resume(returning: output)
        let savedURL = try await task.value
        XCTAssertEqual(savedURL, output)
        XCTAssertEqual(model.input.url, output)
        XCTAssertEqual(exports, 1)
        XCTAssertFalse(model.isTrimmingVideo)
    }

    func testCancelledTrimKeepsInputAndRemovesUnpublishedOutput() async throws {
        let source = MediaFile(url: URL(fileURLWithPath: "/tmp/source.mov"), originalFilename: "source.mov",
                               category: .video, sizeOnDisk: 100, duration: 2, containerFormat: "mov")
        let model = OutputConfigViewModel(input: source)
        let output = ImportStorage.url(originalName: nil, fallbackExtension: "mov")
        try Data([1]).write(to: output)
        defer { try? FileManager.default.removeItem(at: output) }
        let started = expectation(description: "export started")
        var resume: CheckedContinuation<URL, Never>?
        let task = Task { @MainActor in
            try await model.trimVideo(sourceURL: source.url) {
                let url = await withCheckedContinuation { resume = $0; started.fulfill() }
                return MediaFile(url: url, originalFilename: "temporary.mov", category: .video,
                                 sizeOnDisk: 1, duration: 1, containerFormat: "mov")
            }
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        resume?.resume(returning: output)
        do {
            _ = try await task.value
            XCTFail("Cancelled trim replaced the input")
        } catch is CancellationError { }
        XCTAssertEqual(model.input.url, source.url)
        XCTAssertFalse(model.isTrimmingVideo)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }

    func testTrimHandlesCannotCrossOrLeaveVideoBounds() {
        let range = VideoTrimRange(start: 0.5, end: 1.5)
        XCTAssertEqual(range.movingStart(to: -10, totalDuration: 2).start, 0)
        XCTAssertEqual(range.movingStart(to: 10, totalDuration: 2).duration, 0.1, accuracy: 0.0001)
        XCTAssertEqual(range.movingEnd(to: 10, totalDuration: 2).end, 2)
        XCTAssertEqual(range.movingEnd(to: -10, totalDuration: 2).duration, 0.1, accuracy: 0.0001)
        let short = VideoTrimRange(start: 0, end: 0.04)
        XCTAssertEqual(short.movingStart(to: 1, totalDuration: 0.04), short)
        XCTAssertEqual(short.movingEnd(to: 0, totalDuration: 0.04), short)
    }

    func testTrimEndpointsPushPlayheadWithoutPullingItBack() {
        // Run the same push/reverse/reapproach sequence for both handles.
        for movingStart in [true, false] {
            var range = VideoTrimRange(start: 2, end: 18)
            var playhead = 10.0
            func move(to seconds: Double) {
                let next = movingStart ? range.movingStart(to: seconds, totalDuration: 20)
                    : range.movingEnd(to: seconds, totalDuration: 20)
                playhead = next.clampedPlayhead(playhead)
                range = next
            }
            move(to: movingStart ? 5 : 15)
            XCTAssertEqual(playhead, 10, "A distant endpoint must not seek the preview")
            move(to: 10)
            XCTAssertEqual(playhead, 10)
            move(to: movingStart ? 12 : 8)
            XCTAssertEqual(playhead, movingStart ? 12 : 8)
            move(to: movingStart ? 11 : 9)
            XCTAssertEqual(playhead, movingStart ? 12 : 8, "Reversing the endpoint must not pull the playhead back")
            move(to: movingStart ? 5 : 15)
            XCTAssertEqual(playhead, movingStart ? 12 : 8)
            move(to: movingStart ? 11.5 : 8.5)
            XCTAssertEqual(playhead, movingStart ? 12 : 8, "Reapproaching the playhead must not move it before contact")
            move(to: movingStart ? 13 : 7)
            XCTAssertEqual(playhead, movingStart ? 13 : 7, "Crossing the playhead again pushes it farther")
            playhead = movingStart ? 15 : 5
            move(to: movingStart ? 14 : 6)
            XCTAssertEqual(playhead, movingStart ? 15 : 5, "Moving a handle leaves an independently scrubbed position alone")
            move(to: movingStart ? 16 : 4)
            XCTAssertEqual(playhead, movingStart ? 16 : 4, "Crossing the playhead between drag samples must push it")
        }
    }

    func testPlayheadStartsAndReturnsSourcePosition() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        var returnedTime: Double?
        let view = FullVideoPlayer(url: source, sourceDimensions: CGSize(width: 160, height: 96),
                                   cropRegion: nil, rotation: .none, isMirrored: false,
                                   trimRange: VideoTrimRange(start: 0.5, end: 1.5), initialSourceTime: 1,
                                   onPlaybackPositionChange: { returnedTime = $0 })
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        func player(in controller: UIViewController) -> AVPlayer? {
            if let controller = controller as? AVPlayerViewController { return controller.player }
            for child in controller.children {
                if let found = player(in: child) { return found }
            }
            return nil
        }
        let deadline = Date().addingTimeInterval(5)
        while player(in: host) == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let activePlayer = try XCTUnwrap(player(in: host))
        activePlayer.pause()
        // AVKit can expose the controller before AVPlayer publishes its seek
        // time. Pausing first ensures this wait cannot pass through playback.
        while activePlayer.currentTime().seconds == 0, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(activePlayer.currentTime().seconds, 0.5, accuracy: 0.12)
        window.rootViewController = UIViewController()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(try XCTUnwrap(returnedTime), 1, accuracy: 0.12)
    }

    func testImageCancellationAfterWritingRemovesPartialOutput() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        }
        try XCTUnwrap(image.pngData()).write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let baseline = try conversionFiles()
        let converter = ImageConverter()
        let input = MediaFile(url: source, originalFilename: "test.png", category: .image,
                              sizeOnDisk: 100, dimensions: CGSize(width: 64, height: 64), containerFormat: "png")
        do {
            _ = try await converter.convert(input: input, config: ConversionConfig(outputFormat: .jpg), progress: {
                if $0 >= 1 { converter.cancel() }
            })
            XCTFail("Cancelled image conversion published output")
        } catch {
            guard case ConversionError.cancelled = error else { throw error }
        }
        XCTAssertEqual(try conversionFiles(), baseline)
    }

    func testNativeAudioCancellationUnwindsAndCleansOutput() async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let samples: UInt32 = 44_100 * 10
        var wave = Data()
        func text(_ value: String) { wave.append(Data(value.utf8)) }
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { wave.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + samples * 2); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(44_100); u32(88_200); u16(2); u16(16)
        text("data"); u32(samples * 2); wave.append(Data(count: Int(samples * 2)))
        try wave.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let baseline = try conversionFiles()
        let converter = AudioConverter()
        let input = MediaFile(url: source, originalFilename: "test.wav", category: .audio,
                              sizeOnDisk: Int64(wave.count), duration: 10, audioCodec: "pcm_s16le", containerFormat: "wav")
        do {
            _ = try await converter.convert(input: input, config: ConversionConfig(outputFormat: .wav), progress: {
                if $0 > 0 && $0 < 1 { converter.cancel() }
            })
            XCTFail("Cancelled audio conversion published output")
        } catch {
            guard case ConversionError.cancelled = error else { throw error }
        }
        XCTAssertEqual(try conversionFiles(), baseline)
    }

    func testVideoToolboxConversionProducesReadableOutput() async throws {
        let source = try await makeVideo()
        defer { try? FileManager.default.removeItem(at: source) }
        let media = try await MediaInspector.inspect(url: source)
        let result = try await VideoConverter().convert(
            input: media, config: ConversionConfig(outputFormat: .mp4_h264), progress: { _ in }
        )
        defer { try? FileManager.default.removeItem(at: result.url) }
        XCTAssertGreaterThan(result.sizeOnDisk, 0)
        XCTAssertGreaterThan(result.duration ?? 0, 1)
        XCTAssertEqual(result.dimensions, CGSize(width: 160, height: 96))
    }

    func testContinuedProcessingRegistrationOnPhysicalDevice() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Continued processing scheduling requires a physical device")
        #else
        guard #available(iOS 26.0, *) else { throw XCTSkip("Requires iOS 26") }
        let controller = ConversionBackgroundController(platform: SystemBackgroundExecution(), notifications: FakeWarnings())
        defer { controller.finish(success: true) }
        let ready = expectation(description: "System granted execution or reported fallback")
        var mode: ConversionBackgroundMode?
        controller.start(id: UUID(), title: "MB Converter verification", subtitle: "Checking background processing",
                         ready: { mode = $0; ready.fulfill() }, expired: {})
        await fulfillment(of: [ready], timeout: 15)
        guard mode == .extended else { throw XCTSkip("System declined extended execution; fallback verified separately") }
        controller.update(fraction: 0.5, stage: "Verifying progress")
        try await Task.sleep(for: .seconds(1))
        controller.tick()
        #endif
    }

    private func conversionFiles() throws -> Set<URL> {
        Set(try FileManager.default.contentsOfDirectory(at: TempStorage.directory, includingPropertiesForKeys: nil))
    }

    private func makeVideo() async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 96
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 96
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        do {
            for frame in 0..<48 {
                while !input.isReadyForMoreMediaData {
                    if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                    try await Task.sleep(for: .milliseconds(1))
                }
                var buffer: CVPixelBuffer?
                XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adapter.pixelBufferPool), &buffer), kCVReturnSuccess)
                let pixelBuffer = try XCTUnwrap(buffer)
                CVPixelBufferLockBaseAddress(pixelBuffer, [])
                memset(try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer)), Int32(frame * 5), CVPixelBufferGetDataSize(pixelBuffer))
                CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
                guard adapter.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
                    throw try XCTUnwrap(writer.error)
                }
            }
            input.markAsFinished()
            await writer.finishWriting()
            guard writer.status == .completed else { throw try XCTUnwrap(writer.error) }
            return url
        } catch {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}

/// Runs on a physical device only. The host suite supplies PQ/static-metadata
/// and failure-injection cases; this suite measures the actual iPhone pipeline.
@MainActor
final class VideoPipelineDeviceTests: XCTestCase {
    private final class Logs: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return lines.joined(separator: "\n") }
    }

    private func requireDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("VideoToolbox acceptance requires a physical iPhone")
        #endif
    }

    func testHardwareColorAndTransformPaths() async throws {
        try requireDevice()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for hdr in [false, true] {
            let source = directory.appendingPathComponent(hdr ? "hdr.mov" : "sdr.mov")
            try await makeVideo(at: source, width: 320, height: 192, hdr: hdr, frames: 24)
            let input = try await MediaInspector.inspect(url: source)
            XCTAssertEqual(input.videoColor?.isHDR, hdr)
            if hdr { XCTAssertEqual(input.videoColor?.bitDepth, 10) }
            for (index, filter) in ["scale=160:96", "transpose=clock", "transpose=cclock", "hflip,vflip", "hflip", "vflip"].enumerated() {
                let output = directory.appendingPathComponent("\(hdr)-\(index).mp4")
                let logs = Logs()
                try await FFmpegCommandRunner().run(
                    "-y -mb-acceleration required -i \(FFmpegCommandRunner.quoted(source.path)) -vf \(filter) -c:v hevc_videotoolbox -b:v 1500k -an -tag:v hvc1 \(FFmpegCommandRunner.quoted(output.path))",
                    duration: 1, progress: { _ in }, onLogLine: { logs.append($0) })
                XCTAssertTrue(logs.text.contains("filter=VideoToolbox"), logs.text)
                let result = try await MediaInspector.inspect(url: output)
                XCTAssertEqual(result.videoColor?.isHDR, hdr)
                if hdr { XCTAssertEqual(result.videoColor?.bitDepth, 10) }
                try await verifyPlayback(output, frames: 24)
                let dimensions = index == 0 ? CGSize(width: 160, height: 96) :
                    index == 1 || index == 2 ? CGSize(width: 192, height: 320) : CGSize(width: 320, height: 192)
                XCTAssertEqual(result.dimensions, dimensions)
            }
            let output = directory.appendingPathComponent("\(hdr)-cpu-filter.mp4")
            let logs = Logs()
            try await FFmpegCommandRunner().run(
                "-y -mb-acceleration auto -i \(FFmpegCommandRunner.quoted(source.path)) -vf crop=160:96 -c:v h264_videotoolbox -b:v 1500k -an \(FFmpegCommandRunner.quoted(output.path))",
                duration: 1, progress: { _ in }, onLogLine: { logs.append($0) })
            let result = try await MediaInspector.inspect(url: output)
            XCTAssertEqual(result.videoColor?.bitDepth, 8)
            XCTAssertEqual(result.videoColor?.isHDR, false)
            XCTAssertTrue(logs.text.contains("filter=CPU"), logs.text)
            if hdr { XCTAssertEqual(result.videoColor?.transfer, "bt709") }
        }
    }

    func testDeviceAccelerationBenchmarks() async throws {
        try requireDevice()
        let toneMapping = ProcessInfo.processInfo.environment["MBF_BENCHMARK_TONEMAP"] == "1"
        executionTimeAllowance = 600
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples: [[String: Any]] = []
        for width in [1920, 3840] {
            for hdr in toneMapping ? [true] : [false, true] {
                let source = directory.appendingPathComponent("source-\(width)-\(hdr).mov")
                try await makeVideo(at: source, width: width, height: width * 9 / 16, hdr: hdr, frames: 96)
                // Pair modes at each repetition to reduce warm-up/thermal bias.
                for repetition in 0..<4 {
                    let modes = toneMapping ? ["off", "auto"] : ["off", "required", "auto"]
                    for mode in repetition % 2 == 0 ? modes : modes.reversed() {
                        let output = directory.appendingPathComponent("output.mp4")
                        let logs = Logs()
                        var before = rusage(), after = rusage()
                        getrusage(RUSAGE_SELF, &before)
                        let start = ProcessInfo.processInfo.systemUptime
                        let thermalStart = ProcessInfo.processInfo.thermalState.rawValue
                        try await FFmpegCommandRunner().run(
                            "-y -mb-acceleration \(mode) -i \(FFmpegCommandRunner.quoted(source.path)) -vf scale=\(width / 2):\(width * 9 / 32) -c:v \(toneMapping ? "h264_videotoolbox" : "hevc_videotoolbox") -b:v 4000k -an \(toneMapping ? "" : "-tag:v hvc1") \(FFmpegCommandRunner.quoted(output.path))",
                            duration: 4, progress: { _ in }, onLogLine: { logs.append($0) })
                        let seconds = ProcessInfo.processInfo.systemUptime - start
                        getrusage(RUSAGE_SELF, &after)
                        func cpuTime(_ usage: rusage) -> Double {
                            Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
                        }
                        let cpuSeconds = cpuTime(after) - cpuTime(before)
                        if mode == "required" { XCTAssertTrue(logs.text.contains("filter=VideoToolbox"), logs.text) }
                        if mode == "auto" { XCTAssertTrue(logs.text.contains("filter=CPU"), logs.text) }
                        samples.append(["width": width, "hdr": hdr, "toneMapping": toneMapping, "mode": mode, "warmup": repetition == 0,
                                        "seconds": seconds, "cpuSeconds": cpuSeconds, "processPeakRSS": after.ru_maxrss,
                                        "thermalStart": thermalStart, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
                                        "pipeline": logs.text])
                    }
                }
                validateAutomaticPerformance(samples.filter { $0["width"] as? Int == width && $0["hdr"] as? Bool == hdr })
            }
        }
        let data = try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "VideoToolbox iPhone benchmark samples"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDeviceRotationQualification() async throws {
        try requireDevice()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var samples: [[String: Any]] = []
        for hdr in [false, true] {
            let source = directory.appendingPathComponent("source.mov")
            try await makeVideo(at: source, width: 3840, height: 2160, hdr: hdr, frames: 96)
            for filter in ["transpose=clock", "transpose=clock,scale=1080:1920", "null"] {
                for repetition in 0..<4 {
                    for mode in repetition % 2 == 0 ? ["off", "required", "auto"] : ["auto", "required", "off"] {
                        let output = directory.appendingPathComponent("output.mp4")
                        let logs = Logs()
                        var before = rusage(), after = rusage()
                        getrusage(RUSAGE_SELF, &before)
                        let start = ProcessInfo.processInfo.systemUptime
                        let thermal = ProcessInfo.processInfo.thermalState.rawValue
                        let filtering = filter == "null" ? "" : "-vf \(filter)"
                        try await FFmpegCommandRunner().run(
                            "-y -mb-acceleration \(mode) -i \(FFmpegCommandRunner.quoted(source.path)) \(filtering) -c:v hevc_videotoolbox -b:v 4000k -an -tag:v hvc1 \(FFmpegCommandRunner.quoted(output.path))",
                            duration: 4, progress: { _ in }, onLogLine: { logs.append($0) })
                        getrusage(RUSAGE_SELF, &after)
                        let elapsed = ProcessInfo.processInfo.systemUptime - start
                        func cpuTime(_ value: rusage) -> Double {
                            Double(value.ru_utime.tv_sec + value.ru_stime.tv_sec)
                            + Double(value.ru_utime.tv_usec + value.ru_stime.tv_usec) / 1_000_000
                        }
                        samples.append(["width": 3840, "hdr": hdr, "filter": filter, "mode": mode,
                                        "warmup": repetition == 0, "seconds": elapsed,
                                        "cpuSeconds": cpuTime(after) - cpuTime(before), "processPeakRSS": after.ru_maxrss,
                                        "thermalStart": thermal, "thermalEnd": ProcessInfo.processInfo.thermalState.rawValue,
                                        "pipeline": logs.text])
                        print("MBF_ROTATION hdr=\(hdr) filter=\(filter) mode=\(mode) warmup=\(repetition == 0) seconds=\(elapsed)")
                    }
                }
                validateAutomaticPerformance(samples.filter { $0["hdr"] as? Bool == hdr && $0["filter"] as? String == filter })
            }
            try FileManager.default.removeItem(at: source)
        }
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]),
                                       uniformTypeIdentifier: "public.json")
        attachment.name = "VideoToolbox rotation qualification"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func validateAutomaticPerformance(_ samples: [[String: Any]]) {
        let measured = samples.filter { $0["warmup"] as? Bool == false }
        let automatic = measured.filter { $0["mode"] as? String == "auto" }
        let reference = measured.filter { $0["mode"] as? String == "off" }
        guard automatic.contains(where: { ($0["pipeline"] as? String)?.contains("decode=VideoToolbox") == true }) else {
            print("MBF_QUALIFICATION: automatic hardware decoding/filtering withheld for this path")
            return
        }
        func median(_ rows: [[String: Any]], _ key: String) -> Double {
            let values = rows.compactMap { $0[key] as? Double }.sorted()
            return values[values.count / 2]
        }
        let timeRatio = median(automatic, "seconds") / median(reference, "seconds")
        let cpuRatio = median(automatic, "cpuSeconds") / median(reference, "cpuSeconds")
        print("MBF_QUALIFICATION: automatic timeRatio=\(timeRatio) cpuRatio=\(cpuRatio)")
        XCTAssertLessThanOrEqual(timeRatio, 1.05, "An automatically enabled path regressed elapsed time")
        XCTAssertTrue(timeRatio < 0.95 || cpuRatio < 0.95, "An automatically enabled path provided no measurable benefit")
    }

    func testVideoCancellationOnDevice() async throws {
        try requireDevice()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        let output = directory.appendingPathComponent("output.mp4")
        try await makeVideo(at: source, width: 1920, height: 1080, hdr: true, frames: 96)
        let runner = FFmpegCommandRunner()
        let logs = Logs()
        do {
            try await runner.run(
                "-y -mb-acceleration auto -i \(FFmpegCommandRunner.quoted(source.path)) -vf scale=960:540 -c:v hevc_videotoolbox -b:v 2000k -an \(FFmpegCommandRunner.quoted(output.path))",
                duration: 4, progress: { if $0 > 0 { runner.cancel() } }, onLogLine: { logs.append($0) })
            XCTFail("Cancelled video conversion completed")
        } catch {
            guard case ConversionError.cancelled = error else { throw error }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertFalse(logs.text.contains("MBF_RETRY"))
    }

    func testExternalHDRFixtures() async throws {
        try requireDevice()
        let documents = try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
        let sources = ["mb-dovi-validation.mp4", "mb-pq-validation.mp4"].map { documents.appendingPathComponent($0) }
        guard sources.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("Copy the pinned Dolby 8.4 and generated PQ fixtures into the app's Documents directory")
        }
        defer { for source in sources { try? FileManager.default.removeItem(at: source) } }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for source in sources {
            let input = try await MediaInspector.inspect(url: source)
            XCTAssertEqual(input.videoColor?.isHDR, true)
            for preserveHDR in [true, false] {
                let output = directory.appendingPathComponent("output.mp4")
                try await FFmpegCommandRunner().run(
                    "-y -mb-acceleration \(preserveHDR ? "required" : "auto") -i \(FFmpegCommandRunner.quoted(source.path)) -vf scale=160:96 -c:v \(preserveHDR ? "hevc_videotoolbox" : "h264_videotoolbox") -b:v 1500k -an \(preserveHDR ? "-tag:v hvc1" : "") \(FFmpegCommandRunner.quoted(output.path))",
                    duration: input.duration, progress: { _ in })
                let result = try await MediaInspector.inspect(url: output)
                XCTAssertEqual(result.videoColor?.isHDR, preserveHDR)
                XCTAssertEqual(result.videoColor?.bitDepth, preserveHDR ? 10 : 8)
                XCTAssertEqual(result.videoColor?.transfer, preserveHDR ? input.videoColor?.transfer : "bt709")
                XCTAssertNil(result.videoColor?.dolbyVisionProfile)
                try await verifyPlayback(output)
            }
        }
    }

    private func verifyPlayback(_ url: URL, frames: Int? = nil) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(output)
        XCTAssertTrue(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        if let frames { XCTAssertEqual(count, frames) }
        else { XCTAssertGreaterThan(count, 0) }
    }

    func testLockedScreenHardwareConversion() async throws {
        try requireDevice()
        guard ProcessInfo.processInfo.environment["MBF_LOCKED_SCREEN_TEST"] == "1" else {
            throw XCTSkip("Run with MBF_LOCKED_SCREEN_TEST=1 and lock the iPhone after the ready marker")
        }
        executionTimeAllowance = 180
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.mov")
        try await makeVideo(at: source, width: 1920, height: 1080, hdr: true, frames: 96)
        let controller = ConversionBackgroundController(platform: SystemBackgroundExecution(), notifications: FakeWarnings())
        var completed = false
        defer { controller.finish(success: completed) }
        let ready = expectation(description: "Background execution available")
        var mode: ConversionBackgroundMode?
        var expired = false
        let runner = FFmpegCommandRunner()
        controller.start(id: UUID(), title: "Video acceleration verification", subtitle: "Checking locked-screen conversion",
                         ready: { mode = $0; ready.fulfill() }, expired: { expired = true; runner.cancel() })
        await fulfillment(of: [ready], timeout: 15)
        guard mode == .extended else { throw XCTSkip("System declined extended background execution") }
        NSLog("MBF_LOCK_TEST_READY: lock the iPhone now")
        let started = ProcessInfo.processInfo.systemUptime
        var backgroundStarted: TimeInterval?
        var backgroundJobs = 0
        var completedJobs: Int64 = 0
        let logs = Logs()
        let output = directory.appendingPathComponent("output.mp4")
        while ProcessInfo.processInfo.systemUptime - started < 150 {
            let backgrounded = UIApplication.shared.applicationState == .background
            controller.setBackgrounded(backgrounded)
            if backgrounded && backgroundStarted == nil {
                backgroundStarted = ProcessInfo.processInfo.systemUptime
                NSLog("MBF_LOCK_TEST_BACKGROUND")
            }
            try await runner.run(
                "-y -mb-acceleration auto -i \(FFmpegCommandRunner.quoted(source.path)) -vf transpose=clock,scale=540:960 -c:v hevc_videotoolbox -b:v 2000k -an -tag:v hvc1 \(FFmpegCommandRunner.quoted(output.path))",
                duration: 4, progress: { _ in }, onLogLine: { logs.append($0) })
            if UIApplication.shared.applicationState == .background { backgroundJobs += 1 }
            completedJobs += 1
            // Mirror the production session's actual-work progress updates.
            // A repeated-job test has no known total, but it must not appear
            // stalled to the continued-processing scheduler.
            controller.recordProcessedUnits(completedJobs * 4_000_000)
            controller.update(fraction: nil, stage: "Verifying HDR conversion")
            controller.tick()
            XCTAssertFalse(expired, "Background execution expired during conversion")
            if expired { break }
            if let backgroundStarted, backgroundJobs >= 3,
               ProcessInfo.processInfo.systemUptime - backgroundStarted >= 10 {
                completed = true
                break
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertNotNil(backgroundStarted, "The iPhone was not placed in the background during the test")
        XCTAssertGreaterThanOrEqual(backgroundJobs, 3)
        XCTAssertTrue(completed, "Did not complete at least ten seconds of background conversion")
        let result = try await MediaInspector.inspect(url: output)
        XCTAssertEqual(result.videoColor?.bitDepth, 10)
        XCTAssertEqual(result.videoColor?.isHDR, true)
        XCTAssertEqual(result.dimensions, CGSize(width: 540, height: 960))
        let backgroundSeconds = backgroundStarted.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let attachment = XCTAttachment(string: "backgroundJobs=\(backgroundJobs) backgroundSeconds=\(backgroundSeconds)\n" + logs.text)
        attachment.name = "Locked-screen VideoToolbox conversion"
        attachment.lifetime = .keepAlways
        add(attachment)
        NSLog("MBF_LOCK_TEST_COMPLETE backgroundJobs=%d", backgroundJobs)
    }

    private func makeVideo(at url: URL, width: Int, height: Int, hdr: Bool, frames: Int) async throws {
        let writer = try AVAssetWriter(url: url, fileType: .mov)
        let color: [String: Any] = [
            AVVideoColorPrimariesKey: hdr ? AVVideoColorPrimaries_ITU_R_2020 : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: hdr ? AVVideoTransferFunction_ITU_R_2100_HLG : AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: hdr ? AVVideoYCbCrMatrix_ITU_R_2020 : AVVideoYCbCrMatrix_ITU_R_709_2
        ]
        var compression: [String: Any] = [AVVideoAverageBitRateKey: 12_000_000]
        if hdr { compression[AVVideoProfileLevelKey] = "HEVC_Main10_AutoLevel" }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: color, AVVideoCompressionPropertiesKey: compression
        ])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        writer.add(input)
        guard writer.startWriting() else { throw try XCTUnwrap(writer.error) }
        writer.startSession(atSourceTime: .zero)
        for index in 0..<frames {
            while !input.isReadyForMoreMediaData {
                if writer.status == .failed { throw try XCTUnwrap(writer.error) }
                try await Task.sleep(for: .milliseconds(1))
            }
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, try XCTUnwrap(adapter.pixelBufferPool), &buffer), kCVReturnSuccess)
            let pixel = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixel, [])
            for plane in 0..<2 {
                let address = try XCTUnwrap(CVPixelBufferGetBaseAddressOfPlane(pixel, plane))
                let stride = CVPixelBufferGetBytesPerRowOfPlane(pixel, plane)
                let rows = CVPixelBufferGetHeightOfPlane(pixel, plane)
                if hdr {
                    let values = address.assumingMemoryBound(to: UInt16.self)
                    for row in 0..<rows {
                        let value = UInt16(plane == 0 ? 64 + ((row + index * 7) % 877) : 512) << 6
                        values.advanced(by: row * stride / 2).update(repeating: value, count: stride / 2)
                    }
                } else {
                    for row in 0..<rows {
                        memset(address.advanced(by: row * stride), Int32(plane == 0 ? 16 + ((row + index * 7) % 220) : 128), stride)
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(pixel, [])
            guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 24)) else {
                throw try XCTUnwrap(writer.error)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw try XCTUnwrap(writer.error) }
    }
}
