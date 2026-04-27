import Foundation

#if canImport(ffmpegkit)
@preconcurrency import ffmpegkit
#endif

struct FFmpegRuntimeInfo: Sendable {
    let packageName: String
    let ffmpegVersion: String
    let ffmpegKitVersion: String
    let buildDate: String
    let externalLibraries: [String]

    static let current = FFmpegRuntimeInfo.load()

    var isMinPackage: Bool {
        packageName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "min"
    }

    func hasExternalLibrary(_ name: String) -> Bool {
        let needle = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return externalLibraries.contains { library in
            library.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == needle
        }
    }

    static func logSummary() {
        let info = current
        let libraries = info.externalLibraries.isEmpty
            ? "none"
            : info.externalLibraries.sorted().joined(separator: ", ")
        print(
            "[FFMPEG RUNTIME] package=\(info.packageName) "
            + "ffmpeg=\(info.ffmpegVersion) "
            + "ffmpegkit=\(info.ffmpegKitVersion) "
            + "buildDate=\(info.buildDate) "
            + "externalLibraries=\(libraries)"
        )
    }

    private static func load() -> FFmpegRuntimeInfo {
        #if canImport(ffmpegkit)
        let libraries = (Packages.getExternalLibraries() as? [String]) ?? []
        return FFmpegRuntimeInfo(
            packageName: Packages.getPackageName() ?? "unknown",
            ffmpegVersion: FFmpegKitConfig.getFFmpegVersion() ?? "unknown",
            ffmpegKitVersion: FFmpegKitConfig.getVersion() ?? "unknown",
            buildDate: FFmpegKitConfig.getBuildDate() ?? "unknown",
            externalLibraries: libraries
        )
        #else
        return FFmpegRuntimeInfo(
            packageName: "unlinked",
            ffmpegVersion: "unavailable",
            ffmpegKitVersion: "unavailable",
            buildDate: "unavailable",
            externalLibraries: []
        )
        #endif
    }
}
