import AVFoundation
import Foundation
import Testing
@testable import Converter

/// Synthesizes clips with AVAssetWriter so tests need no binary fixtures.
enum MediaFixtures {
    static func video(seconds: Double = 2, withAudio: Bool = true, width: Int = 320, height: Int = 240) async throws -> URL {
        let url = TestSupport.tempURL("mov")
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
            writer.add(input)
            audioInput = input
        }
        guard writer.startWriting() else { throw writer.error ?? ConversionError.engineFailed("writer") }
        writer.startSession(atSourceTime: .zero)

        // Interleave video frames and audio chunks; AVAssetWriter stalls if one track runs far ahead.
        let fps = 15
        let frameCount = Int(seconds * Double(fps))
        var sine = SineGenerator(frequency: 440, totalSamples: Int(seconds * 44_100))
        for frame in 0 ..< frameCount {
            while !videoInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(1)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let pixelBuffer = buffer!
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer)!, Int32((frame * 9) % 255), CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: CMTimeScale(fps)))
            if let audioInput {
                let until = Int(Double(frame + 1) / Double(fps) * 44_100)
                try await sine.append(to: audioInput, upTo: until)
            }
        }
        videoInput.markAsFinished()
        if let audioInput {
            try await sine.append(to: audioInput, upTo: sine.totalSamples)
            audioInput.markAsFinished()
        }
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? ConversionError.engineFailed("writer") }
        return url
    }

    static func audio(seconds: Double = 2, frequency: Double = 440) async throws -> URL {
        let url = TestSupport.tempURL("m4a")
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

@Suite(.serialized)
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
