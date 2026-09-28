// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MBFFmpeg",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MBFFmpeg", targets: ["MBFFmpegBridge"])],
    targets: [
        // Generate locally with: python3 Scripts/BuildFFmpeg.py --platform ios --platform ios-simulator
        .binaryTarget(name: "MBFFmpegBridge", path: "Artifacts/MBFFmpegBridge.xcframework")
    ]
)
