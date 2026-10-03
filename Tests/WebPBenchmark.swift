import Foundation
import CoreGraphics
import Darwin
import libwebp

@main
struct WebPBenchmark {
    private final class Timings: @unchecked Sendable {
        private let lock = NSLock()
        private var preparation: Double?
        private var encoding: Double?
        private var saving: Double?
        func record(_ stats: FFmpegEncodingDisplayStats) {
            let now = ProcessInfo.processInfo.systemUptime
            lock.lock(); defer { lock.unlock() }
            if stats.activity == "Preparing pixels…", preparation == nil { preparation = now }
            if stats.activity?.hasPrefix("Encoding WebP") == true, encoding == nil { encoding = now }
            if stats.activity == "Saving image…", saving == nil { saving = now }
        }
        func durations(start: Double, end: Double) -> [String: Double] {
            lock.lock(); defer { lock.unlock() }
            return ["decode_edit_seconds": (preparation ?? start) - start,
                    "prepare_seconds": (encoding ?? start) - (preparation ?? start),
                    "encode_seconds": (saving ?? end) - (encoding ?? start),
                    "save_seconds": end - (saving ?? end), "total_seconds": end - start]
        }
    }

    static func main() async throws {
        let args = CommandLine.arguments
        if args[1] == "generate" {
            let directory = URL(fileURLWithPath: args[2])
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var manifest: [[String: Any]] = []
            for (kind, width, height) in [("photo", 511, 383), ("gradient", 1024, 768),
                ("text", 1024, 768), ("noise", 1024, 768), ("alpha", 511, 383),
                ("photo", 4032, 3024), ("photo", 8064, 6048)] {
                let heic = width >= 4032
                let name = "\(kind)-\(width)x\(height)"
                let url = directory.appendingPathComponent(name + (heic ? ".heic" : ".png"))
                try autoreleasepool {
                    try WebPFixtures.write(WebPFixtures.image(kind: kind, width: width, height: height), to: url, heic: heic)
                }
                manifest.append(["name": name, "path": url.path, "opaque": kind != "alpha",
                                 "synthetic": true, "width": width, "height": height])
            }
            try emit(manifest)
            return
        }
        let input = try WebPFixtures.input(URL(fileURLWithPath: args[2]))
        let quality = Double(args[3])!
        let timings = Timings()
        let start = ProcessInfo.processInfo.systemUptime
        let result = try await ImageConverter().convert(input: input,
            config: ConversionConfig(outputFormat: .webpImage, imageQuality: quality),
            progress: { _ in }, encodingStats: { timings.record($0) })
        let end = ProcessInfo.processInfo.systemUptime
        // Capture before validation decodes allocate additional full-sized buffers.
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        var report: [String: Any] = timings.durations(start: start, end: end)
        report["peak_rss_bytes"] = usage.ru_maxrss
        report["output_bytes"] = result.sizeOnDisk
        let output = URL(fileURLWithPath: args[4])
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: result.url, to: output)
        let data = try Data(contentsOf: output)
        var width: Int32 = 0, height: Int32 = 0
        let decoded = data.withUnsafeBytes {
            WebPDecodeRGBA($0.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count, &width, &height)
        }
        try WebPFixtures.require(decoded != nil, "Benchmark WebP must decode")
        defer { WebPFree(decoded) }
        let original = WebPFixtures.read(input.url)
        try WebPFixtures.require(Int(width) == original.width && Int(height) == original.height, "Dimensions changed")
        let reference = try WebPFixtures.rgba(original)
        var squaredError = 0.0
        var alphaError = 0
        var opaque = true
        for i in stride(from: 0, to: reference.count, by: 4) {
            opaque = opaque && reference[i+3] == 255
            alphaError = max(alphaError, abs(Int(reference[i+3]) - Int(decoded![i+3])))
            for c in 0..<3 {
                let delta = Double(reference[i+c]) - Double(decoded![i+c])
                squaredError += delta * delta
            }
        }
        report["opaque"] = opaque
        report["alpha_max_error"] = alphaError
        let mse = squaredError / Double(Int(width) * Int(height) * 3)
        report["rgb_psnr_db"] = mse == 0 ? 100 : 10 * log10(255 * 255 / mse)
        report["width"] = width
        report["height"] = height
        try emit(report)
    }

    private static func emit(_ value: Any) throws {
        FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
