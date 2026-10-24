import AVFoundation
import Foundation
import ImageIO
import Testing
@testable import Converter

/// Time limits turn a hang on slow CI runners into a named failure instead of a job timeout.
@Suite(.timeLimit(.minutes(3)))
struct ImageMagickFormatTests {
    @Test func runtimeIsLinkedWithExpectedCoders() {
        #expect(Magick.isAvailable)
        #expect(Magick.version.contains("ImageMagick 7"))
        for coder in ["psd", "tga", "ico", "jxl", "jp2", "qoi", "pcx", "dds", "sgi", "xpm", "hdr", "eps", "pdf"] {
            #expect(Magick.canWrite(coder), "missing writer \(coder)")
        }
        for coder in ["psd", "tga", "ico", "jxl", "jp2", "qoi", "pcx", "dds"] {
            #expect(Magick.canRead(coder), "missing reader \(coder)")
        }
        #expect(!Magick.canRead("eps"), "EPS reading needs Ghostscript, which must not be bundled")
    }

    @Test(arguments: ImageToolkit.OutputFormat.available.filter { $0 != .eps })
    func roundTripsThroughEveryWritableFormat(format: ImageToolkit.OutputFormat) throws {
        let source = TestSupport.makeImage(width: 200, height: 120)
        let data = try ImageToolkit.encode(source, as: format, quality: 0.85)
        let url = TestSupport.tempURL(format.fileExtension)
        try data.write(to: url)
        let decoded = try ImageToolkit.load(url)
        let expected = format == .ico ? CGSize(width: 200, height: 120) : CGSize(width: 200, height: 120)
        #expect(CGSize(width: decoded.width, height: decoded.height) == expected, "\(format) decoded at \(decoded.width)×\(decoded.height)")
    }

    @Test func writesEPSWithoutGhostscript() throws {
        let data = try ImageToolkit.encode(TestSupport.makeImage(width: 64, height: 64), as: .eps)
        #expect(String(decoding: data.prefix(10), as: UTF8.self).hasPrefix("%!PS-Adobe"))
    }

    @Test func icoOutputIsCappedAt256() throws {
        let data = try ImageToolkit.encode(TestSupport.makeImage(width: 1024, height: 512), as: .ico)
        let url = TestSupport.tempURL("ico")
        try data.write(to: url)
        let info = try Magick.identify(url)
        #expect(max(info.width, info.height) <= 256)
    }

    @Test func psdDecodesAndRoutesToHub() throws {
        let psd = TestSupport.tempURL("psd")
        try ImageToolkit.encode(TestSupport.makeImage(width: 90, height: 60), as: .psd).write(to: psd)
        #expect(!FileIntake.opensInMediaConverter(.psd))
        #expect(FileIntake.opensInMediaConverter(.png))
        let image = try ImageToolkit.load(psd)
        #expect(image.width == 90)
        #expect(ConversionTargets.targets(for: .psd).contains(.png))
        #expect(ConversionTargets.targets(for: .eps).isEmpty)
    }

    @Test func avifFallsBackToSVTAV1() throws {
        // Odd dimensions exercise the 4:2:0 padding path.
        let data = try ImageToolkit.encodeAVIFWithFFmpeg(TestSupport.makeImage(width: 81, height: 47), quality: 0.7)
        #expect(data.count > 100)
        #expect(String(decoding: data.dropFirst(4).prefix(8), as: UTF8.self).hasPrefix("ftypavi"))
    }

    @Test func rejectsOversizedImagesCleanly() throws {
        let bomb = TestSupport.tempURL("ppm")
        try Data("P6\n40000 40000\n255\n".utf8).write(to: bomb)
        #expect(throws: (any Error).self) { try Magick.convert(bomb, to: TestSupport.tempURL("png"), format: "png") }
    }
}

@Suite(.serialized, .timeLimit(.minutes(5)))
struct ExtendedVideoFormatTests {
    @Test func newEncodersAreAvailable() {
        #expect(FFmpegRuntimeInfo.hasEncoder("libsvtav1"))
        #expect(FFmpegRuntimeInfo.hasEncoder("libwebp_anim"))
        #expect(FFmpegRuntimeInfo.hasEncoder("libtheora"))
        #expect(CodecCapability.canEncode(.mp4_av1))
        #expect(CodecCapability.canEncode(.ogv))
        #expect(FormatMatrix.allowedOutputs(for: .video).contains(.mp4_av1))
    }

    @Test(arguments: [OutputFormat.mp4_av1, .ogv])
    func convertsVideoThroughTheMainPipeline(format: OutputFormat) async throws {
        let source = try await MediaFixtures.video(seconds: 1.5)
        let media = try await ImportService().validatedMediaFile(at: source)
        let config = ConversionConfig(outputFormat: format)
        let converter = try ConversionRouter.converter(for: media, config: config)
        let result = try await converter.convert(input: media, config: config, progress: { _ in }, encodingStats: nil)
        let output = try await MediaInspector.inspect(url: result.url)
        #expect(output.category == .video)
        let codec = output.videoCodec?.lowercased() ?? ""
        let accepted: Set<String> = format == .mp4_av1 ? ["av1", "av01"] : ["theora"]
        #expect(accepted.contains(codec), "got \(codec)")
        #expect(abs((output.duration ?? 0) - 1.5) < 0.3)
    }

    /// The reason for the GPL runtime: VideoToolbox can't do two passes, so H.264 target sizes were a guess.
    @Test func h264TargetSizeLandsOnTargetWithX264TwoPass() async throws {
        #expect(FFmpegRuntimeInfo.hasEncoder("libx264"), "The bundled runtime must include libx264")
        let source = try await MediaFixtures.video(seconds: 6, width: 640, height: 360)
        let media = try await MediaInspector.inspect(url: source)
        let target: Int64 = 260_000
        let config = ConversionConfig(outputFormat: .mp4_h264, targetSizeBytes: target)
        #expect(config.usesTwoPassVideoEncoding)
        let result = try await VideoConverter().convert(input: media, config: config, progress: { _ in })
        defer { try? FileManager.default.removeItem(at: result.url) }
        let error = abs(Double(result.sizeOnDisk - target)) / Double(target)
        #expect(error < 0.12, "Two-pass output was \(result.sizeOnDisk) bytes for a \(target)-byte target (\(Int(error * 100))% off)")
        #expect(result.videoCodec?.lowercased().contains("h264") == true || result.videoCodec?.lowercased().contains("avc") == true,
                "Got \(result.videoCodec ?? "nil")")
        #expect(abs((result.duration ?? 0) - 6) < 0.5)
        // No pass statistics are left behind.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        #expect(!leftovers.contains { $0.hasSuffix("-0.log") || $0.hasSuffix(".mbtree") }, "Pass logs left in tmp: \(leftovers.filter { $0.contains(".log") })")
    }

    @Test(arguments: [MediaToolkit.AnimationFormat.gif, .webp])
    func makesAnimations(format: MediaToolkit.AnimationFormat) async throws {
        let source = try await MediaFixtures.video(seconds: 2)
        let output = TestSupport.tempURL(format.fileExtension)
        try await MediaToolkit.makeAnimation(source, start: 0.5, duration: 1, fps: 10, width: 160, format: format, output: output)
        let image = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        #expect(CGImageSourceGetCount(image) >= 8)
        #expect(CGImageSourceCreateImageAtIndex(image, 0, nil)?.width == 160)
    }

    @Test func animationCommandsStayInsideAdapterSubset() throws {
        let command = MediaToolkit.animationCommand(URL(fileURLWithPath: "/tmp/a b.mp4"), start: 1, duration: 2, fps: 12, width: 480,
                                                    format: .webp, output: URL(fileURLWithPath: "/tmp/o.webp"))
        let arguments = try FFmpegCommandRunner.arguments(in: command)
        #expect(arguments.filter { $0 == "-i" }.count == 1)
        #expect(arguments.contains("-mb-muxer-opt") && arguments.contains("loop=0"))
        #expect(arguments.contains("24") && arguments.contains("-frames:v"))
    }
}

