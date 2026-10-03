import Foundation
import CoreGraphics

@MainActor
enum PNGViewModelTests {
    static func run(input: MediaFile) async throws {
        let model = OutputConfigViewModel(input: input)
        model.selectedFormat = .png
        await model.loadDiscoveredMetadataIfNeeded()
        try require(model.shouldShowPNGDimensions && !model.shouldShowTargetSize, "PNG offers dimensions only")
        try require(model.canConvert, "Estimation does not block conversion")
        await model.preparePNGBaseline()
        let maximum = model.pngEstimatedBytes!
        try require(maximum > input.sizeOnDisk, "Estimate uses PNG baseline rather than JPEG bytes")
        let request = model.pngBaselineRequest
        model.pngDimensionScale = 0.5
        try require(model.pngDimensions == CGSize(width: 128, height: 96), "Slider scales both dimensions")
        try require(abs(model.pngEstimatedBytes! - maximum / 4) <= 1, "Half dimensions predicts quarter bytes")
        try require(model.pngBaselineRequest == request, "Dragging needs no encode")
        try require(model.makeConfig().targetDimensions == model.pngDimensions && model.makeConfig().targetSizeBytes == nil,
                    "Export uses dimensions without a byte limit")
        try require(model.pngSizeEstimateLabel.contains("Estimated size:"), "Size is clearly an estimate")
        model.pngDimensionScale = 0.75
        model.pngDimensionScale = 0.25
        try require(model.pngDimensions == CGSize(width: 64, height: 48), "Rapid slider changes immediately select latest dimensions")
        model.updateCustomWidth("96")
        try require(model.pngDimensionScale == 0.375, "Manual dimensions synchronize slider")
        model.pngDimensionScale = 5
        try require(model.makeConfig().targetDimensions == nil, "Slider never upscales")
        model.pngDimensionScale = 0
        try require(model.pngDimensions == CGSize(width: 1, height: 1), "Tiny dimensions remain valid")

        model.cropRegion = CropRegion(x: 0, y: 0, width: 64, height: 48)
        model.pngDimensionScale = 1
        try require(model.pngEstimatedBytes == nil, "Crop hides stale estimate")
        let old = Task { await model.preparePNGBaseline() }
        try await Task.sleep(for: .milliseconds(20))
        model.cropRegion = CropRegion(x: 0, y: 0, width: 128, height: 96)
        old.cancel()
        await model.preparePNGBaseline()
        await old.value
        let expected = try ImageConverter().measurePNGBaseline(input: input, config: model.makeConfig())
        try require(model.pngEstimatedBytes == expected.bytes, "Cancelled stale estimate cannot replace current crop")
        model.removeAllMetadata.toggle()
        try require(model.pngEstimatedBytes == nil, "Metadata invalidates baseline")
        await model.preparePNGBaseline()
        model.selectedFormat = .heic
        try require(model.pngBaselineRequest == nil && model.shouldShowTargetSize, "Other formats retain size controls")
        model.imageEnhancement.removeBackground = true
        model.selectedFormat = .jpg
        try require(!model.makeConfig().imageEnhancement.removeBackground, "Opaque formats clear background-removal settings")
        print("PNG dimension slider and baseline invalidation passed")
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }
    private struct Failure: Error { let message: String }
}
