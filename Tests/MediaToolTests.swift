import AVFoundation
import Foundation
import Testing
@testable import Converter

/// Clip synthesis lives in the app (`SelfTestFixtures`) so the in-app self-test uses the same inputs.
enum MediaFixtures {
    static func video(seconds: Double = 2, withAudio: Bool = true, width: Int = 320, height: Int = 240) async throws -> URL {
        try await SelfTestFixtures.video(seconds: seconds, withAudio: withAudio, width: width, height: height)
    }

    static func audio(seconds: Double = 2, frequency: Double = 440) async throws -> URL {
        try await SelfTestFixtures.audio(seconds: seconds, frequency: frequency)
    }
}

struct MediaCommandTests {
    @Test func audioEditFilters() {
        var edit = MediaToolkit.AudioEdit()
        #expect(edit.filter(duration: 10) == "anull")
        #expect(edit.isIdentity)
        edit.volumeDB = -3
        edit.fadeOut = 2
        #expect(edit.filter(duration: 10) == "volume=-3.0dB,afade=t=out:st=8.00:d=2.00")
        edit.volumeDB = 4
        #expect(edit.filter(duration: 10).hasSuffix("alimiter=limit=0.97"))
    }

    @Test func audioCommandStaysInsideAdapterSubset() throws {
        let command = MediaToolkit.editAudioCommand(URL(fileURLWithPath: "/tmp/in put.m4a"), edit: .init(volumeDB: 2), duration: 5, output: URL(fileURLWithPath: "/tmp/out.m4a"))
        let arguments = try FFmpegCommandRunner.arguments(in: command)
        #expect(arguments.filter { $0 == "-i" }.count == 1)
        #expect(arguments.contains("-af"))
        #expect(arguments.contains("/tmp/in put.m4a"))
        #expect(!arguments.contains("-filter_complex"))
    }

    @Test func orientationTransformsSwapDimensions() {
        let size = CGSize(width: 320, height: 240)
        let (transform, render) = MediaToolkit.Orientation.clockwise.transform(for: size)
        #expect(render == CGSize(width: 240, height: 320))
        let corner = CGPoint(x: 320, y: 0).applying(transform)
        #expect(abs(corner.x - 240) < 0.001 && abs(corner.y - 320) < 0.001)
        #expect(MediaToolkit.Orientation.mirror.transform(for: size).1 == size)
    }
}

/// Time limits turn a hang on slow CI runners into a named failure instead of a job timeout.
@Suite(.serialized, .timeLimit(.minutes(5)))
struct MediaToolRunTests {
    @Test func trimsVideoPreciselyAndFast() async throws {
        let source = try await MediaFixtures.video(seconds: 3)
        for precise in [true, false] {
            let output = TestSupport.tempURL("mp4")
            try await MediaToolkit.trim(source, start: 0.5, end: 1.5, precise: precise, output: output)
            let probe = try await MediaToolkit.probe(output)
            #expect(abs(probe.duration - 1.0) < 0.5, "precise=\(precise) duration \(probe.duration)")
            #expect(probe.hasAudio && probe.hasVideo)
        }
    }

    @Test func mutesVideo() async throws {
        let output = TestSupport.tempURL("mp4")
        try await MediaToolkit.mute(try await MediaFixtures.video(), output: output)
        let probe = try await MediaToolkit.probe(output)
        #expect(probe.hasVideo && !probe.hasAudio)
    }

    @Test func makesGIF() async throws {
        let data = try await MediaToolkit.makeGIF(try await MediaFixtures.video(seconds: 2), start: 0, duration: 1, fps: 10, width: 160)
        let image = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(image) >= 8)
        #expect(CGImageSourceCreateImageAtIndex(image, 0, nil)?.width == 160)
    }

    @Test func rotatesVideo() async throws {
        let output = TestSupport.tempURL("mp4")
        try await MediaToolkit.reorient(try await MediaFixtures.video(), .clockwise, output: output)
        #expect(try await MediaToolkit.probe(output).size == CGSize(width: 240, height: 320))
    }

    @Test func changesSpeed() async throws {
        let output = TestSupport.tempURL("mp4")
        try await MediaToolkit.speed(try await MediaFixtures.video(seconds: 2), factor: 2, output: output)
        #expect(abs(try await MediaToolkit.probe(output).duration - 1.0) < 0.3)
    }

    @Test func loopsVideo() async throws {
        let output = TestSupport.tempURL("mp4")
        try await MediaToolkit.loop(try await MediaFixtures.video(seconds: 1), times: 3, output: output)
        #expect(abs(try await MediaToolkit.probe(output).duration - 3) < 0.4)
    }

    @Test func mergesClipsWithAndWithoutAudio() async throws {
        let first = try await MediaFixtures.video(seconds: 1, withAudio: true)
        let second = try await MediaFixtures.video(seconds: 1, withAudio: false, width: 160, height: 120)
        let output = TestSupport.tempURL("mp4")
        try await MediaToolkit.concatenateVideos([first, second], output: output)
        let probe = try await MediaToolkit.probe(output)
        #expect(abs(probe.duration - 2) < 0.4)
        #expect(probe.size == CGSize(width: 320, height: 240))
        #expect(probe.hasAudio)
    }

    @Test func extractsFrames() async throws {
        let frames = try await MediaToolkit.extractFrames(try await MediaFixtures.video(seconds: 2), everySeconds: 0.5, duration: 2)
        #expect(frames.count == 4)
        #expect(frames[0].width == 320)
    }

    @Test func joinsAndAdjustsAudio() async throws {
        let joined = TestSupport.tempURL("m4a")
        try await MediaToolkit.concatenateAudio([try await MediaFixtures.audio(seconds: 1), try await MediaFixtures.audio(seconds: 1, frequency: 660)], output: joined)
        #expect(abs(try await MediaToolkit.probe(joined).duration - 2) < 0.3)
        let adjusted = TestSupport.tempURL("m4a")
        try await MediaToolkit.editAudio(joined, edit: .init(volumeDB: -6, fadeIn: 0.3, fadeOut: 0.3), output: adjusted)
        #expect(abs(try await MediaToolkit.probe(adjusted).duration - 2) < 0.3)
    }

    @Test func replacesSoundtrack() async throws {
        let output = TestSupport.tempURL("mp4")
        try await MediaToolkit.replaceAudio(video: try await MediaFixtures.video(seconds: 2, withAudio: false), audio: try await MediaFixtures.audio(seconds: 0.5), loopAudio: true, output: output)
        let probe = try await MediaToolkit.probe(output)
        #expect(probe.hasAudio && probe.hasVideo)
        #expect(abs(probe.duration - 2) < 0.3)
    }
}
