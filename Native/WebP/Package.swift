// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MBWebP",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "libwebp", targets: ["libwebp"])],
    targets: [
        .target(
            name: "libwebp",
            path: ".",
            sources: ["libwebp/src", "libwebp/sharpyuv"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("libwebp"),
                .define("WEBP_USE_THREAD"),
                // Optimize only the codec, including when the app is debugged.
                .unsafeFlags(["-O2"])
            ]
        )
    ]
)
