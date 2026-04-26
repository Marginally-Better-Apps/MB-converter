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
    var sourceDimensions: CGSize? = nil
    /// Shaded crop overlay on the inline preview. Pass `nil` to hide; full-frame is shown when the effective crop is uncropped.
    var displayCropRect: CropRegion? = nil

    @State private var isShowingFullImage = false
    @State private var isShowingFullVideo = false
    @State private var isShowingFullAudio = false
    @State private var videoPreviewState: VideoPreviewState = .loading

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
        .frame(minHeight: compact ? 140 : 220)
        // Hard cap so image/video/animated never exceed a predictable vertical budget (avoids layout pushing siblings).
        .frame(maxHeight: compact ? 220 : 400)
        .clipped()
        .modifier(PreviewChrome(enabled: showsChrome))
        .overlay {
            if let displayCropRect, let sourceDimensions {
                CropPreviewOverlay(
                    sourceDimensions: sourceDimensions,
                    displayCrop: displayCropRect,
                    imagePadding: compact ? 2 : 12
                )
                .allowsHitTesting(false)
            }
        }
    }

    private var imagePreview: some View {
        Group {
            if let image = UIImage.firstFrame(from: url) {
                Button {
                    Haptics.impact(.light)
                    isShowingFullImage = true
                } label: {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(compact ? 2 : 12)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .fullScreenCover(isPresented: $isShowingFullImage) {
                    FullImagePreview(image: image)
                }
            } else {
                ContentUnavailableView("Preview Unavailable", systemImage: "photo")
                    .foregroundStyle(Theme.textMuted)
            }
        }
    }

    /// Poster + play affordance; non-playable containers fall back to a thumbnail-only card.
    private var videoCardPreview: some View {
        Group {
            switch videoPreviewState {
            case .loading:
                videoPosterBackground(nil)
                    .overlay {
                        ProgressView()
                            .tint(Theme.textMuted)
                    }
            case .playable(let poster):
                Button {
                    Haptics.impact(.light)
                    isShowingFullVideo = true
                } label: {
                    videoPosterBackground(poster)
                        .overlay {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 56))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                        }
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
            case .unavailable(let poster):
                videoPosterBackground(poster)
                    .overlay {
                        Color.black.opacity(poster == nil ? 0 : 0.38)
                    }
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "play.slash")
                                .font(.system(size: 34, weight: .semibold))
                            Text("Preview Not Available")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(12)
                        .multilineTextAlignment(.center)
                    }
            }
        }
        .task(id: url) {
            videoPreviewState = .loading
            let isPlayable = await VideoPreviewSupport.isPlayable(url)
            let poster = await UIImage.videoPosterFrame(from: url)
            videoPreviewState = isPlayable ? .playable(poster) : .unavailable(poster)
        }
        .fullScreenCover(isPresented: $isShowingFullVideo) {
            FullVideoPlayer(url: url)
        }
    }

    @ViewBuilder
    private func videoPosterBackground(_ poster: UIImage?) -> some View {
        ZStack {
            Color(white: 0.12)

            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFit()
                    .padding(compact ? 2 : 12)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private enum VideoPreviewState {
        case loading
        case playable(UIImage?)
        case unavailable(UIImage?)
    }

    private var audioPlayerPreview: some View {
        Button {
            Haptics.impact(.light)
            isShowingFullAudio = true
        } label: {
            ZStack {
                Color(white: 0.12)
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(Theme.primary)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .fullScreenCover(isPresented: $isShowingFullAudio) {
            FullAudioPlayer(url: url)
        }
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
                        shadeColor: Theme.primary,
                        opacity: 0.1
                    )
                    CropFrameChrome(displayRect: displayRect, crop: crop, showsHandles: false, usesThemeAccent: true)
                }
            }
        }
    }
}

/// Full-screen crop editor. Uses local `liveCrop` during drags so `@Observable` planning is not invoked every frame.
struct CropEditorView: View {
    let url: URL
    let category: MediaCategory
    let sourceDimensions: CGSize
    @Binding var cropRegion: CropRegion?

    @Environment(\.dismiss) private var dismiss
    @State private var liveCrop: CropRegion
    @State private var previewImage: UIImage?
    @State private var xText = ""
    @State private var yText = ""
    @State private var widthText = ""
    @State private var heightText = ""

    init(url: URL, category: MediaCategory, sourceDimensions: CGSize, cropRegion: Binding<CropRegion?>) {
        self.url = url
        self.category = category
        self.sourceDimensions = sourceDimensions
        self._cropRegion = cropRegion
        let initial = cropRegion.wrappedValue?.clamped(to: sourceDimensions)
            ?? CropRegion.fullFrame(source: sourceDimensions)
            ?? CropRegion(x: 0, y: 0, width: 1, height: 1)
        _liveCrop = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text("Crop")
                        .font(.title3.bold())
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)

                    Spacer()

                    Button {
                        Haptics.selection()
                        if let full = CropRegion.fullFrame(source: sourceDimensions) {
                            liveCrop = full
                            syncTextFromLive()
                        }
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.background)
                            .frame(width: 34, height: 34)
                            .background(Theme.primary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset crop")
                }

                // Let media preview consume remaining vertical space.
                CropCanvasView(
                    sourceDimensions: sourceDimensions,
                    liveCrop: $liveCrop,
                    previewImage: previewImage,
                    onUserGestureEnded: { syncTextFromLive() }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.surface.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 1)
                )
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Theme.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Crop region (pixels)")
                            .font(.title3.bold())
                            .foregroundStyle(Theme.text)

                        HStack(spacing: 10) {
                            cropField("X", text: $xText)
                            cropField("Y", text: $yText)
                        }
                        HStack(spacing: 10) {
                            cropField("Width", text: $widthText)
                            cropField("Height", text: $heightText)
                        }

                        Text("Drag the frame or use the fields. Target-size planning runs when you tap Done or close the sheet.")
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Theme.accent, lineWidth: 1)
                    )

                    HStack(spacing: 12) {
                        Button {
                            Haptics.selection()
                            dismiss()
                        } label: {
                            Text("Cancel")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.text)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.surface)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Theme.accent, lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)

                        Button {
                            Haptics.impact(.light)
                            applyLiveToBinding()
                            dismiss()
                        } label: {
                            Text("Done")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.background)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Theme.primary)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 14)
                .background(Theme.background.opacity(0.96))
            }
        }
        .task(id: url) {
            previewImage = nil
            switch category {
            case .image, .animatedImage:
                previewImage = UIImage.firstFrame(from: url)
            case .video:
                previewImage = await UIImage.videoPosterFrame(from: url)
            case .audio:
                previewImage = nil
            }
        }
        .onAppear {
            if liveCrop.clamped(to: sourceDimensions) == nil,
               let full = CropRegion.fullFrame(source: sourceDimensions) {
                liveCrop = full
            }
            syncTextFromLive()
        }
    }

    private func applyLiveToBinding() {
        guard let clamped = liveCrop.clamped(to: sourceDimensions) else { return }
        cropRegion = clamped.isEffectivelyFullFrame(for: sourceDimensions) ? nil : clamped
    }

    private func cropField(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textMuted)
            TextField(title, text: text)
                .keyboardType(.numberPad)
                .font(.subheadline.monospacedDigit())
                .padding(10)
                .background(Theme.background.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Theme.accent.opacity(0.5), lineWidth: 1)
                )
                .onChange(of: text.wrappedValue) { _, _ in
                    applyTextToLive()
                }
        }
    }

    private func syncTextFromLive() {
        let crop = liveCrop.clamped(to: sourceDimensions) ?? liveCrop
        xText = "\(Int(crop.x.rounded()))"
        yText = "\(Int(crop.y.rounded()))"
        widthText = "\(Int(crop.width.rounded()))"
        heightText = "\(Int(crop.height.rounded()))"
    }

    private func applyTextToLive() {
        guard let x = Double(xText),
              let y = Double(yText),
              let width = Double(widthText),
              let height = Double(heightText),
              width > 0,
              height > 0,
              let next = CropRegion(x: x, y: y, width: width, height: height).clamped(to: sourceDimensions)
        else { return }
        liveCrop = next
    }
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

private struct CropCanvasView: View {
    let sourceDimensions: CGSize
    @Binding var liveCrop: CropRegion
    let previewImage: UIImage?
    var onUserGestureEnded: (() -> Void)? = nil

    @State private var activeDrag: ActiveCropDrag?

    private let minimumCropSize = 8.0

    var body: some View {
        GeometryReader { proxy in
            let bounds = CGRect(origin: .zero, size: proxy.size)
            let contentRect = CropLayout.aspectFitRect(source: sourceDimensions, in: bounds)
            let crop = liveCrop.clamped(to: sourceDimensions) ?? liveCrop
            let displayRect = CropLayout.displayRect(for: crop, source: sourceDimensions, in: contentRect)

            ZStack {
                Theme.background

                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: contentRect.width, height: contentRect.height)
                        .position(x: contentRect.midX, y: contentRect.midY)
                } else {
                    ProgressView()
                        .tint(Theme.textMuted)
                }

                CropShadeBands(contentRect: contentRect, cropRect: displayRect, opacity: 0.42)
                CropFrameChrome(displayRect: displayRect, crop: crop, showsHandles: true, usesThemeAccent: false)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0.5, coordinateSpace: .local)
                    .onChanged { value in
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

    private var lineColor: Color { usesThemeAccent ? Theme.primary : .white }
    private var labelBackground: Color { usesThemeAccent ? Theme.surface : Color.black.opacity(0.6) }
    private var labelForeground: Color { usesThemeAccent ? Theme.text : .white }
    private var handleColor: Color { usesThemeAccent ? Theme.primary : .white }

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(lineColor, lineWidth: usesThemeAccent ? 2 : 1.5)
                .frame(width: displayRect.width, height: displayRect.height)
                .position(x: displayRect.midX, y: displayRect.midY)

            Text("\(Int(crop.width.rounded())) × \(Int(crop.height.rounded()))")
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(labelForeground)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(labelBackground.opacity(usesThemeAccent ? 0.95 : 0.9), in: Capsule())
                .position(x: displayRect.midX, y: max(displayRect.minY - 12, 14))

            if showsHandles {
                ForEach(0..<8, id: \.self) { index in
                    let point = handlePoints[index]
                    Circle()
                        .fill(handleColor)
                        .frame(width: 11, height: 11)
                        .overlay(
                            Circle().stroke(Theme.background.opacity(0.35), lineWidth: 0.5)
                        )
                        .position(point)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var handlePoints: [CGPoint] {
        [
            CGPoint(x: displayRect.minX, y: displayRect.minY),
            CGPoint(x: displayRect.midX, y: displayRect.minY),
            CGPoint(x: displayRect.maxX, y: displayRect.minY),
            CGPoint(x: displayRect.maxX, y: displayRect.midY),
            CGPoint(x: displayRect.maxX, y: displayRect.maxY),
            CGPoint(x: displayRect.midX, y: displayRect.maxY),
            CGPoint(x: displayRect.minX, y: displayRect.maxY),
            CGPoint(x: displayRect.minX, y: displayRect.midY)
        ]
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
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Theme.accent, lineWidth: 1)
                )
        } else {
            content
        }
    }
}

private extension UIImage {
    static func firstFrame(from url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return UIImage(cgImage: image)
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
        for t in startTimes {
            do {
                let (cg, _) = try await generator.image(at: t)
                return UIImage(cgImage: cg)
            } catch {
                continue
            }
        }
        return nil
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
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 16)
            .padding(.leading, 16)
        }
    }
}

private struct FullVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 16)
            .padding(.leading, 16)
        }
        .onAppear {
            PreviewAudioSession.configureForPlayback()
            if player == nil {
                let newPlayer = AVPlayer(url: url)
                newPlayer.allowsExternalPlayback = false
                newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
                player = newPlayer
            }
            player?.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private struct FullAudioPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()

            if let player {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else {
                ProgressView()
                    .tint(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Button {
                Haptics.impact(.light)
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(.black.opacity(0.45), in: Circle())
            }
            .padding(.top, 16)
            .padding(.leading, 16)
        }
        .onAppear {
            PreviewAudioSession.configureForPlayback()
            if player == nil {
                let newPlayer = AVPlayer(url: url)
                newPlayer.allowsExternalPlayback = false
                newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
                player = newPlayer
            }
            player?.play()
        }
        .onDisappear {
            player?.pause()
        }
    }
}

private enum PreviewAudioSession {
    static func configureForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
        } catch {
            assertionFailure("Unable to configure preview audio session: \(error)")
        }
    }
}

private enum VideoPreviewSupport {
    static func isPlayable(_ url: URL) async -> Bool {
        let asset = AVURLAsset(url: url)
        return (try? await asset.load(.isPlayable)) ?? false
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
