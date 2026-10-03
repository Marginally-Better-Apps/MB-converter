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
    private(set) var input: MediaFile
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
            if ![.png, .heic, .webpImage, .tiff].contains(selectedFormat) {
                imageEnhancement.removeBackground = false
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
    var mediaRotation: MediaRotation = .none
    var isMirrored = false
    var audioEdits = AudioEditSettings() {
        didSet {
            clampTargetFractionToMinimum()
            refreshAutoTargetSelections()
        }
    }

    var shouldShowAudioEditor: Bool {
        isAudioOutput && (input.category == .audio || input.audioCodec != nil)
            && (input.duration.map { $0.isFinite && $0 > 0 } ?? false)
    }

    var audioOutputDuration: Double? {
        input.duration.map { audioEdits.outputDuration(sourceDuration: $0) }
    }

    private var planningDuration: Double? {
        isAudioOutput ? audioOutputDuration : input.duration
    }
    var documentSettings = DocumentExportSettings()
    var imageEnhancement = ImageEnhancementSettings()
    var webpQuality: Double = 0.82
    var targetFraction: Double = 1.0 {
        didSet {
            syncMegabytesText()
            refreshAutoTargetSelections()
        }
    }
    var megabytesText = ""
    var usesSinglePassVideoTargetEncode = true
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
    private var sourceWasTrimmed = false
    private(set) var durationBeforeTrim: TimeInterval?
    private(set) var isTrimmingVideo = false

    private var pngBaseline: ImageConverter.PNGSizeBaseline?
    private var pngBaselineConfig: ConversionConfig?
    private var pngBaselineErrorConfig: ConversionConfig?

    var shouldShowPNGDimensions: Bool { selectedFormat == .png && effectiveSourceDimensions != nil }

    /// Dimension changes use arithmetic only; crop/rotation/metadata changes
    /// request a new full-resolution baseline.
    var pngBaselineRequest: ConversionConfig? {
        guard selectedFormat == .png, hasCompletedMetadataDiscovery else { return nil }
        var config = makeConfig()
        config.targetDimensions = nil
        return config
    }

    func preparePNGBaseline() async {
        guard let request = pngBaselineRequest, pngBaselineConfig != request else { return }
        do {
            try await Task.sleep(for: .milliseconds(300))
            let input = input
            let task = Task.detached(priority: .utility) {
                try await ImageConverter().measurePNGBaselineWithFallback(input: input, config: request)
            }
            let baseline = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard pngBaselineRequest == request else { return }
            pngBaseline = baseline
            pngBaselineConfig = request
            pngBaselineErrorConfig = nil
        } catch is CancellationError {
            // The replacement task owns the estimate.
        } catch {
            guard !Task.isCancelled, pngBaselineRequest == request else { return }
            pngBaselineErrorConfig = request
        }
    }

    var pngDimensions: CGSize? { resolvedDimensions ?? effectiveSourceDimensions }

    var pngDimensionScale: Double {
        get {
            guard let source = effectiveSourceDimensions, let dimensions = pngDimensions else { return 1 }
            return min(1, max(pngMinimumScale, Double(max(dimensions.width, dimensions.height) / max(source.width, source.height))))
        }
        set {
            guard let source = effectiveSourceDimensions else { return }
            let scale = min(1, max(pngMinimumScale, newValue))
            if scale >= 1 {
                selectedResolutionID = "original"
            } else {
                selectedResolutionID = "custom"
                customWidthText = "\(max(1, Int((source.width * scale).rounded())))"
                customHeightText = "\(max(1, Int((source.height * scale).rounded())))"
            }
        }
    }

    var pngMinimumScale: Double {
        guard let source = effectiveSourceDimensions else { return 1 }
        return 1 / max(1, Double(max(source.width, source.height)))
    }

    var pngDimensionsLabel: String {
        guard let dimensions = pngDimensions else { return "Original" }
        return "\(Int(dimensions.width.rounded())) × \(Int(dimensions.height.rounded()))"
    }

    var pngEstimatedBytes: Int64? {
        guard let request = pngBaselineRequest, pngBaselineConfig == request,
              let baseline = pngBaseline, let dimensions = pngDimensions else { return nil }
        let ratio = Double(dimensions.width * dimensions.height / (baseline.dimensions.width * baseline.dimensions.height))
        return max(1, Int64((Double(baseline.bytes) * min(1, ratio)).rounded()))
    }

    var pngSizeEstimateLabel: String {
        if let bytes = pngEstimatedBytes {
            let size = bytes < 1_000 ? "\(bytes) bytes" : MetadataFormatter.bytes(bytes)
            return "Estimated size: \(size). Actual file size may vary."
        }
        if let request = pngBaselineRequest, pngBaselineErrorConfig == request {
            return "Size estimate unavailable. You can still convert."
        }
        return "Estimating size…"
    }

    // MARK: - Output metadata

    /// When `true`, strip all EXIF / container tags. When `false`, use per-field rows.
    var removeAllMetadata = false
    /// Starts as `true` so Convert cannot snapshot an empty retention policy before
    /// the view's metadata-discovery task gets its first opportunity to run.
    private(set) var isLoadingDiscoveredMetadata = true
    private(set) var hasCompletedMetadataDiscovery = false
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
        guard !hasCompletedMetadataDiscovery else { return }

        let token = UUID()
        metadataLoadToken = token
        isLoadingDiscoveredMetadata = true
        let tags = await MediaTagDiscovery.discover(for: input)
        guard token == metadataLoadToken else { return }
        discoveredMetadataTags = tags
        if metadataFieldRows.isEmpty {
            metadataFieldRows = tags.map { MetadataFieldRowModel(tag: $0) }
        }
        if let policy = restoredMetadata {
            for index in metadataFieldRows.indices {
                let tag = metadataFieldRows[index].tag
                let retained: String?
                switch tag.kind {
                case .ffprobeFormat: retained = policy.retainedFormatTags[tag.tagKey]
                case .ffprobeStream(let stream): retained = policy.retainedStreamTags[stream]?[tag.tagKey]
                case .image(let entry): retained = policy.retainedImageTags.first { $0.imagePropertyKey == entry.imagePropertyKey }?.value
                }
                metadataFieldRows[index].isRemoved = policy.stripAll || retained == nil
                if let retained { metadataFieldRows[index].value = retained }
            }
            // Fields added in the metadata editor may not exist in the source.
            for entry in policy.retainedImageTags where !metadataFieldRows.contains(where: { $0.id == entry.imagePropertyKey }) {
                let tag = DiscoveredMetadataTag(id: entry.imagePropertyKey, label: entry.dictionaryKey, value: entry.value, tagKey: entry.dictionaryKey, kind: .image(entry), defaultIsRemoved: false)
                metadataFieldRows.append(MetadataFieldRowModel(tag: tag))
            }
            for (key, value) in policy.retainedFormatTags where !metadataFieldRows.contains(where: { $0.tag.tagKey == key && $0.tag.kind == .ffprobeFormat }) {
                metadataFieldRows.append(MetadataFieldRowModel(tag: DiscoveredMetadataTag(id: "format:\(key)", label: key, value: value, tagKey: key, kind: .ffprobeFormat)))
            }
            for (stream, values) in policy.retainedStreamTags {
                for (key, value) in values where !metadataFieldRows.contains(where: { $0.tag.tagKey == key && $0.tag.kind == .ffprobeStream(index: stream) }) {
                    metadataFieldRows.append(MetadataFieldRowModel(tag: DiscoveredMetadataTag(id: "stream:\(stream):\(key)", label: key, value: value, tagKey: key, kind: .ffprobeStream(index: stream))))
                }
            }
            restoredMetadata = nil
        }
        hasCompletedMetadataDiscovery = true
        isLoadingDiscoveredMetadata = false
    }

    /// Serialize saves on the model that owns the input, rather than a transient
    /// sheet callback. A cancelled or stale export never replaces the current input.
    @MainActor
    func trimVideo(
        sourceURL: URL,
        export: () async throws -> MediaFile
    ) async throws -> URL {
        guard !isTrimmingVideo else {
            throw ConversionError.invalidInput("A video trim is already being saved.")
        }
        guard input.url == sourceURL, input.category == .video else {
            throw ConversionError.invalidInput("Reopen the editor to trim the current video.")
        }
        isTrimmingVideo = true
        defer { isTrimmingVideo = false }
        let previousInput = input
        let inspected = try await export()
        let ownedURL = inspected.url
        do {
            try Task.checkCancellation()
            guard input.url == sourceURL, inspected.category == .video else {
                throw ConversionError.invalidInput("The trimmed video could not replace the current input.")
            }
            let trimmedMedia = MediaFile(
                id: previousInput.id,
                url: ownedURL,
                originalFilename: previousInput.originalFilename,
                category: inspected.category,
                sizeOnDisk: inspected.sizeOnDisk,
                dimensions: inspected.dimensions,
                duration: inspected.duration,
                fps: inspected.fps,
                bitrate: inspected.bitrate,
                audioBitrate: inspected.audioBitrate,
                videoCodec: inspected.videoCodec,
                videoColor: inspected.videoColor,
                audioCodec: inspected.audioCodec,
                containerFormat: inspected.containerFormat
            )
            replaceInput(trimmedMedia)
            return ownedURL
        } catch {
            try? FileManager.default.removeItem(at: ownedURL)
            throw error
        }
    }

    /// Replaces the source after a video trim while preserving the user's
    /// output choices. The trimmed file becomes the source for the final export.
    func replaceInput(_ input: MediaFile) {
        guard input.category == self.input.category else { return }
        if input.category == .video, !sourceWasTrimmed {
            durationBeforeTrim = self.input.duration
        }
        self.input = input
        audioEdits = AudioEditSettings()
        sourceWasTrimmed = true
        metadataLoadToken = UUID()
        isLoadingDiscoveredMetadata = true
        hasCompletedMetadataDiscovery = false
        discoveredMetadataTags = []
        metadataFieldRows = []
        pngBaseline = nil
        pngBaselineConfig = nil
        pngBaselineErrorConfig = nil
        clampTargetFractionToMinimum()
        refreshAutoTargetSelections()
    }

    /// Cache invalidation should begin only after discovery establishes the initial
    /// retention policy. The initial `nil` to populated transition is background
    /// model setup, not a user configuration edit.
    var cacheInvalidationConfig: ConversionConfig? {
        guard hasCompletedMetadataDiscovery else { return nil }
        return makeConfig()
    }

    var canConvert: Bool {
        !isTrimmingVideo && !isLoadingDiscoveredMetadata && !wouldProduceUnchangedOutput
    }

    /// Compare the effective output with the source, so reverting edits also
    /// disables Convert. A different container or codec is still a conversion.
    private var wouldProduceUnchangedOutput: Bool {
        guard !sourceWasTrimmed,
              selectedFormat.category == input.category,
              matchesSourceContainer,
              !hasMetadataChanges, imageEnhancement == ImageEnhancementSettings() else { return false }

        switch input.category {
        case .video:
            return canRemuxCurrentVideoSelection
                && !isMirrored
                && !(input.videoColor?.isHDR == true && selectedFormat != .mp4_hevc)
                && (!shouldShowVideoOutputAudio || videoOutputAudioQuality == .auto)
        case .audio:
            return canRemuxCurrentAudioOutput
        case .image:
            guard normalizedCropRegion == nil,
                  mediaRotation == .none,
                  !isMirrored,
                  resolvedDimensions == nil || resolvedDimensions == input.dimensions else { return false }
            // WebP always applies its explicit quality setting. A smaller image
            // target can also change the output even at the slider's maximum.
            if selectedFormat == .webpImage { return false }
            return !selectedFormat.supportsTargetSize || targetSizeBytes >= input.sizeOnDisk
        case .animatedImage, .document, .data, .archive, .file:
            return false
        }
    }

    private var matchesSourceContainer: Bool {
        let source = input.containerFormat.lowercased()
        switch selectedFormat {
        case .jpg: return source == "jpg" || source == "jpeg"
        case .tiff: return source == "tif" || source == "tiff"
        default: return source == selectedFormat.fileExtension
        }
    }

    private var hasMetadataChanges: Bool {
        if removeAllMetadata { return true }
        return metadataFieldRows.contains { row in
            if row.isRemoved != row.tag.defaultIsRemoved { return true }
            return !row.isRemoved && row.value != row.tag.value
        }
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
        selectedFormat.supportsTwoPassVideoEncoding
            && selectedFormat.supportsTargetSize
            && !usesVideoQualityFallback
    }

    var usesTwoPassVideoEncoding: Bool {
        shouldShowSinglePassVideoTargetToggle && !usesSinglePassVideoTargetEncode
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
        return usesVideoQualityFallback ? "Smaller file" : nil
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
        guard selectedFormat.category == .image || selectedFormat.category == .audio,
              !selectedFormat.isLossy else { return nil }
        return "\(selectedFormat.displayName) is lossless."
    }

    var targetSizeBytes: Int64 {
        let ref = targetSizeSliderReferenceBytes
        return max(targetMinimumSizeBytes, Int64(Double(ref) * targetFraction))
    }

    var suggestedTargetSizesMB: [Int] {
        guard shouldShowTargetSize, !usesVideoQualityFallback else { return [] }
        let minimum = targetMinimumSizeBytes
        let maximum = targetSizeSliderReferenceBytes
        // Show the closest common sizes below the input, within the range the
        // current format and locked settings can actually target.
        return Array([1, 2, 5, 8, 10, 20, 25, 50, 100].filter { megabytes in
            let bytes = Int64(megabytes) * 1_000_000
            return bytes < input.sizeOnDisk && bytes >= minimum && bytes <= maximum
        }.suffix(3))
    }

    func applyTargetSizeSuggestion(_ megabytes: Int) {
        guard suggestedTargetSizesMB.contains(megabytes) else { return }
        targetFraction = Double(megabytes * 1_000_000) / Double(targetSizeSliderReferenceBytes)
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
        case .document, .data, .archive, .file: return ""
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

    func restore(_ config: ConversionConfig) {
        if formats.contains(config.outputFormat) { selectedFormat = config.outputFormat }
        operationMode = config.operationMode
        isResolutionLocked = config.autoTargetLockPolicy.resolution
        isFPSLocked = config.autoTargetLockPolicy.fps
        isAudioQualityLocked = config.autoTargetLockPolicy.audioQuality
        selectedFPS = config.targetFPS
        cropRegion = config.cropRegion; mediaRotation = config.mediaRotation; isMirrored = config.isMirrored
        audioEdits = config.audioEdits
        documentSettings = config.document; imageEnhancement = config.imageEnhancement
        if let size = config.targetDimensions {
            selectedResolutionID = "custom"; customWidthText = "\(Int(size.width))"; customHeightText = "\(Int(size.height))"
        }
        if let bytes = config.targetSizeBytes { targetFraction = Double(bytes) / Double(max(1, targetSizeSliderReferenceBytes)) }
        if let quality = config.imageQuality { webpQuality = quality }
        if let bitrate = config.preferredAudioBitrateKbps { videoOutputAudioQuality = .closestPreset(for: bitrate) }
        usesSinglePassVideoTargetEncode = config.usesSinglePassVideoTargetEncode
        restoredMetadata = config.metadata
        removeAllMetadata = config.metadata.stripAll
    }

    private var restoredMetadata: MetadataExportPolicy?

    func makeConfig() -> ConversionConfig {
        let mode: OutputOperationMode = isAutoTargetMode ? .autoTarget : .manual
        var config = ConversionConfig(
            outputFormat: selectedFormat,
            targetDimensions: resolvedDimensions,
            targetFPS: selectedFPS,
            targetSizeBytes: selectedFormat.supportsTargetSize ? targetSizeBytes : nil,
            cropRegion: normalizedCropRegion,
            mediaRotation: shouldShowCrop ? mediaRotation : .none,
            isMirrored: (input.category == .image || input.category == .video) && isMirrored,
            imageQuality: selectedFormat == .webpImage ? webpQuality : nil,
            videoQuality: usesVideoQualityFallback ? targetFraction : nil,
            usesSinglePassVideoTargetEncode: !usesTwoPassVideoEncoding,
            frameTimeForExtraction: 0,
            preferredAudioBitrateKbps: preferredAudioKbpsForExport(),
            audioEdits: isAudioOutput ? audioEdits : videoTrackAudioEdits,
            operationMode: mode,
            autoTargetLockPolicy: mode == .autoTarget ? currentAutoTargetLockPolicy : .manual,
            prefersRemuxWhenPossible: prefersRemuxWhenPossible,
            metadata: makeMetadataPolicy()
        )
        config.document = documentSettings
        config.imageEnhancement = imageEnhancement
        return config
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
              let source = editingSourceDimensions,
              let crop = cropRegion?.clamped(to: source),
              !crop.isEffectivelyFullFrame(for: source)
        else { return nil }
        return crop
    }

    private var effectiveSourceDimensions: CGSize? {
        normalizedCropRegion?.dimensions ?? editingSourceDimensions
    }

    private var editingSourceDimensions: CGSize? {
        guard let dimensions = input.dimensions else { return nil }
        return shouldShowCrop ? mediaRotation.applied(to: dimensions) : dimensions
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
        case .animatedImage, .document, .data, .archive, .file:
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
        usesTwoPassVideoEncoding ? " · two passes" : " · single pass, size may vary"
    }

    private func videoAudioBitrateKbps(for targetBytes: Int64) -> Int {
        guard input.audioCodec != nil else { return 0 }
        let suggested = BitrateCalculator.suggestedAudioBitrate(
            for: targetBytes,
            durationSec: planningDuration ?? 1
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

    private var videoTrackAudioEdits: AudioEditSettings {
        guard includesVideoOutputAudio else { return AudioEditSettings() }
        return audioEdits.videoTrackEdits
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
            && mediaRotation == .none
            && resolvedDimensions == nil
            && selectedFPS == nil
            && (!includesVideoOutputAudio || audioEdits.videoTrackIsIdentity)
            && selectedFormat.canRemuxVideoCodec(input.videoCodec)
            && selectedFormat.canRemuxAudioCodec(input.audioCodec)
    }

    private var canRemuxCurrentAudioOutput: Bool {
        prefersRemuxWhenPossible
            && audioEdits.isIdentity
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
        let duration = planningDuration ?? 0
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
        let duration = planningDuration ?? 1
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
            durationSec: planningDuration ?? 0,
            maxBitrateKbps: maxKbps
        )
    }

    /// Smallest lossy file size (video → audio) using encoder + source floor, aligned with `audioExportEncodeBitrateKbps` at the low end.
    private func minimumAudioExtractionTargetBytes() -> Int64 {
        let duration = planningDuration ?? 0
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
        guard let duration = planningDuration, duration > 0 else { return 1 }
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
