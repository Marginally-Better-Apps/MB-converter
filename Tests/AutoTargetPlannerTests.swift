import Foundation
import CoreGraphics

// Standalone regression suite: bash Scripts/TestAutoTargetPlanner.sh
@main
struct AutoTargetPlannerTests {
    static func main() {
        let input = fixture()
        let resolutionPlan = plan(input, bytes: 20_000_000)
        check(resolutionPlan.targetDimensions == CGSize(width: 1280, height: 720), "Reduce resolution before FPS")
        check(resolutionPlan.targetFPS == nil, "Keep source 60 FPS at moderate targets")
        check(resolutionPlan.audioBitrateKbps == 192, "Preserve audio while reducing resolution")

        let fpsPlan = plan(input, bytes: 14_000_000)
        check(fpsPlan.targetDimensions == CGSize(width: 1280, height: 720), "Allow FPS adjustment before reaching minimum resolution")
        check(fpsPlan.targetFPS == 30, "Try FPS after the first resolution step")
        check(fpsPlan.audioBitrateKbps == 192, "Preserve audio while reducing FPS")

        let audioPlan = plan(input, bytes: 3_000_000)
        check(audioPlan.targetDimensions == CGSize(width: 640, height: 360), "Keep minimum resolution in audio stage")
        check(audioPlan.targetFPS == 15, "Exhaust FPS before reducing audio")
        check(audioPlan.audioBitrateKbps == 64 && audioPlan.isTargetReachable, "Reduce audio only for very small targets")

        check(plan(fixture(audioKbps: 320), bytes: 50_000_000).audioBitrateKbps == 320, "Do not cap source audio at 192 kbps")
        check(plan(fixture(audioKbps: 157), bytes: 50_000_000).audioBitrateKbps == 157, "Preserve non-preset source audio bitrate")
        check(plan(fixture(audioKbps: nil), bytes: 10_000_000).audioBitrateKbps == 192, "Unknown source audio uses a stable default")
        check(plan(input, bytes: 5_000_000, includesAudio: false).audioBitrateKbps == 0, "Do not introduce audio")

        let locked = plan(input, bytes: 1, dimensions: CGSize(width: 1280, height: 720), fps: 24,
                          audioKbps: 128, locks: .manual)
        check(locked.targetDimensions == CGSize(width: 1280, height: 720) && locked.targetFPS == 24,
              "Unreachable targets respect locked resolution and FPS")
        check(locked.audioBitrateKbps == 128 && !locked.isTargetReachable, "Unreachable targets respect locked audio")
        let fpsLocked = plan(input, bytes: 3_000_000, locks: .init(resolution: false, fps: true, audioQuality: false))
        check(fpsLocked.targetFPS == nil, "FPS lock preserves the source rate even for tiny targets")
        let audioLocked = plan(input, bytes: 3_000_000, locks: .init(resolution: false, fps: false, audioQuality: true))
        check(audioLocked.audioBitrateKbps == 192 && !audioLocked.isTargetReachable, "Audio lock prevents last-resort reductions")
        let resolutionLocked = plan(input, bytes: 20_000_000, locks: .init(resolution: true, fps: false, audioQuality: false))
        check(resolutionLocked.targetDimensions == nil && resolutionLocked.targetFPS != nil,
              "Resolution lock skips directly to FPS adjustments")

        for format in [OutputFormat.mp4_h264, .mp4_hevc, .mov, .webm] {
            var previous = plan(input, bytes: 50_000_000, format: format)
            for bytes in stride(from: Int64(49_750_000), through: 250_000, by: -250_000) {
                let current = plan(input, bytes: bytes, format: format)
                check((current.targetDimensions ?? input.dimensions!).height <= (previous.targetDimensions ?? input.dimensions!).height,
                      "Shrinking targets must not raise resolution")
                check((current.targetFPS ?? 60) <= (previous.targetFPS ?? 60), "Shrinking targets must not raise FPS")
                check(current.audioBitrateKbps <= previous.audioBitrateKbps, "Shrinking targets must not raise audio bitrate")
                if current.targetFPS != nil {
                    check(current.targetDimensions != nil, "Try a resolution reduction before FPS")
                }
                let originalAudio = format == .webm ? 128 : 192
                if current.audioBitrateKbps < originalAudio {
                    check(current.targetFPS == 15 && current.targetDimensions == CGSize(width: 640, height: 360),
                          "Audio reductions must follow video adjustments")
                }
                previous = current
            }
        }

        let config = ConversionConfig(outputFormat: .mp4_h264, targetSizeBytes: 14_000_000,
                                      operationMode: .autoTarget, autoTargetLockPolicy: .unlocked)
        check(AutoTargetPlanner.videoPlan(input: input, config: config, includesAudio: true) == fpsPlan,
              "Export and slider preview must use the same plan")
        print("Auto target planner tests passed")
    }

    private static func fixture(audioKbps: Int? = 192) -> MediaFile {
        MediaFile(url: URL(fileURLWithPath: "/tmp/planner-test.mp4"), originalFilename: "planner-test.mp4",
                  category: .video, sizeOnDisk: 62_668_800, dimensions: CGSize(width: 1920, height: 1080),
                  duration: 60, fps: 60, bitrate: 8_192_000, audioBitrate: audioKbps.map { $0 * 1000 },
                  videoCodec: "h264", audioCodec: "aac", containerFormat: "mp4")
    }

    private static func plan(_ input: MediaFile, bytes: Int64, format: OutputFormat = .mp4_h264,
                             dimensions: CGSize? = nil, fps: Double? = nil, audioKbps: Int? = nil,
                             locks: AutoTargetLockPolicy = .unlocked, includesAudio: Bool = true) -> AutoTargetVideoPlan {
        AutoTargetPlanner.videoPlan(input: input, outputFormat: format, targetBytes: bytes,
                                    lockedDimensions: dimensions, lockedFPS: fps, preferredAudioBitrateKbps: audioKbps,
                                    lockPolicy: locks, includesAudio: includesAudio)
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }
}
