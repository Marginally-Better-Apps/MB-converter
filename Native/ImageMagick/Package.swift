// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MBImageMagick",
    platforms: [.iOS(.v17)],
    products: [.library(name: "MBImageMagick", targets: ["MBImageMagickBridge"])],
    targets: [
        // Generate locally with: python3 Scripts/BuildImageMagick.py --platform ios --platform ios-simulator
        .binaryTarget(name: "MBImageMagickBridge", path: "Artifacts/MBImageMagickBridge.xcframework")
    ]
)
