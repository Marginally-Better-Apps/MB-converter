import Foundation

#if canImport(MBFFmpegBridge)
import MBFFmpegBridge
#endif

struct FFmpegRuntimeInfo: Sendable {
    let packageName: String
    let ffmpegVersion: String
    /// Retained for compatibility with saved diagnostics. FFmpegKit is no longer bundled.
    let ffmpegKitVersion: String
    let buildDate: String
    let externalLibraries: [String]
    let license: String
    let buildConfiguration: String

    static let current = FFmpegRuntimeInfo.load()

    var isMinPackage: Bool { packageName.lowercased() == "min" }

    func hasExternalLibrary(_ name: String) -> Bool {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return externalLibraries.contains { $0.lowercased() == needle }
    }

    static func hasEncoder(_ name: String) -> Bool {
        #if canImport(MBFFmpegBridge)
        return name.withCString { mbf_has_encoder($0) != 0 }
        #else
        return false
        #endif
    }

    static func hasDecoder(_ name: String) -> Bool {
        #if canImport(MBFFmpegBridge)
        return name.withCString { mbf_has_decoder($0) != 0 }
        #else
        return false
        #endif
    }

    static func hasMuxer(_ name: String) -> Bool {
        #if canImport(MBFFmpegBridge)
        return name.withCString { mbf_has_muxer($0) != 0 }
        #else
        return false
        #endif
    }

    static func logSummary() {
        let info = current
        let libraries = info.externalLibraries.isEmpty ? "none" : info.externalLibraries.sorted().joined(separator: ", ")
        print("[FFMPEG RUNTIME] package=\(info.packageName) ffmpeg=\(info.ffmpegVersion) license=\(info.license) externalLibraries=\(libraries)")
    }

    private static func load() -> FFmpegRuntimeInfo {
        #if canImport(MBFFmpegBridge)
        let configuration = mbf_configuration().map { String(cString: $0) } ?? "unknown"
        let libraries = configuration.split(whereSeparator: \.isWhitespace).compactMap { option -> String? in
            guard option.hasPrefix("--enable-lib") else { return nil }
            return String(option.dropFirst("--enable-".count))
        }
        return FFmpegRuntimeInfo(
            packageName: "mb-custom-lgpl",
            ffmpegVersion: mbf_version().map { String(cString: $0) } ?? "unknown",
            ffmpegKitVersion: "not used (MBFFmpegBridge)",
            buildDate: "see bundled build manifest",
            externalLibraries: libraries,
            license: mbf_license().map { String(cString: $0) } ?? "unknown",
            buildConfiguration: configuration
        )
        #else
        return FFmpegRuntimeInfo(
            packageName: "unlinked", ffmpegVersion: "unavailable", ffmpegKitVersion: "not used",
            buildDate: "unavailable", externalLibraries: [], license: "unavailable", buildConfiguration: "unavailable"
        )
        #endif
    }
}
