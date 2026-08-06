import CoreGraphics
import Foundation
import Observation

struct ResolutionOption: Identifiable, Hashable {
    let id: String
    let label: String
    let dimensions: CGSize?
}

struct FPSOption: Identifiable, Hashable {
    let id: String
    let label: String
    let value: Double?
}

/// One editable metadata field in the convert screen (backed by a `DiscoveredMetadataTag`).
struct MetadataFieldRowModel: Identifiable, Hashable {
    let id: String
    let tag: DiscoveredMetadataTag
    var value: String
    var isRemoved: Bool

    init(tag: DiscoveredMetadataTag) {
        self.id = tag.id
        self.tag = tag
        self.value = tag.value
        self.isRemoved = tag.defaultIsRemoved
    }
}

/// Output audio for video (or audio extracted from video). Values are never upsampled past the source in encoding.
enum VideoOutputAudioQualityPreset: String, CaseIterable, Identifiable, Hashable {
    case auto
    case k192, k160, k128, k96, k64, k48, k32

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto:   "Original"
        case .k192:   "192 kbps"
        case .k160:   "160 kbps"
        case .k128:   "128 kbps"
        case .k96:    "96 kbps"
        case .k64:    "64 kbps"
        case .k48:    "48 kbps"
        case .k32:    "32 kbps"
        }
    }

    var explicitKbps: Int? {
        switch self {
        case .auto:   return nil
        case .k192:   return 192
        case .k160:   return 160
        case .k128:   return 128
        case .k96:    return 96
        case .k64:    return 64
        case .k48:    return 48
        case .k32:    return 32
        }
    }

    static func closestPreset(for kbps: Int) -> VideoOutputAudioQualityPreset {
        allCases
            .filter { $0.explicitKbps != nil }
            .min { lhs, rhs in
                abs((lhs.explicitKbps ?? kbps) - kbps) < abs((rhs.explicitKbps ?? kbps) - kbps)
            } ?? .auto
    }
}

@MainActor
@Observable
final class OutputConfigViewModel {
    let input: MediaFile
    let formats: [OutputFormat]

    var selectedFormat: OutputFormat {
        didSet {
            selectedResolutionID = "original"
            // Reset FPS for new format without treating it as a user lock action.
            isApplyingAutoTarget = true
            selectedFPS = nil
            isApplyingAutoTarget = false
            if !selectedFormat.supportsTargetSize {
                operationMode = .manual
            }
            if selectedFormat.category != .video {
                usesSinglePassVideoTargetEncode = false
            }
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }

    var operationMode: OutputOperationMode = .autoTarget {
        didSet {
            if operationMode == .autoTarget, !selectedFormat.supportsTargetSize {
                operationMode = .manual
                return
            }
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }
    var isResolutionLocked = false {
        didSet {
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }
    var isFPSLocked = false {
        didSet {
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }
    var isAudioQualityLocked = false {
        didSet {
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }
    var selectedResolutionID = "original"
    var customWidthText = ""
    var customHeightText = ""
    var selectedFPS: Double? {
        didSet {
            guard !isApplyingAutoTarget else { return }
            if isAutoTargetMode, !isFPSLocked {
                isFPSLocked = true
            }
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }
    var cropRegion: CropRegion?
    var webpQuality: Double = 0.82
    var targetFraction: Double = 1.0 {
        didSet {
            syncMegabytesText()
            refreshAutoTargetSelections()
        }
    }
    var megabytesText = ""
    var usesSinglePassVideoTargetEncode = false
    var videoOutputAudioQuality: VideoOutputAudioQualityPreset = .auto {
        didSet {
            guard !isApplyingAutoTarget else { return }
            if isAutoTargetMode, !isAudioQualityLocked {
                isAudioQualityLocked = true
            }
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }

    private var isApplyingAutoTarget = false

    // MARK: - Output metadata

    /// When `true`, strip all EXIF / container tags (default). When `false`, use per-field rows.
    var removeAllMetadata = true
    var isMetadataSectionExpanded = false
    var isLoadingDiscoveredMetadata = false
    private(set) var discoveredMetadataTags: [DiscoveredMetadataTag] = []
    var metadataFieldRows: [MetadataFieldRowModel] = []
    private var metadataLoadToken = UUID()

    init(input: MediaFile) {
        self.input = input
        self.formats = FormatMatrix.allowedOutputs(for: input.category)
        self.selectedFormat = FormatMatrix.defaultOutput(for: input.category)
        if !formats.contains(selectedFormat), let first = formats.first {
            self.selectedFormat = first
        }
        syncCustomDimensionsFromOriginal()
        clampTargetFractionToMinimum()
    }

    func loadDiscoveredMetadataIfNeeded() async {
        let token = UUID()
        metadataLoadToken = token
        isLoadingDiscoveredMetadata = true
        let tags = await MediaTagDiscovery.discover(for: input)
        guard token == metadataLoadToken else { return }
        discoveredMetadataTags = tags
        if metadataFieldRows.isEmpty {
            metadataFieldRows = tags.map { MetadataFieldRowModel(tag: $0) }
        }
        isLoadingDiscoveredMetadata = false
    }

    /// Rebuilds rows from a fresh discovery (e.g. after changing the advanced preference).
    func resetMetadataRowsFromDiscovery() {
        metadataFieldRows = discoveredMetadataTags.map { MetadataFieldRowModel(tag: $0) }
    }

    func makeMetadataPolicy() -> MetadataExportPolicy {
        let streamIndices = Set(
            discoveredMetadataTags.compactMap { tag -> Int? in
                if case .ffprobeStream(let i) = tag.kind { return i }
                return nil
            }
        ).sorted()
        if removeAllMetadata {
            return MetadataExportPolicy(
                stripAll: true,
                retainedFormatTags: [:],
                retainedStreamTags: [:],
                retainedImageTags: [],
                sourceStreamIndicesForTagStrip: streamIndices
            )
        }
        var format: [String: String] = [:]
        var stream: [Int: [String: String]] = [:]
        var image: [ImageMetadataEntry] = []
        for row in metadataFieldRows where !row.isRemoved {
            switch row.tag.kind {
            case .ffprobeFormat:
                format[row.tag.tagKey] = row.value
            case .ffprobeStream(let index):
                var m = stream[index] ?? [:]
                m[row.tag.tagKey] = row.value
                stream[index] = m
            case .image(let entry):
                guard !row.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                var e = entry
                e.value = row.value
                image.append(e)
            }
        }
        return MetadataExportPolicy(
            stripAll: false,
            retainedFormatTags: format,
            retainedStreamTags: stream,
            retainedImageTags: image,
            sourceStreamIndicesForTagStrip: streamIndices
        )
    }

    var resolutionOptions: [ResolutionOption] {
        guard let source = effectiveSourceDimensions, shouldShowResolution else { return [] }
        let sourceShortEdge = min(source.width, source.height)
        var options = [ResolutionOption(id: "original", label: "Original", dimensions: nil)]
        let presets: [(String, CGFloat)] = [
            ("2K", 1440),
            ("1080p", 1080),
            ("720p", 720),
            ("480p", 480),
            ("360p", 360)
        ]

        for preset in presets where sourceShortEdge > preset.1 {
            let dimensions = scaledDimensions(presetShortEdge: preset.1, source: source)
            options.append(ResolutionOption(id: preset.0, label: preset.0, dimensions: dimensions))
        }

        options.append(ResolutionOption(id: "custom", label: "Custom", dimensions: customDimensions))
        return options
    }

    var fpsOptions: [FPSOption] {
        guard let sourceFPS = input.fps, shouldShowFPS else { return [] }
        var options = [FPSOption(id: "original", label: "\(fpsDisplayText(sourceFPS)) (Source)", value: nil)]
        for fps in [60.0, 30.0, 24.0, 15.0] where fps <= sourceFPS.rounded(.up) {
            if abs(fps - sourceFPS) < 0.01 {
                continue
            }
            options.append(FPSOption(id: "\(Int(fps))", label: "\(Int(fps))", value: fps))
        }
        return options
    }

    var videoAudioQualityOptions: [VideoOutputAudioQualityPreset] {
        guard shouldShowVideoOutputAudio else { return VideoOutputAudioQualityPreset.allCases }
        guard let sourceKbps = input.audioBitrate.map({ max(1, $0 / 1000) }) else {
            return VideoOutputAudioQualityPreset.allCases
        }
        return VideoOutputAudioQualityPreset.allCases.filter { preset in
            guard preset != .auto else { return true }
            guard let explicitKbps = preset.explicitKbps else { return false }
            return explicitKbps < sourceKbps
        }
    }

    var videoAudioQualitySelectionLabel: String {
        guard videoOutputAudioQuality == .auto else { return videoOutputAudioQuality.label }
        return videoAudioSourceLabel
    }

    var videoAudioSourceLabel: String {
        if let sourceKbps = input.audioBitrate.map({ max(1, $0 / 1000) }) {
            return "\(sourceKbps) kbps (Source)"
        }
        return "(Source)"
    }

    var shouldShowResolution: Bool {
        selectedFormat.category != .audio && input.dimensions != nil
    }

    var shouldShowCrop: Bool {
        (input.category == .image || input.category == .video)
            && selectedFormat.category != .audio
            && input.dimensions != nil
    }

    /// Crop shown in the convert preview; hidden when uncropped/full-frame.
    var cropRectForDisplay: CropRegion? {
        normalizedCropRegion
    }

    /// Re-run size planning after the user finishes a crop (avoid doing this on every drag frame).
    func refreshAfterCropChange() {
        clampTargetFractionToMinimum()
        refreshAutoTargetSelections()
    }

    var shouldShowFPS: Bool {
        selectedFormat.category == .video && input.fps != nil
    }

    var shouldShowOperationMode: Bool {
        selectedFormat.supportsTargetSize && !usesVideoQualityFallback
    }

    var isAutoTargetMode: Bool {
        operationMode == .autoTarget && selectedFormat.supportsTargetSize && !usesVideoQualityFallback
    }

    var shouldShowTargetSize: Bool {
        selectedFormat.supportsTargetSize
    }

    var shouldShowSinglePassVideoTargetToggle: Bool {
        selectedFormat.category == .video
            && selectedFormat.supportsTargetSize
            && !usesVideoQualityFallback
    }

    var shouldShowWebPQuality: Bool {
        selectedFormat == .webpImage
    }

    var shouldShowVideoOutputAudio: Bool {
        input.category == .video
            && input.audioCodec != nil
            && selectedFormat.category == .video
    }

    var shouldShowTargetSizeEstimate: Bool {
        selectedFormat.category == .audio || !isAutoTargetMode || usesVideoQualityFallback
    }

    var isAudioOutput: Bool {
        selectedFormat.category == .audio
    }

    var usesVideoQualityFallback: Bool {
        input.category == .video
            && selectedFormat.category == .video
            && !hasKnownDuration(input)
    }

    var targetControlTitle: String {
        usesVideoQualityFallback ? "Quality" : "Target Size"
    }

    var targetControlValueLabel: String? {
        guard usesVideoQualityFallback else { return nil }
        return "Quality \(Int((targetFraction * 100).rounded()))%"
    }

    var targetControlMinimumLabel: String? {
        usesVideoQualityFallback ? "Smaller file" : nil
    }

    var targetControlAccessibilityLabel: String {
        usesVideoQualityFallback ? "Encode quality" : "Target size"
    }

    /// 100% on the target-size slider enables best-effort remux for compatible audio codecs.
    private static let targetFractionForMaxQuality: Double = 0.999

    private var isAudioTargetSizeAtMax: Bool {
        isAudioOutput
            && selectedFormat.supportsTargetSize
            && targetFraction >= Self.targetFractionForMaxQuality
    }

    var losslessNote: String? {
        if selectedFormat == .webpImage {
            return "WebP uses quality mode (single pass). Output size is not guaranteed."
        }
        return selectedFormat.supportsTargetSize ? nil : "\(selectedFormat.fileExtension.uppercased()) is lossless. Output size depends on dimensions."
    }

    var targetSizeBytes: Int64 {
        let ref = targetSizeSliderReferenceBytes
        return max(targetMinimumSizeBytes, Int64(Double(ref) * targetFraction))
    }

    /// Upper bound for the target-size control (100% = this value). For audio from video, caps at a plausible max audio size, not the whole video.
    /// For still images, caps at a plausible max for the **output** format so the slider matches achievable sizes (e.g. PNG → HEIC is much smaller on disk than the source).
    var targetSizeSliderReferenceBytes: Int64 {
        guard input.sizeOnDisk > 0 else { return 1 }
        if selectedFormat.category == .audio, selectedFormat.supportsTargetSize {
            let fromDuration = maximumAudioTargetBytes(for: selectedFormat)
            return max(targetMinimumSizeBytes, min(input.sizeOnDisk, fromDuration))
        }
        if input.category == .image, selectedFormat.category == .image {
            let formatCap = estimatedMaximumImageTargetBytes(for: imageSliderReferenceDimensions)
            return max(targetMinimumSizeBytes, min(input.sizeOnDisk, formatCap))
        }
        return input.sizeOnDisk
    }

    var targetMinimumSizeBytes: Int64 {
        guard selectedFormat.supportsTargetSize else { return 0 }
        let minimum = estimatedMinimumTargetBytes()
        return max(1, minimum)
    }

    var targetMinimumFraction: Double {
        let ref = targetSizeSliderReferenceBytes
        guard ref > 0 else { return 1 }
        return min(1, max(0, Double(targetMinimumSizeBytes) / Double(ref)))
    }

    var estimatedLabel: String {
        guard selectedFormat.supportsTargetSize else {
            return "Output size depends on the selected dimensions."
        }

        switch selectedFormat.category {
        case .video, .animatedImage:
            if prefersRemuxWhenPossible {
                return canRemuxCurrentVideoSelection
                    ? "Max target: remux compatible streams without re-encoding."
                    : "Max target: remux if compatible; otherwise re-encode."
            }

            if usesVideoQualityFallback {
                let bitrate = qualityFallbackVideoBitrateKbps()
                return "Quality mode: higher values use more bitrate. Video \(MetadataFormatter.bitrateText(bitrate * 1000)); final size depends on stream length."
            }

            if isAutoTargetMode {
                let plan = currentAutoTargetVideoPlan()
                let resolution = resolutionLabel(for: plan.targetDimensions)
                let fps = fpsLabel(for: plan.targetFPS)
                let audioLine = includesVideoOutputAudio
                    ? " · audio \(plan.audioBitrateKbps) kbps"
                    : ""
                let reachability = plan.isTargetReachable ? "" : " · best effort"
                return "Auto: \(resolution), \(fps), video \(MetadataFormatter.bitrateText(plan.videoBitrateKbps * 1000))\(audioLine)\(reachability)\(singlePassVideoTargetSuffix)"
            }

            let duration = input.duration ?? 1
            let audio = selectedFormat.category == .video
                ? videoAudioBitrateKbps(for: targetSizeBytes)
                : 0
            let video = BitrateCalculator.videoBitrateKbps(
                targetBytes: targetSizeBytes,
                durationSec: duration,
                audioBitrateKbps: audio,
                minimumVideoBitrateKbps: minimumVideoBitrateKbps
            )
            let audioLine = (selectedFormat.category == .video && input.audioCodec != nil)
                ? " · audio \(effectiveAudioKbpsString(for: targetSizeBytes))"
                : ""
            return "Estimated video bitrate: \(MetadataFormatter.bitrateText(video * 1000))\(audioLine)\(singlePassVideoTargetSuffix)"
        case .audio:
            if isAudioTargetSizeAtMax, canRemuxCurrentAudioOutput {
                return "Stream copy (remux) at 100% target when codec/container are compatible"
            }
            let planningBytes: Int64 = selectedFormat.supportsTargetSize ? targetSizeBytes : max(1, input.sizeOnDisk)
            return audioLossySummaryLabel(targetBytes: planningBytes)
        case .image:
            return "Image quality will be tuned for the target size."
        }
    }

    var shouldShowRemuxBadgeOnTargetSize: Bool {
        canRemuxCurrentVideoSelection || canRemuxCurrentAudioOutput
    }

    func selectResolution(_ option: ResolutionOption) {
        selectedResolutionID = option.id
        if isAutoTargetMode, !isResolutionLocked {
            isResolutionLocked = true
        }
        if option.id == "custom" {
            syncCustomDimensionsFromOriginal()
        }
        clampTargetFractionToMinimum()
        refreshAutoTargetSelections()
    }

    func updateCustomWidth(_ text: String) {
        customWidthText = text
        guard let width = Double(text), width > 0, let source = effectiveSourceDimensions else { return }
        let ratio = source.height / source.width
        customHeightText = "\(max(1, Int((width * ratio).rounded())))"
        clampTargetFractionToMinimum()
        refreshAutoTargetSelections()
    }

    func updateCustomHeight(_ text: String) {
        customHeightText = text
        guard let height = Double(text), height > 0, let source = effectiveSourceDimensions else { return }
        let ratio = source.width / source.height
        customWidthText = "\(max(1, Int((height * ratio).rounded())))"
        clampTargetFractionToMinimum()
        refreshAutoTargetSelections()
    }

    func applyMegabytesText() {
        guard let megabytes = Double(megabytesText), megabytes > 0 else {
            syncMegabytesText()
            return
        }
        let bytes = megabytes * 1_000_000
        let ref = Double(targetSizeSliderReferenceBytes)
        guard ref > 0 else { return }
        targetFraction = min(1.0, max(targetMinimumFraction, bytes / ref))
    }

    func makeConfig() -> ConversionConfig {
        let mode: OutputOperationMode = isAutoTargetMode ? .autoTarget : .manual
        return ConversionConfig(
            outputFormat: selectedFormat,
            targetDimensions: resolvedDimensions,
            targetFPS: selectedFPS,
            targetSizeBytes: selectedFormat.supportsTargetSize ? targetSizeBytes : nil,
            cropRegion: normalizedCropRegion,
            imageQuality: selectedFormat == .webpImage ? webpQuality : nil,
            videoQuality: usesVideoQualityFallback ? targetFraction : nil,
            usesSinglePassVideoTargetEncode: shouldShowSinglePassVideoTargetToggle && usesSinglePassVideoTargetEncode,
            frameTimeForExtraction: 0,
            preferredAudioBitrateKbps: preferredAudioKbpsForExport(),
            operationMode: mode,
            autoTargetLockPolicy: mode == .autoTarget ? currentAutoTargetLockPolicy : .manual,
            prefersRemuxWhenPossible: prefersRemuxWhenPossible,
            metadata: makeMetadataPolicy()
        )
    }

    private func preferredAudioKbpsForExport() -> Int? {
        guard shouldShowVideoOutputAudio else { return nil }
        if isAutoTargetMode, !isAudioQualityLocked {
            return nil
        }
        return videoAudioBitrateKbps(for: bytesForAudioPlanning())
    }

    private func bytesForAudioPlanning() -> Int64 {
        if selectedFormat.supportsTargetSize {
            return targetSizeBytes
        }
        return input.sizeOnDisk
    }

    private func effectiveAudioKbpsString(for targetBytes: Int64) -> String {
        let kbps = videoAudioBitrateKbps(for: targetBytes)
        return "\(kbps) kbps"
    }

    private var resolvedDimensions: CGSize? {
        guard shouldShowResolution else { return nil }
        if selectedResolutionID == "original" {
            return nil
        }
        if selectedResolutionID == "custom" {
            return customDimensions
        }
        return resolutionOptions.first { $0.id == selectedResolutionID }?.dimensions
    }

    private var customDimensions: CGSize? {
        guard let width = Double(customWidthText),
              let height = Double(customHeightText),
              width > 0,
              height > 0,
              let source = effectiveSourceDimensions else { return nil }
        return CGSize(width: min(width, source.width), height: min(height, source.height))
    }

    private var normalizedCropRegion: CropRegion? {
        guard shouldShowCrop,
              let source = input.dimensions,
              let crop = cropRegion?.clamped(to: source),
              !crop.isEffectivelyFullFrame(for: source)
        else { return nil }
        return crop
    }

    private var effectiveSourceDimensions: CGSize? {
        normalizedCropRegion?.dimensions ?? input.dimensions
    }

    private var mediaForPlanning: MediaFile {
        guard let dimensions = effectiveSourceDimensions else {
            return input
        }
        if let source = input.dimensions, dimensions == source {
            return input
        }

        return MediaFile(
            id: input.id,
            url: input.url,
            originalFilename: input.originalFilename,
            category: input.category,
            sizeOnDisk: input.sizeOnDisk,
            dimensions: dimensions,
            duration: input.duration,
            fps: input.fps,
            bitrate: input.bitrate,
            audioBitrate: input.audioBitrate,
            videoCodec: input.videoCodec,
            audioCodec: input.audioCodec,
            containerFormat: input.containerFormat
        )
    }

    private func syncMegabytesText() {
        let mb = Double(targetSizeBytes) / 1_000_000
        megabytesText = String(format: "%.1f", mb)
    }

    private func clampTargetFractionToMinimum() {
        let minimum = targetMinimumFraction
        if targetFraction < minimum {
            targetFraction = minimum
        } else {
            syncMegabytesText()
        }
    }

    private func estimatedMinimumTargetBytes() -> Int64 {
        let planningInput = mediaForPlanning
        switch selectedFormat.category {
        case .audio:
            if input.category == .video, input.audioCodec != nil, shouldShowVideoOutputAudio {
                return minimumAudioExtractionTargetBytes()
            }
            return minimumAudioTargetBytes(for: selectedFormat)
        case .video:
            if isAutoTargetMode {
                return AutoTargetPlanner.minimumVideoTargetBytes(
                    input: planningInput,
                    outputFormat: selectedFormat,
                    lockedDimensions: resolvedDimensions,
                    lockedFPS: selectedFPS,
                    preferredAudioBitrateKbps: isAudioQualityLocked
                        ? videoAudioBitrateKbps(for: max(1, input.sizeOnDisk))
                        : nil,
                    lockPolicy: currentAutoTargetLockPolicy,
                    includesAudio: includesVideoOutputAudio
                )
            }

            // Use original file size for the audio ceiling here — not `targetSizeBytes`.
            // `targetSizeBytes` depends on `targetMinimumSizeBytes`, which calls this method, so
            // passing `targetSizeBytes` into `videoAudioBitrateKbps` causes infinite recursion.
            return BitrateCalculator.minimumVideoTargetBytes(
                durationSec: input.duration ?? 0,
                includesAudio: input.audioCodec != nil,
                dimensions: effectiveVideoDimensions,
                fps: effectiveVideoFPS,
                outputFormat: selectedFormat,
                sourceVideoBitrateBps: sourceVideoBitrateBps,
                maximumAudioBitrateKbps: (input.audioCodec != nil)
                    ? videoAudioBitrateKbps(for: max(1, input.sizeOnDisk))
                    : nil
            )
        case .image:
            if isAutoTargetMode {
                return AutoTargetPlanner.minimumImageTargetBytes(
                    input: planningInput,
                    outputFormat: selectedFormat,
                    lockedDimensions: resolvedDimensions,
                    lockPolicy: currentAutoTargetLockPolicy
                )
            }
            return minimumImageTargetBytes()
        case .animatedImage:
            return input.sizeOnDisk
        }
    }

    private func minimumImageTargetBytes(for dimensions: CGSize? = nil) -> Int64 {
        AutoTargetPlanner.minimumImageTargetBytes(
            input: mediaForPlanning,
            outputFormat: selectedFormat,
            lockedDimensions: dimensions ?? resolvedDimensions,
            lockPolicy: .manual
        )
    }

    /// Loose upper bound for lossy still-image output at ~full quality, used to cap the target slider so 100% is reachable for the selected format.
    private func estimatedMaximumImageTargetBytes(for dimensions: CGSize? = nil) -> Int64 {
        let imageDimensions = dimensions ?? resolvedDimensions ?? input.dimensions
        guard let imageDimensions else {
            return max(input.sizeOnDisk, minimumImageTargetBytes(for: nil))
        }

        let pixels = max(1.0, Double(imageDimensions.width * imageDimensions.height))
        let bytesPerPixel: Double
        switch selectedFormat {
        case .heic:
            bytesPerPixel = 0.55
        case .jpg:
            bytesPerPixel = 1.4
        default:
            bytesPerPixel = 0.12
        }

        let est = Int64((pixels * bytesPerPixel).rounded(.up)) + 16_384
        return max(est, minimumImageTargetBytes(for: imageDimensions))
    }

    private var imageSliderReferenceDimensions: CGSize? {
        if isAutoTargetMode, !isResolutionLocked {
            return effectiveSourceDimensions
        }
        return resolvedDimensions ?? effectiveSourceDimensions
    }

    private func syncCustomDimensionsFromOriginal() {
        guard let source = effectiveSourceDimensions, customWidthText.isEmpty || customHeightText.isEmpty else { return }
        customWidthText = "\(Int(source.width.rounded()))"
        customHeightText = "\(Int(source.height.rounded()))"
    }

    private var effectiveVideoDimensions: CGSize? {
        resolvedDimensions ?? effectiveSourceDimensions
    }

    private var effectiveVideoFPS: Double? {
        selectedFPS ?? input.fps
    }

    private var minimumVideoBitrateKbps: Int {
        BitrateCalculator.minimumVideoBitrateKbps(
            dimensions: effectiveVideoDimensions,
            fps: effectiveVideoFPS,
            outputFormat: selectedFormat,
            sourceVideoBitrateBps: sourceVideoBitrateBps
        )
    }

    private func qualityFallbackVideoBitrateKbps() -> Int {
        BitrateCalculator.qualityDrivenVideoBitrateKbps(
            quality: targetFraction,
            dimensions: effectiveVideoDimensions,
            fps: effectiveVideoFPS,
            outputFormat: selectedFormat,
            sourceVideoBitrateBps: sourceVideoBitrateBps
        )
    }

    private var sourceVideoBitrateBps: Int? {
        BitrateCalculator.sourceVideoBitrateBps(
            totalBitrateBps: input.bitrate,
            audioBitrateBps: input.audioBitrate
        )
    }

    private var singlePassVideoTargetSuffix: String {
        usesSinglePassVideoTargetEncode ? " · single pass, size may vary" : ""
    }

    private func videoAudioBitrateKbps(for targetBytes: Int64) -> Int {
        guard input.audioCodec != nil else { return 0 }
        let suggested = BitrateCalculator.suggestedAudioBitrate(
            for: targetBytes,
            durationSec: input.duration ?? 1
        )
        let fromPreset: Int
        if let explicit = videoOutputAudioQuality.explicitKbps {
            fromPreset = explicit
        } else {
            fromPreset = input.audioBitrate.map { max(1, $0 / 1000) } ?? suggested
        }
        let capped = selectedFormat == .webm ? min(fromPreset, 128) : fromPreset
        return BitrateCalculator.capAudioEncodeKbps(
            requested: capped,
            sourceBps: input.audioBitrate
        )
    }

    private var includesVideoOutputAudio: Bool {
        input.category == .video
            && input.audioCodec != nil
            && selectedFormat.category == .video
    }

    private var prefersRemuxWhenPossible: Bool {
        if input.category == .video, selectedFormat.category == .video {
            return targetFraction >= 0.999
        }
        if selectedFormat.category == .audio {
            return selectedFormat.supportsTargetSize
                ? targetFraction >= 0.999
                : true
        }
        return false
    }

    private var canRemuxCurrentVideoSelection: Bool {
        prefersRemuxWhenPossible
            && normalizedCropRegion == nil
            && resolvedDimensions == nil
            && selectedFPS == nil
            && selectedFormat.canRemuxVideoCodec(input.videoCodec)
            && selectedFormat.canRemuxAudioCodec(input.audioCodec)
    }

    private var canRemuxCurrentAudioOutput: Bool {
        prefersRemuxWhenPossible
            && isAudioOutput
            && selectedFormat.canRemuxStandaloneAudioCodec(
                input.audioCodec,
                inputContainer: input.containerFormat
            )
    }

    private func audioLossySummaryLabel(targetBytes: Int64) -> String {
        let kbps = audioExportEncodeBitrateKbps(targetBytes: targetBytes)
        return "Bitrate: \(kbps) kbps"
    }

    private var currentAutoTargetLockPolicy: AutoTargetLockPolicy {
        guard isAutoTargetMode else { return .manual }
        return AutoTargetLockPolicy(
            resolution: !shouldShowResolution || isResolutionLocked,
            fps: !shouldShowFPS || isFPSLocked,
            audioQuality: !shouldShowVideoOutputAudio || isAudioQualityLocked
        )
    }

    private func currentAutoTargetVideoPlan() -> AutoTargetVideoPlan {
        AutoTargetPlanner.videoPlan(
            input: mediaForPlanning,
            outputFormat: selectedFormat,
            targetBytes: targetSizeBytes,
            lockedDimensions: resolvedDimensions,
            lockedFPS: selectedFPS,
            preferredAudioBitrateKbps: isAudioQualityLocked
                ? videoAudioBitrateKbps(for: max(1, input.sizeOnDisk))
                : nil,
            lockPolicy: currentAutoTargetLockPolicy,
            includesAudio: includesVideoOutputAudio
        )
    }

    private func currentAutoTargetImagePlan() -> AutoTargetImagePlan {
        AutoTargetPlanner.imagePlan(
            input: mediaForPlanning,
            outputFormat: selectedFormat,
            targetBytes: targetSizeBytes,
            lockedDimensions: resolvedDimensions,
            lockPolicy: currentAutoTargetLockPolicy
        )
    }

    private func refreshAutoTargetSelections() {
        guard isAutoTargetMode, !isApplyingAutoTarget else { return }

        isApplyingAutoTarget = true
        defer {
            isApplyingAutoTarget = false
            syncMegabytesText()
        }

        switch selectedFormat.category {
        case .video:
            let plan = currentAutoTargetVideoPlan()
            if shouldShowResolution, !isResolutionLocked {
                applyAutoResolution(plan.targetDimensions)
            }
            if shouldShowFPS, !isFPSLocked {
                selectedFPS = plan.targetFPS
            }
        case .audio:
            // Video → audio: the selected format is `.audio`, so the video branch above does not run.
            // When quality is unlocked, pick a preset from the current target (same idea as auto resolution / FPS for video).
            guard input.category == .video, input.audioCodec != nil, shouldShowVideoOutputAudio else { return }
            if !isAudioQualityLocked {
                let next = autoTargetVideoToAudioQualityPreset()
                if videoOutputAudioQuality != next {
                    videoOutputAudioQuality = next
                }
            }
        case .image:
            let plan = currentAutoTargetImagePlan()
            if shouldShowResolution, !isResolutionLocked {
                applyAutoResolution(plan.targetDimensions)
            }
        default:
            break
        }
    }

    private func applyAutoResolution(_ dimensions: CGSize?) {
        guard shouldShowResolution else { return }
        guard let dimensions else {
            selectedResolutionID = "original"
            return
        }

        if let option = resolutionOptions.first(where: { option in
            guard let optionDimensions = option.dimensions else { return false }
            return Int(optionDimensions.width.rounded()) == Int(dimensions.width.rounded())
                && Int(optionDimensions.height.rounded()) == Int(dimensions.height.rounded())
        }) {
            selectedResolutionID = option.id
        } else {
            selectedResolutionID = "custom"
            customWidthText = "\(Int(dimensions.width.rounded()))"
            customHeightText = "\(Int(dimensions.height.rounded()))"
        }
    }

    private func resolutionLabel(for dimensions: CGSize?) -> String {
        guard let dimensions else { return "original resolution" }
        if let option = resolutionOptions.first(where: { option in
            guard let optionDimensions = option.dimensions else { return false }
            return Int(optionDimensions.width.rounded()) == Int(dimensions.width.rounded())
                && Int(optionDimensions.height.rounded()) == Int(dimensions.height.rounded())
        }) {
            return option.label
        }
        return "\(Int(dimensions.width.rounded()))x\(Int(dimensions.height.rounded()))"
    }

    private func fpsLabel(for fps: Double?) -> String {
        guard let fps else { return "original FPS" }
        return fpsDisplayText(fps)
    }

    private func fpsDisplayText(_ fps: Double) -> String {
        let rounded = fps.rounded()
        if abs(fps - rounded) < 0.01 {
            return "\(Int(rounded)) fps"
        }
        return String(format: "%.1f fps", fps)
    }

    private func hasKnownDuration(_ media: MediaFile) -> Bool {
        guard let duration = media.duration else { return false }
        return duration.isFinite && duration > 0
    }

    private func scaledDimensions(presetShortEdge: CGFloat, source: CGSize) -> CGSize {
        let shortEdge = min(source.width, source.height)
        guard shortEdge > 0 else { return source }
        let scale = min(1, presetShortEdge / shortEdge)
        return CGSize(
            width: (source.width * scale).rounded(),
            height: (source.height * scale).rounded()
        )
    }

    /// Suggested quality row for video → lossy audio in auto target when the row is **unlocked** (follows the target size slider, like auto resolution / FPS for video).
    private func autoTargetVideoToAudioQualityPreset() -> VideoOutputAudioQualityPreset {
        let duration = input.duration ?? 0
        guard duration > 0 else { return .auto }
        var kbps = BitrateCalculator.audioBitrateKbps(
            targetBytes: targetSizeBytes,
            durationSec: duration
        )
        kbps = BitrateCalculator.capAudioEncodeKbps(
            requested: kbps,
            sourceBps: input.audioBitrate
        )
        kbps = max(minimumAudioBitrateKbps(for: selectedFormat), kbps)
        let candidate = VideoOutputAudioQualityPreset.closestPreset(for: kbps)
        let options = videoAudioQualityOptions
        if options.contains(candidate) {
            return candidate
        }
        if let sourceKbps = input.audioBitrate.map({ max(1, $0 / 1000) }),
           abs(kbps - sourceKbps) <= 12 {
            return .auto
        }
        let withExplicit: [(VideoOutputAudioQualityPreset, Int)] = options.compactMap { p in
            guard let e = p.explicitKbps else { return nil }
            return (p, e)
        }
        guard !withExplicit.isEmpty else { return .auto }
        if let atOrBelow = withExplicit.filter({ $0.1 <= kbps }).max(by: { $0.1 < $1.1 }) {
            return atOrBelow.0
        }
        return withExplicit.min(by: { abs($0.1 - kbps) < abs($1.1 - kbps) })?.0 ?? .auto
    }

    private func selectedAudioQualityOverrideKbps(for targetBytes: Int64) -> Int? {
        guard shouldShowVideoOutputAudio else { return nil }
        if isAutoTargetMode, !isAudioQualityLocked {
            return nil
        }
        let planBytes = selectedFormat.supportsTargetSize ? targetBytes : max(1, input.sizeOnDisk)
        return videoAudioBitrateKbps(for: planBytes)
    }

    /// Matches `AudioConverter.convert` so target size, quality preset, and source cap match the actual encode.
    private func audioExportEncodeBitrateKbps(targetBytes: Int64) -> Int {
        let duration = input.duration ?? 1
        var bitrate: Int
        if let override = selectedAudioQualityOverrideKbps(for: targetBytes) {
            bitrate = override
        } else if selectedFormat.supportsTargetSize {
            bitrate = BitrateCalculator.audioBitrateKbps(targetBytes: targetBytes, durationSec: duration)
        } else {
            bitrate = 192
        }
        let capKbps = (selectedFormat == .m4a || selectedFormat == .aac)
            ? AudioExportParameters.maxAACKbps
            : BitrateCalculator.maximumAudioEncodeKbps(for: selectedFormat)
        bitrate = BitrateCalculator.capAudioEncodeKbps(
            requested: bitrate,
            sourceBps: input.category == .video ? input.audioBitrate : input.bitrate,
            maximumKbps: capKbps
        )
        return max(minimumAudioBitrateKbps(for: selectedFormat), bitrate)
    }

    private func maximumAudioTargetBytes(for format: OutputFormat) -> Int64 {
        let sourceBps = input.category == .video ? input.audioBitrate : input.bitrate
        let ceilingKbps: Int
        if format == .m4a || format == .aac {
            ceilingKbps = AudioExportParameters.maxAACKbps
        } else {
            ceilingKbps = BitrateCalculator.maximumAudioEncodeKbps(for: format)
        }
        let maxKbps = max(
            minimumAudioBitrateKbps(for: format),
            BitrateCalculator.capAudioEncodeKbps(
                requested: ceilingKbps,
                sourceBps: sourceBps,
                maximumKbps: ceilingKbps
            )
        )
        return BitrateCalculator.maximumAudioTargetBytes(
            durationSec: input.duration ?? 0,
            maxBitrateKbps: maxKbps
        )
    }

    /// Smallest lossy file size (video → audio) using encoder + source floor, aligned with `audioExportEncodeBitrateKbps` at the low end.
    private func minimumAudioExtractionTargetBytes() -> Int64 {
        let duration = input.duration ?? 0
        guard duration > 0 else { return 1 }
        let minKbps: Int
        if let override = selectedAudioQualityOverrideKbps(for: max(1, input.sizeOnDisk)) {
            minKbps = max(
                minimumAudioBitrateKbps(for: selectedFormat),
                BitrateCalculator.capAudioEncodeKbps(
                    requested: override,
                    sourceBps: input.audioBitrate
                )
            )
        } else {
            minKbps = max(
                minimumAudioBitrateKbps(for: selectedFormat),
                BitrateCalculator.capAudioEncodeKbps(
                    requested: BitrateCalculator.minAudioBitrateKbps,
                    sourceBps: input.audioBitrate
                )
            )
        }
        return BitrateCalculator.estimatedSize(
            videoBitrateKbps: 0,
            audioBitrateKbps: minKbps,
            durationSec: duration
        )
    }

    private func minimumAudioTargetBytes(for format: OutputFormat) -> Int64 {
        guard let duration = input.duration, duration > 0 else { return 1 }
        let bits = Double(minimumAudioBitrateKbps(for: format)) * 1000.0 * duration
        let withOverhead = bits * (1.0 + BitrateCalculator.muxOverhead)
        return Int64((withOverhead / 8.0).rounded(.up))
    }

    private func minimumAudioBitrateKbps(for format: OutputFormat) -> Int {
        switch format {
        case .m4a:
            // iOS AAC encoding can reject very low stereo bitrates; 64 kbps is the safe floor.
            return 64
        default:
            return BitrateCalculator.minAudioBitrateKbps
        }
    }
}
