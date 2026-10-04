import AVFoundation
import AVKit
import ImageIO
import SwiftUI
import UIKit

struct MediaPreview: View {
    let url: URL
    let category: MediaCategory
    /// Narrow column for side-by-side layouts with metadata.
    var compact: Bool = false
    /// Set false when preview is already inside another card container.
    var showsChrome: Bool = true
    /// Draws a subtle outline around the aspect-fitted media itself.
    var showsMediaBorder: Bool = false
    var sourceDimensions: CGSize? = nil
    /// Shaded crop overlay on the inline preview. Pass `nil` to hide; full-frame is shown when the effective crop is uncropped.
    var displayCropRect: CropRegion? = nil
    /// Clockwise rotation shown for image and video edits.
    var mediaRotation: MediaRotation = .none
    /// Horizontal mirror shown for image and video edits.
    var isMirrored = false
    /// Disable full-screen playback when the preview is embedded in another control.
    var isInteractive: Bool = true

    /// Optional fixed height for previews that have more room in their parent card.
    var preferredHeight: CGFloat? = nil

    @State private var isShowingFullImage = false
    @State private var isShowingFullVideo = false
    @State private var isShowingFullAudio = false
    @State private var videoPreviewState: VideoPreviewState = .loading
    @State private var imagePreviewState: VideoPreviewState = .loading

    var body: some View {
        Group {
            switch category {
            case .image, .animatedImage:
                imagePreview
            case .video:
                videoCardPreview
            case .audio:
                audioPlayerPreview
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: preferredHeight ?? (compact ? 140 : 220))
        // Hard cap so image/video/animated never exceed a predictable vertical budget (avoids layout pushing siblings).
        .frame(maxHeight: preferredHeight ?? (compact ? 220 : 400))
        .clipped()
        .modifier(PreviewChrome(enabled: showsChrome))
        .overlay {
            if let displayCropRect, let sourceDimensions {
                CropPreviewOverlay(
                    sourceDimensions: mediaRotation.applied(to: sourceDimensions),
                    displayCrop: displayCropRect,
                    imagePadding: compact ? 2 : 12
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var imagePreview: some View {
        Group {
            if case .ready(let image?) = imagePreviewState {
                Group {
                    if isInteractive {
                        Button {
                            Haptics.impact(.light)
                            isShowingFullImage = true
                        } label: {
                            QuarterTurnImage(
                                image: image,
                                sourceDimensions: sourceDimensions,
                                rotation: mediaRotation,
                                isMirrored: isMirrored,
                                padding: compact ? 2 : 12,
                                showsBorder: showsMediaBorder
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    } else {
                        QuarterTurnImage(
                            image: image,
                            sourceDimensions: sourceDimensions,
                            rotation: mediaRotation,
                            isMirrored: isMirrored,
                            padding: compact ? 2 : 12,
                            showsBorder: showsMediaBorder
                        )
                    }
                }
                .fullScreenCover(isPresented: $isShowingFullImage) {
                    FullImagePreview(image: image)
                }
            } else if case .loading = imagePreviewState {
                ProgressView().tint(Theme.textMuted)
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo")
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .task(id: url) {
            imagePreviewState = .loading
            let image = await UIImage.previewImage(from: url)
            guard !Task.isCancelled else { return }
            imagePreviewState = .ready(image)
        }
    }

    /// Posters load independently; a compatible playback copy is prepared only after tapping Play.
    private var videoCardPreview: some View {
        Group {
            switch videoPreviewState {
            case .loading:
                videoPosterBackground(nil)
                    .overlay {
                        ProgressView()
                            .tint(Theme.textMuted)
                    }
            case .ready(let poster):
                if isInteractive {
                    Button {
                        Haptics.impact(.light)
                        isShowingFullVideo = true
                    } label: {
                        videoPosterBackground(poster)
                            .overlay {
                                VideoPlayIndicator(
                                    sourceDimensions: sourceDimensions.map { mediaRotation.applied(to: $0) },
                                    cropRegion: displayCropRect,
                                    imagePadding: compact ? 2 : 12
                                )
                            }
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                } else {
                    videoPosterBackground(poster)
                }
            }
        }
        .task(id: url) {
            videoPreviewState = .loading
            let poster = await UIImage.videoPosterFrame(from: url)
            guard !Task.isCancelled else { return }
            videoPreviewState = .ready(poster)
        }
        .fullScreenCover(isPresented: $isShowingFullVideo) {
            FullVideoPlayer(
                url: url,
                sourceDimensions: sourceDimensions,
                cropRegion: displayCropRect,
                rotation: mediaRotation,
                isMirrored: isMirrored
            )
        }
    }

    @ViewBuilder
    private func videoPosterBackground(_ poster: UIImage?) -> some View {
        ZStack {
            Color.clear

            if let poster {
                QuarterTurnImage(
                    image: poster,
                    sourceDimensions: sourceDimensions,
                    rotation: mediaRotation,
                    isMirrored: isMirrored,
                    padding: compact ? 2 : 12,
                    showsBorder: showsMediaBorder
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum VideoPreviewState {
        case loading
        case ready(UIImage?)
    }

    private var audioPlayerPreview: some View {
        Group {
            if isInteractive {
                Button {
                    Haptics.impact(.light)
                    isShowingFullAudio = true
                } label: {
                    audioArtwork
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            } else {
                audioArtwork
            }
        }
        .fullScreenCover(isPresented: $isShowingFullAudio) {
            FullAudioPlayer(url: url)
        }
    }

    /// Placeholder artwork in the icon's gradient, like an untitled album in Music.
    private var audioArtwork: some View {
        ZStack {
            Theme.brandGradient
            Image(systemName: "waveform")
                .font(.system(size: compact ? 96 : 128, weight: .regular))
                .foregroundStyle(.white.opacity(0.35))
                .accessibilityHidden(true)
            MediaPlayGlyph()
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Glass play button drawn over media. Media stays dark-backed, so the glass
/// always uses its dark appearance to keep the white glyph legible.
private struct MediaPlayGlyph: View {
    var body: some View {
        Image(systemName: "play.fill")
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            // Optical centering for the triangle.
            .offset(x: 2)
            .frame(width: 56, height: 56)
            .glassSurface(in: Circle())
            .environment(\.colorScheme, .dark)
    }
}

private struct VideoPlayIndicator: View {
    let sourceDimensions: CGSize?
    let cropRegion: CropRegion?
    let imagePadding: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
                .insetBy(dx: imagePadding, dy: imagePadding)
            let center = indicatorCenter(in: bounds)

            MediaPlayGlyph()
                .position(center)
        }
    }

    private func indicatorCenter(in bounds: CGRect) -> CGPoint {
        guard let sourceDimensions,
              let crop = cropRegion?.clamped(to: sourceDimensions) else {
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }

        let contentRect = CropLayout.aspectFitRect(source: sourceDimensions, in: bounds)
        let cropRect = CropLayout.displayRect(
            for: crop,
            source: sourceDimensions,
            in: contentRect
        )
        return CGPoint(x: cropRect.midX, y: cropRect.midY)
    }
}

private enum CropLayout {
    static func aspectFitRect(source: CGSize, in bounds: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }

        let scale = min(bounds.width / source.width, bounds.height / source.height)
        let width = source.width * scale
        let height = source.height * scale
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height
        )
    }

    static func displayRect(for crop: CropRegion, source: CGSize, in contentRect: CGRect) -> CGRect {
        let x = contentRect.minX + (CGFloat(crop.x) / source.width) * contentRect.width
        let y = contentRect.minY + (CGFloat(crop.y) / source.height) * contentRect.height
        let width = (CGFloat(crop.width) / source.width) * contentRect.width
        let height = (CGFloat(crop.height) / source.height) * contentRect.height
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

/// Displays quarter-turn edits without rasterizing another full-size preview image.
private struct QuarterTurnImage: View {
    let image: UIImage
    let sourceDimensions: CGSize?
    let rotation: MediaRotation
    let isMirrored: Bool
    let padding: CGFloat
    let showsBorder: Bool

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: padding, dy: padding)
            let rawDimensions = sourceDimensions ?? image.size
            let displayedDimensions = rotation.applied(to: rawDimensions)
            let contentRect = CropLayout.aspectFitRect(source: displayedDimensions, in: bounds)

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()

                if showsBorder {
                    Rectangle()
                        .strokeBorder(Theme.textMuted.opacity(0.32), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
            .frame(
                width: rotation.swapsDimensions ? contentRect.height : contentRect.width,
                height: rotation.swapsDimensions ? contentRect.width : contentRect.height
            )
            .rotationEffect(.degrees(Double(rotation.rawValue)))
            .scaleEffect(x: isMirrored ? -1 : 1)
            .position(x: contentRect.midX, y: contentRect.midY)
        }
    }
}

private struct CropPreviewOverlay: View {
    let sourceDimensions: CGSize
    let displayCrop: CropRegion
    let imagePadding: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: imagePadding, dy: imagePadding)
            let contentRect = CropLayout.aspectFitRect(source: sourceDimensions, in: bounds)
            if let crop = displayCrop.clamped(to: sourceDimensions) {
                let displayRect = CropLayout.displayRect(for: crop, source: sourceDimensions, in: contentRect)
                ZStack {
                    CropShadeBands(
                        contentRect: contentRect,
                        cropRect: displayRect,
                        shadeColor: .gray,
                        opacity: 1
                    )
                    .blendMode(.saturation)
                    CropShadeBands(
                        contentRect: contentRect,
                        cropRect: displayRect,
                        opacity: 0.34
                    )
                    CropFrameChrome(displayRect: displayRect, crop: crop, showsHandles: false, usesThemeAccent: true)
                }
            }
        }
    }
}

/// A Live Photo still's movie, used to choose the exported key photo.
struct LivePhotoEditing {
    let movieURL: URL
    let originalStillURL: URL
    /// Size of the original photo.
    let stillDimensions: CGSize
    /// Upright size of the movie's frames, which a chosen key photo has.
    let movieDimensions: CGSize
    /// Movie time of the photo's own key photo, when known.
    let originalKeyPhotoTime: Double?
    /// The movie frame currently used as the key photo; nil for the original.
    let keyPhotoTime: Double?
}

/// Crop, rotation, and inline trimming. Local edit state keeps output planning off the drag path.
struct CropEditorView: View {
    let category: MediaCategory
    let sourceDimensions: CGSize
    let livePhoto: LivePhotoEditing?
    let onTrimVideo: @MainActor (URL, VideoTrimRange) async throws -> Void
    let onSelectKeyPhoto: @MainActor (Double?) async throws -> Void
    let showsVideoAudioControls: Bool
    let showsVideoSpeedControls: Bool
    @Binding var cropRegion: CropRegion?
    @Binding var mediaRotation: MediaRotation
    @Binding var isMirrored: Bool
    @Binding var audioEdits: AudioEditSettings
    @Binding var videoSpeed: Double

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var playback = TrimVideoPlayback()
    @State private var liveCrop: CropRegion
    @State private var liveRotation: MediaRotation
    @State private var liveIsMirrored: Bool
    @State private var liveAudioEdits: AudioEditSettings
    @State private var liveVideoSpeed: Double
    @State private var liveKeyPhotoTime: Double?
    @State private var keyPhotoDuration: Double = 0
    @State private var keyPhotoRequests: AsyncStream<Double?>.Continuation?
    @State private var undoHistory: [CropEditState] = []
    @State private var interactionStartState: CropEditState?
    @State private var previewImage: UIImage?
    @State private var liveTrim: VideoTrimRange?
    @State private var videoDuration: Double = 0
    @State private var isLoadingTrim = true
    @State private var isSavingEdits = false
    @State private var saveTask: Task<Void, Never>?
    @State private var previewTime: Double = 0
    @State private var previewRequests: AsyncStream<Double>.Continuation?
    @State private var activeVideoURL: URL
    @State private var savingMessage = "Saving trim…"
    @State private var saveErrorTitle = "Couldn't use trimmed video"
    @State private var trimErrorMessage = ""
    @State private var isTrimErrorPresented = false
    @State private var volumeOptionsPopoverPresented = false
    @State private var speedOptionsPopoverPresented = false

    init(
        url: URL,
        category: MediaCategory,
        sourceDimensions: CGSize,
        cropRegion: Binding<CropRegion?>,
        mediaRotation: Binding<MediaRotation>,
        isMirrored: Binding<Bool>,
        showsVideoAudioControls: Bool,
        showsVideoSpeedControls: Bool = false,
        audioEdits: Binding<AudioEditSettings>,
        videoSpeed: Binding<Double> = .constant(1),
        livePhoto: LivePhotoEditing? = nil,
        onTrimVideo: @escaping @MainActor (URL, VideoTrimRange) async throws -> Void,
        onSelectKeyPhoto: @escaping @MainActor (Double?) async throws -> Void = { _ in }
    ) {
        self.category = category
        self.sourceDimensions = sourceDimensions
        self.livePhoto = category == .image ? livePhoto : nil
        self.onTrimVideo = onTrimVideo
        self.onSelectKeyPhoto = onSelectKeyPhoto
        self._liveKeyPhotoTime = State(initialValue: livePhoto?.keyPhotoTime)
        self.showsVideoAudioControls = showsVideoAudioControls
        self.showsVideoSpeedControls = showsVideoSpeedControls && category == .video
        self._cropRegion = cropRegion
        self._mediaRotation = mediaRotation
        self._isMirrored = isMirrored
        self._audioEdits = audioEdits
        self._videoSpeed = videoSpeed
        self._liveAudioEdits = State(initialValue: audioEdits.wrappedValue)
        self._liveVideoSpeed = State(initialValue: videoSpeed.wrappedValue)
        let initialRotation = (category == .image || category == .video) ? mediaRotation.wrappedValue : .none
        let initialDimensions = initialRotation.applied(to: sourceDimensions)
        let initial = cropRegion.wrappedValue?.clamped(to: initialDimensions)
            ?? CropRegion.fullFrame(source: initialDimensions)
            ?? CropRegion(x: 0, y: 0, width: 1, height: 1)
        _liveCrop = State(initialValue: initial)
        _liveRotation = State(initialValue: initialRotation)
        _liveIsMirrored = State(initialValue: isMirrored.wrappedValue)
        _activeVideoURL = State(initialValue: url)
    }

    var body: some View {
        NavigationStack {
            CropCanvasView(
                sourceDimensions: editingSourceDimensions,
                liveCrop: $liveCrop,
                previewImage: previewImage,
                rotation: liveRotation,
                isMirrored: liveIsMirrored,
                player: playback.player,
                onUserGestureBegan: { beginUndoableInteraction() },
                onUserGestureEnded: { endUndoableInteraction() }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if category == .video {
                    VStack(spacing: 0) {
                        // Keep the video length timeline fixed while the edit controls scroll.
                        videoTrimControl
                        if showsVideoSpeedControls || showsVideoAudioControls {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 1)
                                .accessibilityHidden(true)
                            ScrollView {
                                VStack(spacing: 12) {
                                    if showsVideoSpeedControls {
                                        videoSpeedControls
                                    }
                                    if showsVideoAudioControls {
                                        videoAudioControls
                                    }
                                }
                                .padding(.horizontal, 16)
                                .padding(.top, 12)
                                .padding(.bottom, 12)
                            }
                            // Portrait media needs the height more than the controls do.
                            .frame(maxHeight: editingSourceDimensions.height > editingSourceDimensions.width ? 210 : 280)
                            .scrollBounceBehavior(.basedOnSize)
                        }
                    }
                } else if let livePhoto {
                    keyPhotoControl(livePhoto)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 12)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        Haptics.selection()
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        Haptics.impact(.light)
                        saveEdits()
                    }
                    .fontWeight(.semibold)
                    .disabled(isSavingEdits)
                }

                ToolbarItemGroup(placement: .bottomBar) {
                    if category == .image || category == .video {
                        Button {
                            Haptics.selection()
                            rotateClockwise()
                        } label: {
                            Label("Rotate", systemImage: "rotate.right")
                        }
                        .accessibilityLabel(
                            category == .video
                                ? "Rotate video 90 degrees clockwise"
                                : "Rotate image 90 degrees clockwise"
                        )
                    }

                    if category == .image || category == .video {
                        Button {
                            Haptics.selection()
                            performUndoableEdit { liveIsMirrored.toggle() }
                        } label: {
                            Label("Mirror", systemImage: "arrow.left.and.right")
                                .foregroundStyle(liveIsMirrored ? Theme.tint : Theme.text)
                        }
                        .accessibilityLabel(category == .video ? "Mirror video horizontally" : "Mirror image horizontally")
                        .accessibilityValue(liveIsMirrored ? "On" : "Off")
                    }

                    Spacer()

                    Button {
                        Haptics.selection()
                        undoLastEdit()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                            .foregroundStyle(canUndo ? Theme.tint : Theme.textMuted)
                    }
                    .disabled(!canUndo)
                    .accessibilityLabel("Undo last edit")
                }
            }
        }
        .tint(Theme.tint)
        .task(id: activeVideoURL) {
            previewImage = nil
            switch category {
            case .image where livePhoto != nil:
                await updateKeyPhotoPreviewFrames()
            case .image, .animatedImage:
                let image = await UIImage.previewImage(from: activeVideoURL)
                guard !Task.isCancelled else { return }
                previewImage = image
            case .video:
                await updateVideoPreviewFrames()
            case .audio:
                previewImage = nil
            }
        }
        .interactiveDismissDisabled(isSavingEdits)
        .disabled(isSavingEdits)
        .overlay {
            if isSavingEdits {
                ProgressView(savingMessage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .controlSize(.large)
                    .padding(.horizontal, 28)
                    .padding(.vertical, 22)
                    .glassSurface(in: RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            }
        }
        .task(id: activeVideoURL) { await loadTrimRange() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { playback.pause() }
        }
        .onChange(of: liveAudioEdits.volume) { _, _ in applyPreviewAudioVolume() }
        .onChange(of: liveVideoSpeed) { _, _ in applyPreviewRate() }
        .onChange(of: liveKeyPhotoTime) { _, time in keyPhotoRequests?.yield(time) }
        .onChange(of: liveAudioEdits.preservePitch) { _, _ in applyPreviewRate() }
        .onDisappear {
            saveTask?.cancel()
            playback.stop()
            PreviewAudioSession.deactivate()
        }
        .alert(saveErrorTitle, isPresented: $isTrimErrorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(trimErrorMessage)
        }
        .onAppear {
            if category == .video { PreviewAudioSession.configureForPlayback() }
            if liveCrop.clamped(to: editingSourceDimensions) == nil,
               let full = CropRegion.fullFrame(source: editingSourceDimensions) {
                liveCrop = full
            }
        }
    }

    private func updateVideoPreviewFrames() async {
        // Reuse one decoder and keep only the newest queued position. Continuous
        // scrubbing produces frames without waiting for the finger to stop, and
        // old seek requests cannot build up behind the playhead.
        let (requests, continuation) = AsyncStream<Double>.makeStream(bufferingPolicy: .bufferingNewest(1))
        previewRequests = continuation
        continuation.yield(previewTime)
        defer { continuation.finish() }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: activeVideoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        await withTaskCancellationHandler {
            for await seconds in requests {
                guard !Task.isCancelled else { return }
                do {
                    // The end boundary has no video frame of its own.
                    let rangeEnd = liveTrim?.end ?? videoDuration
                    let rangeStart = liveTrim?.start ?? 0
                    let frameTime = rangeEnd > 0 ? min(max(seconds, rangeStart), max(rangeStart, rangeEnd - 1.0 / 600)) : seconds
                    let (image, _) = try await generator.image(at: CMTime(seconds: frameTime, preferredTimescale: 600))
                    guard !Task.isCancelled else { return }
                    previewImage = UIImage(cgImage: image)
                } catch {
                    guard !Task.isCancelled else { return }
                    if previewImage == nil {
                        let fallback = await UIImage.videoPosterFrame(from: activeVideoURL)
                        guard !Task.isCancelled else { return }
                        previewImage = fallback
                    }
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    /// Shows the original photo, or the chosen movie frame at full preview size.
    private func updateKeyPhotoPreviewFrames() async {
        guard let livePhoto else { return }
        let (requests, continuation) = AsyncStream<Double?>.makeStream(bufferingPolicy: .bufferingNewest(1))
        keyPhotoRequests = continuation
        continuation.yield(liveKeyPhotoTime)
        defer { continuation.finish() }
        let asset = AVURLAsset(url: livePhoto.movieURL)
        if let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 0 {
            keyPhotoDuration = duration
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var originalImage: UIImage?
        await withTaskCancellationHandler {
            for await time in requests {
                guard !Task.isCancelled else { return }
                if let time {
                    guard let (frame, _) = try? await generator.image(
                        at: CMTime(seconds: time, preferredTimescale: 600)
                    ) else { continue }
                    guard !Task.isCancelled else { return }
                    previewImage = UIImage(cgImage: frame)
                } else {
                    if originalImage == nil {
                        originalImage = await UIImage.previewImage(from: livePhoto.originalStillURL)
                    }
                    guard !Task.isCancelled else { return }
                    previewImage = originalImage
                }
            }
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    @ViewBuilder
    private func keyPhotoControl(_ livePhoto: LivePhotoEditing) -> some View {
        if keyPhotoDuration > 0 {
            LivePhotoKeyPhotoTimeline(
                movieURL: livePhoto.movieURL,
                duration: keyPhotoDuration,
                originalTime: livePhoto.originalKeyPhotoTime,
                selection: Binding(
                    get: { liveKeyPhotoTime ?? livePhoto.originalKeyPhotoTime ?? keyPhotoDuration / 2 },
                    set: { time in
                        let isOriginal = livePhoto.originalKeyPhotoTime.map { abs(time - $0) < 0.000_001 } ?? false
                        setKeyPhotoTime(isOriginal ? nil : time)
                    }
                ),
                isOriginal: liveKeyPhotoTime == nil,
                onInteractionBegan: beginUndoableInteraction,
                onInteractionEnded: endUndoableInteraction,
                onUseOriginal: {
                    Haptics.selection()
                    performUndoableEdit { setKeyPhotoTime(nil) }
                }
            )
            .surfaceCard()
        } else {
            ProgressView("Loading Live Photo…")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .surfaceCard()
        }
    }

    @ViewBuilder
    private var videoTrimControl: some View {
        if let liveTrim {
            VideoTrimTimeline(
                url: activeVideoURL,
                duration: videoDuration,
                selection: Binding(get: { self.liveTrim ?? liveTrim }, set: { self.liveTrim = $0 }),
                playhead: Binding(get: { previewTime }, set: {
                    playback.pause()
                    seekPreview(to: $0)
                }),
                isPlaying: playback.isPlaying,
                onTogglePlayback: {
                    Haptics.selection()
                    if playback.isPlaying {
                        playback.pause()
                    } else {
                        playback.play(from: previewTime, range: self.liveTrim ?? liveTrim)
                    }
                },
                onInteractionBegan: beginUndoableInteraction,
                onInteractionEnded: endUndoableInteraction
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        } else if isLoadingTrim {
            ProgressView("Loading timeline…")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        } else {
            Label("Video trimming isn't available for this file on this device.", systemImage: "info.circle")
                .font(.footnote)
                .foregroundStyle(Theme.textMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
        }
    }

    private var videoSpeedControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                CardHeader(title: "Playback")
                Spacer(minLength: 12)
                if videoDuration > 0 {
                    Text(VideoTrimTimeline.timestamp((liveTrim?.duration ?? videoDuration) / liveVideoSpeed))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textMuted)
                        .accessibilityLabel("Output duration")
                        .accessibilityValue(VideoTrimTimeline.timestamp((liveTrim?.duration ?? videoDuration) / liveVideoSpeed))
                        .accessibilityIdentifier("videoSpeedOutputDuration")
                }
            }

            videoSpeedControl
        }
        .surfaceCard()
    }

    private var videoSpeedControl: some View {
        EditorSliderRow(
            title: "Speed",
            systemImage: "speedometer",
            value: String(format: "%.2f×", liveVideoSpeed),
            valueIdentifier: "videoSpeedValue"
        ) {
            Slider(value: videoSpeedBinding, in: AudioExportParameters.videoSpeedRange, step: 0.05,
                   onEditingChanged: audioSliderInteraction)
                .accessibilityLabel("Video speed")
                .accessibilityValue(String(format: "%.2f times", liveVideoSpeed))
                .accessibilityIdentifier("videoSpeedSlider")
        } accessory: {
            if showsVideoAudioControls {
                speedOptionsMenuButton
            }
        }
    }

    private var videoSpeedBinding: Binding<Double> {
        Binding(get: { liveVideoSpeed }, set: { value in
            if interactionStartState != nil {
                liveVideoSpeed = value
            } else {
                // Accessibility adjustments may not send slider touch callbacks.
                performUndoableEdit { liveVideoSpeed = value }
            }
        })
    }

    private var speedOptionsMenuButton: some View {
        Button {
            speedOptionsPopoverPresented = true
        } label: {
            optionsGlyph
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Video speed options")
        .accessibilityIdentifier("videoSpeedOptions")
        .popover(isPresented: $speedOptionsPopoverPresented) {
            VStack(spacing: 0) {
                Button {
                    performUndoableEdit { liveAudioEdits.preservePitch.toggle() }
                } label: {
                    checkmarkMenuRow("Preserve pitch", isOn: liveAudioEdits.preservePitch)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityValue(liveAudioEdits.preservePitch ? "On" : "Off")
                .accessibilityIdentifier("videoPreservePitchToggle")
            }
            .padding(.vertical, 6)
            .frame(width: 240)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var videoAudioControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardHeader(title: "Audio")

            videoVolumeControl

            Divider()

            HStack {
                editorRowLabel("Channels", systemImage: "hifispeaker.2")
                Spacer(minLength: 12)
                PopoverDropdown(
                    title: liveAudioEdits.channels.label,
                    accessibilityLabel: "Audio channels",
                    options: AudioChannelMode.allCases,
                    optionTitle: { $0.label },
                    isSelected: { $0 == liveAudioEdits.channels },
                    onSelect: { mode in performUndoableEdit { liveAudioEdits.channels = mode } }
                )
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityIdentifier("videoAudioChannelPicker")
            }
            .frame(minHeight: 44)
        }
        .surfaceCard()
    }

    private var videoVolumeControl: some View {
        EditorSliderRow(
            title: "Volume",
            systemImage: liveAudioEdits.volume == 0 ? "speaker.slash" : "speaker.wave.2",
            value: "\(Int((liveAudioEdits.volume * 100).rounded()))%",
            valueIdentifier: "videoAudioVolumeValue"
        ) {
            Slider(value: videoVolumeBinding, in: 0...2, step: 0.05, onEditingChanged: audioSliderInteraction)
                .accessibilityLabel("Video audio volume")
                .accessibilityValue("\(Int((liveAudioEdits.volume * 100).rounded())) percent")
                .accessibilityIdentifier("videoAudioVolumeSlider")
        } accessory: {
            volumeOptionsMenuButton
        }
    }

    private var videoVolumeBinding: Binding<Double> {
        Binding(get: { liveAudioEdits.volume }, set: { value in
            if interactionStartState != nil {
                liveAudioEdits.volume = value
            } else {
                performUndoableEdit { liveAudioEdits.volume = value }
            }
            applyPreviewAudioVolume()
        })
    }

    private var volumeOptionsMenuButton: some View {
        Button {
            volumeOptionsPopoverPresented = true
        } label: {
            optionsGlyph
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Video audio volume options")
        .accessibilityIdentifier("videoAudioVolumeOptions")
        .popover(isPresented: $volumeOptionsPopoverPresented) {
            VStack(spacing: 0) {
                Button {
                    performUndoableEdit { liveAudioEdits.limiterEnabled.toggle() }
                } label: {
                    checkmarkMenuRow("Allow clipping", isOn: !liveAudioEdits.limiterEnabled)
                }
                .buttonStyle(RowButtonStyle())
                .accessibilityValue(liveAudioEdits.limiterEnabled ? "Off" : "On")
                .accessibilityIdentifier("videoAudioRemoveLimiterToggle")
            }
            .padding(.vertical, 6)
            .frame(width: 240)
            .presentationCompactAdaptation(.popover)
        }
    }

    /// Row title with a quiet leading symbol.
    private func editorRowLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.textMuted)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Theme.text)
        }
        .font(.subheadline)
    }

    /// The "more options" glyph beside a slider, with a full 44 pt target.
    private var optionsGlyph: some View {
        Image(systemName: "ellipsis")
            .font(.footnote.weight(.bold))
            .foregroundStyle(Theme.tint)
            .frame(width: 30, height: 30)
            .background(Theme.secondaryFill, in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
    }

    /// A popover row styled like a native menu item: checkmark leading when on.
    private func checkmarkMenuRow(_ title: String, isOn: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 20)
                .opacity(isOn ? 1 : 0)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(Theme.text)
            Spacer(minLength: 0)
        }
        .font(.body)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func loadTrimRange() async {
        guard category == .video else { return }
        if videoDuration > 0 {
            playback.prepare(url: activeVideoURL, onPositionChange: { previewTime = $0 })
            applyPreviewAudioVolume()
            applyPreviewRate()
            if let liveTrim { playback.seek(to: previewTime, range: liveTrim) }
            return
        }
        isLoadingTrim = true
        defer { isLoadingTrim = false }
        let asset = AVURLAsset(url: activeVideoURL)
        guard let duration = try? await asset.load(.duration).seconds,
              duration.isFinite, duration > 0,
              let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough),
              export.supportedFileTypes.contains(where: { $0 == .mov || $0 == .mp4 }),
              !Task.isCancelled else { return }
        videoDuration = duration
        liveTrim = VideoTrimRange(start: 0, end: duration)
        playback.prepare(url: activeVideoURL, onPositionChange: { previewTime = $0 })
        applyPreviewAudioVolume()
        applyPreviewRate()
    }

    private func seekPreview(to seconds: Double) {
        previewTime = seconds
        // Only editing gestures seek. Player time updates (including Pause)
        // must not feed back into the decoder as another seek request.
        if playback.player != nil, let liveTrim {
            playback.seek(to: seconds, range: liveTrim)
        } else {
            previewRequests?.yield(seconds)
        }
    }

    private func audioSliderInteraction(_ editing: Bool) {
        if editing { beginUndoableInteraction() } else { endUndoableInteraction() }
    }

    private func applyPreviewAudioVolume() {
        playback.player?.volume = Float(min(1, max(0, liveAudioEdits.volume)))
    }

    private func applyPreviewRate() {
        guard showsVideoSpeedControls else { return }
        playback.setRate(Float(liveVideoSpeed), preservesPitch: liveAudioEdits.preservePitch)
    }

    private func saveEdits() {
        guard !isSavingEdits else { return }
        playback.pause()
        endUndoableInteraction()
        if livePhoto != nil, liveKeyPhotoTime != livePhoto?.keyPhotoTime {
            saveKeyPhoto()
            return
        }
        guard let liveTrim, !liveTrim.isFullDuration(videoDuration) else {
            applyLiveToBinding()
            dismiss()
            return
        }
        isSavingEdits = true
        savingMessage = "Saving trim…"
        saveTask = Task { @MainActor in
            defer { isSavingEdits = false }
            do {
                try await onTrimVideo(activeVideoURL, liveTrim)
                applyLiveToBinding()
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                saveErrorTitle = "Couldn't use trimmed video"
                trimErrorMessage = error.localizedDescription
                isTrimErrorPresented = true
            }
        }
    }

    private func saveKeyPhoto() {
        // Apply crop in the current still's coordinates first; the model then
        // rescales it to the size of the new key photo.
        applyLiveToBinding()
        isSavingEdits = true
        savingMessage = "Saving key photo…"
        let time = liveKeyPhotoTime
        saveTask = Task { @MainActor in
            defer { isSavingEdits = false }
            do {
                try await onSelectKeyPhoto(time)
                dismiss()
            } catch is CancellationError {
                return
            } catch {
                saveErrorTitle = "Couldn't use key photo"
                trimErrorMessage = error.localizedDescription
                isTrimErrorPresented = true
            }
        }
    }

    private func applyLiveToBinding() {
        // The binding is in the current input's pixels, even while a different
        // key photo is being chosen.
        let inputDimensions = liveRotation.applied(to: sourceDimensions)
        guard let clamped = liveCrop.clamped(to: editingSourceDimensions),
              let crop = editingSourceDimensions == inputDimensions
                ? clamped : clamped.scaled(from: editingSourceDimensions, to: inputDimensions) else { return }
        cropRegion = crop.isEffectivelyFullFrame(for: inputDimensions) ? nil : crop
        mediaRotation = (category == .image || category == .video) ? liveRotation : .none
        isMirrored = (category == .image || category == .video) && liveIsMirrored
        if category == .video { audioEdits = liveAudioEdits }
        if showsVideoSpeedControls { videoSpeed = liveVideoSpeed }
    }

    private var editingSourceDimensions: CGSize {
        liveRotation.applied(to: keyPhotoSourceDimensions(for: liveKeyPhotoTime))
    }

    /// The input's size, or the size of a different Live Photo key photo while it is chosen.
    private func keyPhotoSourceDimensions(for time: Double?) -> CGSize {
        guard let livePhoto, time != livePhoto.keyPhotoTime else { return sourceDimensions }
        return time == nil ? livePhoto.stillDimensions : livePhoto.movieDimensions
    }

    /// Movie frames are smaller than the photo, so keep the same framed region at the new size.
    private func setKeyPhotoTime(_ time: Double?) {
        let previousDimensions = editingSourceDimensions
        liveKeyPhotoTime = time
        guard editingSourceDimensions != previousDimensions,
              let scaled = liveCrop.scaled(from: previousDimensions, to: editingSourceDimensions) else { return }
        liveCrop = scaled
    }

    private var canUndo: Bool {
        !undoHistory.isEmpty || (interactionStartState != nil && interactionStartState != currentEditState)
    }

    /// Add future editor values here so one undo restores the complete edit state.
    private var currentEditState: CropEditState {
        CropEditState(crop: liveCrop, rotation: liveRotation, isMirrored: liveIsMirrored,
                      trim: liveTrim, audioEdits: liveAudioEdits, videoSpeed: liveVideoSpeed,
                      keyPhotoTime: liveKeyPhotoTime)
    }

    private func beginUndoableInteraction() {
        playback.pause()
        guard interactionStartState == nil else { return }
        interactionStartState = currentEditState
    }

    private func endUndoableInteraction() {
        guard let startState = interactionStartState else { return }
        interactionStartState = nil
        guard startState != currentEditState else { return }
        undoHistory.append(startState)
    }

    private func performUndoableEdit(_ edit: () -> Void) {
        playback.pause()
        endUndoableInteraction()
        let startState = currentEditState
        edit()
        guard startState != currentEditState else { return }
        undoHistory.append(startState)
    }

    private func undoLastEdit() {
        playback.pause()
        let previousState: CropEditState
        if let interactionStartState, interactionStartState != currentEditState {
            previousState = interactionStartState
        } else if let historyState = undoHistory.popLast() {
            previousState = historyState
        } else {
            return
        }
        liveCrop = previousState.crop
        liveRotation = previousState.rotation
        liveIsMirrored = previousState.isMirrored
        liveAudioEdits = previousState.audioEdits
        liveVideoSpeed = previousState.videoSpeed
        liveKeyPhotoTime = previousState.keyPhotoTime
        liveTrim = previousState.trim ?? (videoDuration > 0 ? VideoTrimRange(start: 0, end: videoDuration) : nil)
        seekPreview(to: liveTrim?.start ?? 0)
    }

    private func rotateClockwise() {
        performUndoableEdit {
            let currentDimensions = editingSourceDimensions
            liveCrop = liveCrop.rotatedClockwise(in: currentDimensions)
            liveRotation = liveRotation.nextClockwise
            if let clamped = liveCrop.clamped(to: editingSourceDimensions) {
                liveCrop = clamped
            }
        }
    }
}

private struct CropEditState: Hashable {
    let crop: CropRegion
    let rotation: MediaRotation
    let isMirrored: Bool
    let trim: VideoTrimRange?
    let audioEdits: AudioEditSettings
    let videoSpeed: Double
    let keyPhotoTime: Double?
}

// Fast dimming: four bands instead of even-odd fill each frame.
private struct CropShadeBands: View {
    let contentRect: CGRect
    let cropRect: CGRect
    var shadeColor: Color = .black
    var opacity: Double = 0.45

    var body: some View {
        let c = contentRect
        let r = cropRect
        ZStack(alignment: .topLeading) {
            if r.minY > c.minY + 0.5 {
                band(CGRect(x: c.minX, y: c.minY, width: c.width, height: r.minY - c.minY))
            }
            if c.maxY > r.maxY + 0.5 {
                band(CGRect(x: c.minX, y: r.maxY, width: c.width, height: c.maxY - r.maxY))
            }
            if r.minX > c.minX + 0.5 {
                let h = r.height
                band(CGRect(x: c.minX, y: r.minY, width: r.minX - c.minX, height: h))
            }
            if c.maxX > r.maxX + 0.5 {
                let h = r.height
                band(CGRect(x: r.maxX, y: r.minY, width: c.maxX - r.maxX, height: h))
            }
        }
    }

    private func band(_ r: CGRect) -> some View {
        shadeColor.opacity(opacity)
            .frame(width: max(0, r.width), height: max(0, r.height))
            .position(x: r.midX, y: r.midY)
    }
}

/// A video layer without its own controls; the timeline owns playback.
private struct CropVideoSurface: UIViewRepresentable {
    let player: AVPlayer

    final class Surface: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> Surface {
        let view = Surface()
        view.playerLayer.videoGravity = .resizeAspect
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: Surface, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    static func dismantleUIView(_ view: Surface, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

private struct CropCanvasView: View {
    let sourceDimensions: CGSize
    @Binding var liveCrop: CropRegion
    let previewImage: UIImage?
    let rotation: MediaRotation
    let isMirrored: Bool
    var player: AVPlayer? = nil
    var onUserGestureBegan: (() -> Void)? = nil
    var onUserGestureEnded: (() -> Void)? = nil

    @State private var activeDrag: ActiveCropDrag?

    private let minimumCropSize = 8.0
    /// Margin around the media so the corner brackets and size label stay visible at the edges.
    private let canvasInset: CGFloat = 14
    /// How far the dark mat extends past the media.
    private let matMargin: CGFloat = 10

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size).insetBy(dx: canvasInset, dy: canvasInset)
            let contentRect = CropLayout.aspectFitRect(source: sourceDimensions, in: bounds)
            let crop = liveCrop.clamped(to: sourceDimensions) ?? liveCrop
            let displayRect = CropLayout.displayRect(for: crop, source: sourceDimensions, in: contentRect)

            ZStack {
                // Media editing always happens on a dark canvas, like Photos. It
                // hugs the media with a small margin and an edge so it reads as
                // a mat behind the image rather than part of it.
                let mat = contentRect.insetBy(dx: -matMargin, dy: -matMargin)
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemGroupedBackground))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                    }
                    .frame(width: max(0, mat.width), height: max(0, mat.height))
                    .position(x: mat.midX, y: mat.midY)

                if let player {
                    CropVideoSurface(player: player)
                        .frame(
                            width: rotation.swapsDimensions ? contentRect.height : contentRect.width,
                            height: rotation.swapsDimensions ? contentRect.width : contentRect.height
                        )
                        .rotationEffect(.degrees(Double(rotation.rawValue)))
                        .scaleEffect(x: isMirrored ? -1 : 1)
                        .position(x: contentRect.midX, y: contentRect.midY)
                } else if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(
                            width: rotation.swapsDimensions ? contentRect.height : contentRect.width,
                            height: rotation.swapsDimensions ? contentRect.width : contentRect.height
                        )
                        .rotationEffect(.degrees(Double(rotation.rawValue)))
                        .scaleEffect(x: isMirrored ? -1 : 1)
                        .position(x: contentRect.midX, y: contentRect.midY)
                } else {
                    ProgressView()
                        .tint(Theme.textMuted)
                }

                CropShadeBands(
                    contentRect: contentRect,
                    cropRect: displayRect,
                    shadeColor: .black,
                    opacity: 0.55
                )
                CropFrameChrome(displayRect: displayRect, crop: crop, showsHandles: true, usesThemeAccent: false)
            }
            .environment(\.colorScheme, .dark)
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0.5, coordinateSpace: .local)
                    .onChanged { value in
                        if activeDrag == nil {
                            onUserGestureBegan?()
                        }
                        updateDrag(value, contentRect: contentRect, regionAtStart: crop)
                    }
                    .onEnded { _ in
                        activeDrag = nil
                        onUserGestureEnded?()
                    }
            )
        }
    }

    private func updateDrag(_ value: DragGesture.Value, contentRect: CGRect, regionAtStart: CropRegion) {
        let startPoint = pixelPoint(for: value.startLocation, in: contentRect)
        let currentPoint = pixelPoint(for: value.location, in: contentRect)

        if activeDrag == nil {
            let mode = dragMode(for: value.startLocation, contentRect: contentRect, region: regionAtStart)
            let startRegion = regionAtStart.clamped(to: sourceDimensions) ?? regionAtStart
            activeDrag = ActiveCropDrag(mode: mode, startPoint: startPoint, startRegion: startRegion)
        }

        guard let activeDrag else { return }
        let next: CropRegion
        switch activeDrag.mode {
        case .move:
            next = movedRegion(activeDrag.startRegion, start: activeDrag.startPoint, current: currentPoint)
        case .resize(let handle):
            next = resizedRegion(activeDrag.startRegion, handle: handle, start: activeDrag.startPoint, current: currentPoint)
        }

        if let clamped = next.clamped(to: sourceDimensions, minimumSize: minimumCropSize) {
            liveCrop = clamped
        }
    }

    private func pixelPoint(for point: CGPoint, in contentRect: CGRect) -> CGPoint {
        guard contentRect.width > 0, contentRect.height > 0 else { return .zero }
        let x = min(max(point.x, contentRect.minX), contentRect.maxX)
        let y = min(max(point.y, contentRect.minY), contentRect.maxY)
        return CGPoint(
            x: ((x - contentRect.minX) / contentRect.width) * sourceDimensions.width,
            y: ((y - contentRect.minY) / contentRect.height) * sourceDimensions.height
        )
    }

    private func dragMode(for point: CGPoint, contentRect: CGRect, region: CropRegion) -> CropDragMode {
        let displayRect = CropLayout.displayRect(for: region, source: sourceDimensions, in: contentRect)
        if let handle = resizeHandle(at: point, in: displayRect) {
            return .resize(handle)
        }
        return .move
    }

    private func resizeHandle(at point: CGPoint, in rect: CGRect) -> CropResizeHandle? {
        let cornerTolerance: CGFloat = 28
        let edgeTolerance: CGFloat = 18
        let corners: [(CropResizeHandle, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
        for (handle, corner) in corners
            where abs(point.x - corner.x) <= cornerTolerance && abs(point.y - corner.y) <= cornerTolerance {
            return handle
        }
        if abs(point.y - rect.minY) <= edgeTolerance, point.x >= rect.minX, point.x <= rect.maxX { return .top }
        if abs(point.y - rect.maxY) <= edgeTolerance, point.x >= rect.minX, point.x <= rect.maxX { return .bottom }
        if abs(point.x - rect.minX) <= edgeTolerance, point.y >= rect.minY, point.y <= rect.maxY { return .left }
        if abs(point.x - rect.maxX) <= edgeTolerance, point.y >= rect.minY, point.y <= rect.maxY { return .right }
        return nil
    }

    private func movedRegion(_ region: CropRegion, start: CGPoint, current: CGPoint) -> CropRegion {
        CropRegion(
            x: region.x + Double(current.x - start.x),
            y: region.y + Double(current.y - start.y),
            width: region.width,
            height: region.height
        )
    }

    private func resizedRegion(_ region: CropRegion, handle: CropResizeHandle, start: CGPoint, current: CGPoint) -> CropRegion {
        let dx = Double(current.x - start.x)
        let dy = Double(current.y - start.y)
        let maxX = Double(sourceDimensions.width)
        let maxY = Double(sourceDimensions.height)

        var left = region.x
        var right = region.x + region.width
        var top = region.y
        var bottom = region.y + region.height

        if handle.movesLeft { left = min(max(0, left + dx), right - minimumCropSize) }
        if handle.movesRight { right = max(min(maxX, right + dx), left + minimumCropSize) }
        if handle.movesTop { top = min(max(0, top + dy), bottom - minimumCropSize) }
        if handle.movesBottom { bottom = max(min(maxY, bottom + dy), top + minimumCropSize) }

        return CropRegion(x: left, y: top, width: right - left, height: bottom - top)
    }
}

private struct CropFrameChrome: View {
    let displayRect: CGRect
    let crop: CropRegion
    var showsHandles: Bool
    var usesThemeAccent: Bool

    /// Thickness of the corner brackets and edge bars.
    private let handleThickness: CGFloat = 3
    private let cornerLength: CGFloat = 20
    private let edgeBarLength: CGFloat = 18

    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsHandles {
                // Photos-style chrome: a hairline frame with heavy corners,
                // shadowed so it reads over light and dark media alike.
                ZStack(alignment: .topLeading) {
                    Path { $0.addRect(displayRect) }
                        .stroke(usesThemeAccent ? Theme.tint : Color.white.opacity(0.9), lineWidth: 1)
                    handlePath
                        .stroke(
                            usesThemeAccent ? Theme.tint : Color.white,
                            style: StrokeStyle(lineWidth: handleThickness, lineCap: .butt, lineJoin: .miter)
                        )
                }
                .compositingGroup()
                .shadow(color: .black.opacity(0.4), radius: 2)
            } else {
                Rectangle()
                    .stroke(usesThemeAccent ? Theme.tint : Color.white, lineWidth: 2)
                    .frame(width: displayRect.width, height: displayRect.height)
                    .position(x: displayRect.midX, y: displayRect.midY)
            }

            Text("\(Int(crop.width.rounded())) × \(Int(crop.height.rounded()))")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(showsHandles ? Color.white : Theme.text)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .glassSurface(in: Capsule())
                .position(x: displayRect.midX, y: labelCenterY)
        }
        .allowsHitTesting(false)
    }

    /// Above the frame when there is room; otherwise just inside its top edge
    /// so it never covers the top bar.
    private var labelCenterY: CGFloat {
        guard showsHandles else { return max(displayRect.minY - 12, 14) }
        return displayRect.minY >= 34 ? displayRect.minY - 21 : displayRect.minY + 21
    }

    /// Corner brackets and edge-midpoint bars, drawn just outside the frame line.
    private var handlePath: Path {
        let outer = displayRect.insetBy(dx: -handleThickness / 2, dy: -handleThickness / 2)
        let armX = min(cornerLength, displayRect.width / 2)
        let armY = min(cornerLength, displayRect.height / 2)
        let minimumEdgeForBar = cornerLength * 2 + edgeBarLength + 16

        var path = Path()
        path.move(to: CGPoint(x: outer.minX, y: outer.minY + armY))
        path.addLine(to: CGPoint(x: outer.minX, y: outer.minY))
        path.addLine(to: CGPoint(x: outer.minX + armX, y: outer.minY))

        path.move(to: CGPoint(x: outer.maxX - armX, y: outer.minY))
        path.addLine(to: CGPoint(x: outer.maxX, y: outer.minY))
        path.addLine(to: CGPoint(x: outer.maxX, y: outer.minY + armY))

        path.move(to: CGPoint(x: outer.maxX, y: outer.maxY - armY))
        path.addLine(to: CGPoint(x: outer.maxX, y: outer.maxY))
        path.addLine(to: CGPoint(x: outer.maxX - armX, y: outer.maxY))

        path.move(to: CGPoint(x: outer.minX + armX, y: outer.maxY))
        path.addLine(to: CGPoint(x: outer.minX, y: outer.maxY))
        path.addLine(to: CGPoint(x: outer.minX, y: outer.maxY - armY))

        if displayRect.width >= minimumEdgeForBar {
            path.move(to: CGPoint(x: displayRect.midX - edgeBarLength / 2, y: outer.minY))
            path.addLine(to: CGPoint(x: displayRect.midX + edgeBarLength / 2, y: outer.minY))
            path.move(to: CGPoint(x: displayRect.midX - edgeBarLength / 2, y: outer.maxY))
            path.addLine(to: CGPoint(x: displayRect.midX + edgeBarLength / 2, y: outer.maxY))
        }
        if displayRect.height >= minimumEdgeForBar {
            path.move(to: CGPoint(x: outer.minX, y: displayRect.midY - edgeBarLength / 2))
            path.addLine(to: CGPoint(x: outer.minX, y: displayRect.midY + edgeBarLength / 2))
            path.move(to: CGPoint(x: outer.maxX, y: displayRect.midY - edgeBarLength / 2))
            path.addLine(to: CGPoint(x: outer.maxX, y: displayRect.midY + edgeBarLength / 2))
        }
        return path
    }
}

private struct ActiveCropDrag {
    let mode: CropDragMode
    let startPoint: CGPoint
    let startRegion: CropRegion
}

private enum CropDragMode {
    case move
    case resize(CropResizeHandle)
}

private enum CropResizeHandle {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool {
        self == .topLeft || self == .bottomLeft || self == .left
    }

    var movesRight: Bool {
        self == .topRight || self == .bottomRight || self == .right
    }

    var movesTop: Bool {
        self == .topLeft || self == .topRight || self == .top
    }

    var movesBottom: Bool {
        self == .bottomLeft || self == .bottomRight || self == .bottom
    }
}

private struct PreviewChrome: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        } else {
            content
        }
    }
}

private extension UIImage {
    static func previewImage(from url: URL) async -> UIImage? {
        let native = await Task.detached(priority: .userInitiated) { firstFrame(from: url) }.value
        guard !Task.isCancelled else { return nil }
        if let native { return native }
        do {
            let data = try await MediaPreviewRenderer.firstFrame(sourceURL: url)
            guard !Task.isCancelled else { return nil }
            return UIImage(data: data)
        } catch {
            if !Task.isCancelled {
                DiagnosticsLog.shared.record(error: error, context: "Decode image preview",
                                             metadata: ["Filename": url.lastPathComponent])
            }
            return nil
        }
    }

    static func firstFrame(from url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        // Show the photo as it was taken; previews match the inspected upright dimensions.
        return UIImage(cgImage: image, scale: 1,
                       orientation: UIImage.Orientation(ImageOrientation.orientation(of: source)))
    }

    /// First frame of a video for inline previews (not for playback).
    static func videoPosterFrame(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Strict zero tolerances at t=0 often fail for HEVC (and some open-GOP H.264); allow the nearest
        // decodable frame. Try a few start times in case t=0 has no keyframe.
        generator.requestedTimeToleranceAfter = .positiveInfinity
        generator.requestedTimeToleranceBefore = .positiveInfinity
        let maxEdge: CGFloat = 1920
        generator.maximumSize = CGSize(width: maxEdge, height: maxEdge)

        let startTimes: [CMTime] = [
            .zero,
            CMTime(seconds: 0.1, preferredTimescale: 600),
            CMTime(seconds: 0.5, preferredTimescale: 600)
        ]
        var lastError: Error?
        for t in startTimes {
            guard !Task.isCancelled else { return nil }
            do {
                let (cg, _) = try await generator.image(at: t)
                return UIImage(cgImage: cg)
            } catch {
                lastError = error
                continue
            }
        }
        guard !Task.isCancelled else { return nil }
        do {
            let data = try await MediaPreviewRenderer.firstFrame(sourceURL: url)
            guard !Task.isCancelled else { return nil }
            if let image = UIImage(data: data) { return image }
        } catch {
            lastError = error
        }
        guard !Task.isCancelled else { return nil }
        if let lastError {
            DiagnosticsLog.shared.record(
                error: lastError,
                context: "Generate video preview image",
                metadata: ["Filename": url.lastPathComponent]
            )
        }
        return nil
    }
}

private extension UIImage.Orientation {
    init(_ orientation: CGImagePropertyOrientation) {
        switch orientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

private struct FullImagePreview: View {
    let image: UIImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            ZoomableImageView(image: image)
                .ignoresSafeArea()

            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                FullScreenCloseGlyph()
            }
            .accessibilityLabel("Close image preview")
            .accessibilityHint("Dismisses the full-screen preview")
            .padding(.top, 16)
            .padding(.leading, 16)
        }
    }
}

/// Glass close button for full-screen media, which is always on black.
private struct FullScreenCloseGlyph: View {
    var body: some View {
        Image(systemName: "xmark")
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .glassSurface(in: Circle(), interactive: true)
            .contentShape(Circle())
            .environment(\.colorScheme, .dark)
    }
}

/// Keeps preview controls in the app without publishing Lock Screen media controls.
private struct PreviewPlayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.updatesNowPlayingInfoCenter = false
        controller.allowsPictureInPicturePlayback = false
        controller.player = player
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: ()) {
        controller.player?.pause()
        controller.player = nil
    }
}

/// Native playback with an on-demand compatible copy for unsupported formats.
@MainActor
struct FullVideoPlayer: View {
    let url: URL
    let sourceDimensions: CGSize?
    let cropRegion: CropRegion?
    let rotation: MediaRotation
    let isMirrored: Bool
    var trimRange: VideoTrimRange? = nil
    var initialSourceTime: Double? = nil
    var onPlaybackPositionChange: ((Double) -> Void)? = nil

    @State private var playback = MediaPreviewPlayback()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player = playback.player {
                PreviewPlayerView(player: player)
                    .ignoresSafeArea()
            } else {
                PlaybackPreparationView(playback: playback)
            }
        }
        .task(id: url) {
            playback.setActive(scenePhase == .active && UIApplication.shared.applicationState == .active)
            var offset = initialSourceTime.map { max(0, $0 - (trimRange?.start ?? 0)) }
            if let trimRange, let time = offset, time >= trimRange.duration - 1.0 / 600 {
                offset = 0
            }
            playback.prepare(sourceURL: url, category: .video, initialTime: offset) { playableURL in
                try await EditedVideoPreview.makePlayerItem(
                    url: playableURL,
                    sourceDimensions: sourceDimensions,
                    cropRegion: cropRegion,
                    rotation: rotation,
                    isMirrored: isMirrored,
                    trimRange: trimRange
                )
            }
        }
        .onChange(of: scenePhase) { _, phase in
            playback.setActive(phase == .active)
        }
        .onDisappear {
            if let onPlaybackPositionChange, let player = playback.player {
                let sourceTime = player.currentTime().seconds + (trimRange?.start ?? 0)
                if sourceTime.isFinite {
                    onPlaybackPositionChange(trimRange?.clampedPlayhead(sourceTime) ?? sourceTime)
                }
            }
            playback.stop()
            PreviewAudioSession.deactivate()
        }
    }
}

/// Builds an in-memory video composition so crop and rotation edits can be previewed without export.
enum EditedVideoPreview {
    enum PreviewError: Error {
        case missingVideoTrack
        case invalidDimensions
        case invalidDuration
    }

    @MainActor
    static func makePlayerItem(
        url: URL,
        sourceDimensions: CGSize?,
        cropRegion: CropRegion?,
        rotation: MediaRotation,
        isMirrored: Bool,
        trimRange: VideoTrimRange? = nil
    ) async throws -> AVPlayerItem {
        let source = AVURLAsset(url: url)
        let asset: AVAsset
        if let trimRange {
            let trimmed = AVMutableComposition()
            try await trimmed.insertTimeRange(trimRange.timeRange, of: source, at: .zero)
            asset = trimmed
        } else {
            asset = source
        }
        let item = AVPlayerItem(asset: asset)
        guard cropRegion != nil || rotation != .none || isMirrored else { return item }

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw PreviewError.missingVideoTrack
        }

        async let naturalSizeValue = track.load(.naturalSize)
        async let preferredTransformValue = track.load(.preferredTransform)
        async let durationValue = asset.load(.duration)

        let naturalSize = try await naturalSizeValue
        let preferredTransform = try await preferredTransformValue
        let duration = try await durationValue
        let nominalFrameRate = (try? await track.load(.nominalFrameRate)) ?? 0
        let minimumFrameDuration = (try? await track.load(.minFrameDuration)) ?? .invalid

        guard naturalSize.width > 0, naturalSize.height > 0 else {
            throw PreviewError.invalidDimensions
        }
        let durationSeconds = CMTimeGetSeconds(duration)
        guard duration.isValid, !duration.isIndefinite,
              durationSeconds.isFinite, durationSeconds > 0 else {
            throw PreviewError.invalidDuration
        }

        let rawRect = CGRect(origin: .zero, size: naturalSize)
        let orientedBounds = rawRect.applying(preferredTransform).standardized
        let orientedSize = CGSize(width: orientedBounds.width, height: orientedBounds.height)
        guard orientedSize.width > 0, orientedSize.height > 0 else {
            throw PreviewError.invalidDimensions
        }

        let normalizedOrientation = preferredTransform.concatenating(
            CGAffineTransform(
                translationX: -orientedBounds.minX,
                y: -orientedBounds.minY
            )
        )
        let editRotation = rotationTransform(rotation, sourceSize: orientedSize)
        let editedSize = rotation.applied(to: orientedSize)
        let logicalSourceSize = validDimensions(sourceDimensions) ?? orientedSize
        let logicalEditedSize = rotation.applied(to: logicalSourceSize)
        let logicalCrop = cropRegion?.clamped(to: logicalEditedSize)
            ?? CropRegion.fullFrame(source: logicalEditedSize)

        guard let logicalCrop else {
            throw PreviewError.invalidDimensions
        }

        // Crop coordinates originate from MediaInspector's oriented dimensions. Map them into
        // the actual playback size, which can be a smaller FFmpeg preview or use a different SAR.
        let scaleX = editedSize.width / logicalEditedSize.width
        let scaleY = editedSize.height / logicalEditedSize.height
        let boundedCrop = CGRect(
            x: CGFloat(logicalCrop.x) * scaleX,
            y: CGFloat(logicalCrop.y) * scaleY,
            width: CGFloat(logicalCrop.width) * scaleX,
            height: CGFloat(logicalCrop.height) * scaleY
        ).intersection(CGRect(origin: .zero, size: editedSize))

        guard !boundedCrop.isNull else {
            throw PreviewError.invalidDimensions
        }
        let renderCrop = pixelAlignedCrop(boundedCrop, in: editedSize)
        guard renderCrop.width >= 1, renderCrop.height >= 1 else {
            throw PreviewError.invalidDimensions
        }

        let cropTranslation = CGAffineTransform(
            translationX: -renderCrop.minX,
            y: -renderCrop.minY
        )
        let finalTransform = normalizedOrientation
            .concatenating(editRotation)
            .concatenating(isMirrored
                ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: editedSize.width, ty: 0)
                : .identity)
            .concatenating(cropTranslation)

        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layerInstruction.setTransform(finalTransform, at: .zero)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layerInstruction]

        let composition = AVMutableVideoComposition()
        composition.renderSize = renderCrop.size
        composition.frameDuration = resolvedFrameDuration(
            minimumFrameDuration: minimumFrameDuration,
            nominalFrameRate: nominalFrameRate
        )
        composition.sourceTrackIDForFrameTiming = track.trackID
        composition.instructions = [instruction]
        item.videoComposition = composition
        return item
    }

    static func pixelAlignedCrop(_ crop: CGRect, in dimensions: CGSize) -> CGRect {
        // Round outward so a valid small source crop cannot collapse to zero pixels in a proxy.
        crop.integral.intersection(CGRect(origin: .zero, size: dimensions))
    }

    private static func validDimensions(_ dimensions: CGSize?) -> CGSize? {
        guard let dimensions,
              dimensions.width.isFinite, dimensions.height.isFinite,
              dimensions.width > 0, dimensions.height > 0 else { return nil }
        return dimensions
    }

    private static func rotationTransform(
        _ rotation: MediaRotation,
        sourceSize: CGSize
    ) -> CGAffineTransform {
        switch rotation {
        case .none:
            return .identity
        case .clockwise90:
            return CGAffineTransform(
                a: 0, b: 1,
                c: -1, d: 0,
                tx: sourceSize.height, ty: 0
            )
        case .clockwise180:
            return CGAffineTransform(
                a: -1, b: 0,
                c: 0, d: -1,
                tx: sourceSize.width, ty: sourceSize.height
            )
        case .clockwise270:
            return CGAffineTransform(
                a: 0, b: -1,
                c: 1, d: 0,
                tx: 0, ty: sourceSize.width
            )
        }
    }

    private static func resolvedFrameDuration(
        minimumFrameDuration: CMTime,
        nominalFrameRate: Float
    ) -> CMTime {
        let minimumSeconds = CMTimeGetSeconds(minimumFrameDuration)
        if minimumFrameDuration.isValid, !minimumFrameDuration.isIndefinite,
           minimumSeconds.isFinite, minimumSeconds > 0 {
            return minimumFrameDuration
        }

        let fps = Double(nominalFrameRate)
        if fps.isFinite, fps > 0 {
            return CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
        }
        return CMTime(value: 1, timescale: 30)
    }
}

private struct FullAudioPlayer: View {
    let url: URL
    @State private var playback = MediaPreviewPlayback()
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player = playback.player {
                PreviewPlayerView(player: player)
                    .ignoresSafeArea()
            } else {
                PlaybackPreparationView(playback: playback)
            }

            Button {
                Haptics.impact(.light)
                playback.stop()
                dismiss()
            } label: {
                FullScreenCloseGlyph()
            }
            .accessibilityLabel("Close audio preview")
            .padding(.top, 16)
            .padding(.leading, 16)
        }
        .task(id: url) {
            playback.setActive(scenePhase == .active && UIApplication.shared.applicationState == .active)
            playback.prepare(sourceURL: url, category: .audio)
        }
        .onChange(of: scenePhase) { _, phase in
            playback.setActive(phase == .active)
        }
        .onDisappear {
            playback.stop()
            PreviewAudioSession.deactivate()
        }
    }
}

private struct PlaybackPreparationView: View {
    let playback: MediaPreviewPlayback

    var body: some View {
        VStack(spacing: 10) {
            if let message = playback.errorMessage {
                Image(systemName: "play.slash")
                    .font(.system(size: 40, weight: .regular))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.bottom, 6)
                Text("Preview Unavailable").font(.title3.weight(.semibold))
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            } else {
                if playback.progress > 0 {
                    ProgressView(value: playback.progress)
                        .frame(maxWidth: 220)
                        .padding(.bottom, 8)
                } else {
                    ProgressView()
                        .controlSize(.large)
                        .padding(.bottom, 8)
                }
                Text("Preparing preview…").font(.headline)
                Text("Close to cancel.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .tint(.white)
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum PreviewAudioSession {
    static func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            // AVPlayer activates the session when playback starts, including
            // when the user resumes a preview after returning to the app.
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Configure preview audio session")
            assertionFailure("Unable to configure preview audio session: \(error)")
        }
    }

    static func deactivate() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Deactivate preview audio session")
        }
    }
}

private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.backgroundColor = .black
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 6
        scrollView.bouncesZoom = true
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.decelerationRate = .fast

        let imageView = context.coordinator.imageView
        imageView.image = image
        imageView.contentMode = .scaleAspectFit
        imageView.frame = scrollView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.addSubview(imageView)

        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.scrollView = scrollView

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView.image = image
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let imageView = UIImageView()
        weak var scrollView: UIScrollView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView else { return }

            if scrollView.zoomScale > scrollView.minimumZoomScale {
                scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
                return
            }

            let location = recognizer.location(in: imageView)
            let zoomScale = min(scrollView.maximumZoomScale, 2.5)
            let width = scrollView.bounds.size.width / zoomScale
            let height = scrollView.bounds.size.height / zoomScale
            let zoomRect = CGRect(
                x: location.x - (width / 2),
                y: location.y - (height / 2),
                width: width,
                height: height
            )

            scrollView.zoom(to: zoomRect, animated: true)
        }
    }
}
