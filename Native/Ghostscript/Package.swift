// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MBGhostscript",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MBGhostscript", targets: ["MBGhostscriptBridge"])],
    targets: [
        // Generate locally with: python3 Scripts/BuildGhostscript.py --platform ios --platform ios-simulator
        .binaryTarget(name: "MBGhostscriptBridge", path: "Artifacts/MBGhostscriptBridge.xcframework")
    ]
)
