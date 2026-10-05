import AVFoundation
import SwiftUI
import UIKit

/// Owns inline playback independently of SwiftUI redraws. Every user seek or
/// pause invalidates an in-flight Play request so it cannot restart playback.
@MainActor
@Observable
final class TrimVideoPlayback {
    private(set) var player: AVPlayer?
    private(set) var isPlaying = false
    /// Preview playback rate, such as an edited video speed.
    private(set) var rate: Float = 1
    private var range: VideoTrimRange?
    private var isSeeking = false
    private var requestID = UUID()
    private var playTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var onPositionChange: ((Double) -> Void)?

    func prepare(url: URL, onPositionChange: @escaping (Double) -> Void) {
        stop()
        let player = AVPlayer(url: url)
        player.allowsExternalPlayback = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        self.player = player
        self.onPositionChange = onPositionChange
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.isSeeking, let range = self.range,
                      let seconds = self.player?.currentTime().seconds, seconds.isFinite else { return }
                self.onPositionChange?(range.clampedPlayhead(seconds))
            }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                              object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying, !self.isSeeking, let range = self.range else { return }
                self.pause()
                self.onPositionChange?(range.end)
            }
        }
    }

    func play(from seconds: Double, range: VideoTrimRange) {
        guard let player else { return }
        let hadPendingSeek = isSeeking
        pause()
        self.range = range
        player.currentItem?.forwardPlaybackEndTime = range.timeRange.end
        let start = seconds >= range.end - 1.0 / 600 ? range.start : range.clampedPlayhead(seconds)
        let needsSeek = hadPendingSeek || !player.currentTime().seconds.isFinite
            || abs(player.currentTime().seconds - start) > 1.0 / 600
        let id = requestID
        isPlaying = true
        onPositionChange?(start)
        // Resuming an unchanged cursor must not flush the decoder with an exact
        // seek. These are local files, so do not wait for a streaming buffer.
        guard needsSeek else {
            player.playImmediately(atRate: rate)
            return
        }
        isSeeking = true
        playTask = Task { @MainActor in
            guard !Task.isCancelled, requestID == id else { return }
            let finished = await player.seek(to: CMTime(seconds: start, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
            guard !Task.isCancelled, requestID == id else { return }
            isSeeking = false
            guard finished else { pause(); return }
            player.playImmediately(atRate: rate)
        }
    }

    /// Applies to the current playback as well as later Play requests.
    func setRate(_ rate: Float, preservesPitch: Bool = true) {
        self.rate = rate
        player?.currentItem?.audioTimePitchAlgorithm = preservesPitch ? .timeDomain : .varispeed
        if isPlaying, !isSeeking { player?.rate = rate }
    }

    func pause() {
        let shouldPublishPosition = isPlaying && !isSeeking
        requestID = UUID()
        playTask?.cancel()
        playTask = nil
        player?.pause()
        player?.currentItem?.cancelPendingSeeks()
        isPlaying = false
        isSeeking = false
        if shouldPublishPosition, let range,
           let seconds = player?.currentTime().seconds, seconds.isFinite {
            onPositionChange?(range.clampedPlayhead(seconds))
        }
    }

    func seek(to seconds: Double, range: VideoTrimRange) {
        guard let player, !isPlaying else { return }
        self.range = range
        requestID = UUID()
        let id = requestID
        isSeeking = true
        player.currentItem?.forwardPlaybackEndTime = range.timeRange.end
        let frameTime = min(range.clampedPlayhead(seconds), max(range.start, range.end - 1.0 / 600))
        player.seek(to: CMTime(seconds: frameTime, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.requestID == id else { return }
                self.isSeeking = false
            }
        }
    }

    func stop() {
        pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        onPositionChange = nil
    }
}

/// The trim selection stays local to the editor until Done; dragging only updates
/// the range and preview, never exports a new video.
struct VideoTrimTimeline: View {
    let url: URL
    let duration: Double
    @Binding var selection: VideoTrimRange
    @Binding var playhead: Double
    let isPlaying: Bool
    var onTogglePlayback: () -> Void
    var onInteractionBegan: () -> Void
    var onInteractionEnded: () -> Void
    var isAudio = false

    @State private var thumbnails: [UIImage] = []
    @State private var audioSamples: [Float] = []
    @State private var dragStart: VideoTrimRange?
    @Namespace private var timelineCoordinateSpace

    private let handleWidth: CGFloat = 22
    private let playButtonWidth: CGFloat = 36
    /// Corner radius shared by the strip, the selection window, and the handles' outer corners.
    private let stripCornerRadius: CGFloat = 8

    /// The start handle sits against the Play button until it is dragged away;
    /// their touching corners square off so the two read as one piece.
    private var isStartHandleDocked: Bool {
        selection.start <= 0.000_001
    }

    var body: some View {
        // A hairline seam keeps the docked start handle distinct from Play.
        HStack(alignment: .top, spacing: 1.5) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: playButtonWidth, height: 56)
                    .background(
                        UnevenRoundedRectangle(
                            topLeadingRadius: stripCornerRadius,
                            bottomLeadingRadius: stripCornerRadius,
                            bottomTrailingRadius: isStartHandleDocked ? 0 : stripCornerRadius,
                            topTrailingRadius: isStartHandleDocked ? 0 : stripCornerRadius,
                            style: .continuous
                        )
                        .fill(Theme.tint)
                        .animation(.snappy(duration: 0.18), value: isStartHandleDocked)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // Above the start handle's enlarged touch area.
            .zIndex(1)
            .accessibilityLabel(isPlaying ? (isAudio ? "Pause audio" : "Pause video") : (isAudio ? "Play audio" : "Play video"))
            .accessibilityIdentifier(isAudio ? "audioTrimPlayPause" : "videoTrimPlayPause")

            timeline
        }
        .task(id: url) { await loadThumbnails() }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { proxy in
                let width = max(1, proxy.size.width - handleWidth * 2)
                let left = handleWidth + width * selection.start / duration
                let right = handleWidth + width * selection.end / duration
                let playheadX = handleWidth + width * selection.clampedPlayhead(playhead) / duration

                ZStack(alignment: .leading) {
                    HStack(spacing: 0) {
                        if isAudio {
                            AudioWaveformView(samples: audioSamples)
                        } else if thumbnails.isEmpty {
                            Theme.fieldFill
                                .overlay(Image(systemName: "film").foregroundStyle(Theme.textMuted))
                        } else {
                            ForEach(thumbnails.indices, id: \.self) { index in
                                Image(uiImage: thumbnails[index])
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: width / CGFloat(thumbnails.count), height: 48)
                                    .clipped()
                            }
                        }
                    }
                    .frame(width: width, height: 48)
                    // Dim outside the selection inside the strip's clip so the
                    // rounded ends stay clean.
                    .overlay(alignment: .leading) {
                        ZStack(alignment: .leading) {
                            Color.black.opacity(0.6)
                                .frame(width: max(0, left - handleWidth))
                            Color.black.opacity(0.6)
                                .frame(width: max(0, handleWidth + width - right))
                                .offset(x: right - handleWidth)
                        }
                        .allowsHitTesting(false)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: stripCornerRadius, style: .continuous))
                    .offset(x: handleWidth)
                    .accessibilityHidden(true)

                    TrimSelectionFrame(border: 4, innerCornerRadius: stripCornerRadius)
                        .fill(Theme.tint, style: FillStyle(eoFill: true))
                        .frame(width: max(0, right - left), height: 56)
                        .offset(x: left)
                        .allowsHitTesting(false)

                    handle(isStart: true, width: width)
                        .offset(x: left - handleWidth)
                    handle(isStart: false, width: width)
                        .offset(x: right)

                    // Scrubbing owns the selected interior; the trim handles
                    // remain outside it. A playhead at either edge is still
                    // draggable without accidentally changing the trim range.
                    Color.clear
                        .frame(width: max(1, right - left), height: 56)
                        .contentShape(Rectangle())
                        .offset(x: left)
                        .gesture(
                            DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineCoordinateSpace))
                                .onChanged { value in seek(at: value.location.x, width: width) }
                                .onEnded { value in seek(at: value.location.x, width: width) }
                        )
                        .accessibilityElement()
                        .accessibilityLabel(isAudio ? "Audio playhead" : "Video playhead")
                        .accessibilityValue(Self.timestamp(selection.clampedPlayhead(playhead)))
                        .accessibilityHint("Swipe up or down to preview a different time within the trim range.")
                        .accessibilityAdjustableAction { direction in
                            let delta = direction == .increment ? 0.1 : -0.1
                            playhead = selection.clampedPlayhead(playhead + delta)
                        }
                        .accessibilityIdentifier(isAudio ? "audioTrimPlayhead" : "videoTrimPlayhead")

                    Capsule()
                        .fill(.white)
                        .frame(width: 4, height: 60)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 0.5)
                        .offset(x: playheadX - 2)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .frame(height: 56)
                .coordinateSpace(name: timelineCoordinateSpace)
            }
            .frame(height: 56)

            HStack {
                Text(Self.timestamp(selection.start))
                Spacer()
                Text(Self.timestamp(selection.clampedPlayhead(playhead)))
                    .foregroundStyle(Theme.text)
                    .accessibilityLabel("Current position")
                Spacer()
                Text(Self.timestamp(selection.end))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.textMuted)
        }
    }

    private func seek(at x: CGFloat, width: CGFloat) {
        let seconds = Double((x - handleWidth) / width) * duration
        playhead = selection.clampedPlayhead(seconds)
    }

    private func handle(isStart: Bool, width: CGFloat) -> some View {
        // Rounded only on the outer side so the handles and the selection
        // window read as one frame. The docked start handle joins the Play button.
        let outerRadius = isStart && isStartHandleDocked ? 0 : stripCornerRadius
        return UnevenRoundedRectangle(
            topLeadingRadius: isStart ? outerRadius : 0,
            bottomLeadingRadius: isStart ? outerRadius : 0,
            bottomTrailingRadius: isStart ? 0 : outerRadius,
            topTrailingRadius: isStart ? 0 : outerRadius,
            style: .continuous
        )
            .fill(Theme.tint)
            .animation(.snappy(duration: 0.18), value: isStartHandleDocked)
            .frame(width: handleWidth, height: 56)
            .overlay {
                Image(systemName: isStart ? "chevron.compact.left" : "chevron.compact.right")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .contentShape(Rectangle().inset(by: -11))
            .gesture(
                // The handle moves during this gesture. Measuring in its local
                // space feeds that movement back into the next drag sample.
                DragGesture(minimumDistance: 0, coordinateSpace: .named(timelineCoordinateSpace))
                    .onChanged { value in
                        if dragStart == nil {
                            dragStart = selection
                            onInteractionBegan()
                            Haptics.selection()
                        }
                        guard let initial = dragStart else { return }
                        let delta = Double(value.translation.width / width) * duration
                        let next = isStart
                            ? initial.movingStart(to: initial.start + delta, totalDuration: duration)
                            : initial.movingEnd(to: initial.end + delta, totalDuration: duration)
                        applySelection(next)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        onInteractionEnded()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(isStart ? "Trim start" : "Trim end")
            .accessibilityValue(Self.timestamp(isStart ? selection.start : selection.end))
            .accessibilityAdjustableAction { direction in
                let delta = direction == .increment ? 0.1 : -0.1
                update(seconds: (isStart ? selection.start : selection.end) + delta, isStart: isStart)
            }
            .accessibilityIdentifier(isAudio ? (isStart ? "audioTrimStart" : "audioTrimEnd") : (isStart ? "videoTrimStart" : "videoTrimEnd"))
    }

    private func update(seconds: Double, isStart: Bool) {
        onInteractionBegan()
        let next = isStart ? selection.movingStart(to: seconds, totalDuration: duration)
            : selection.movingEnd(to: seconds, totalDuration: duration)
        applySelection(next)
        onInteractionEnded()
    }

    private func applySelection(_ next: VideoTrimRange) {
        // Only an endpoint crossing the playhead pushes it. Expanding the
        // selection again leaves it at the last position it was pushed to.
        let nextPlayhead = next.clampedPlayhead(playhead)
        selection = next
        playhead = nextPlayhead
    }

    private func loadThumbnails() async {
        thumbnails = []
        if isAudio {
            let sourceURL = url
            let task = Task.detached(priority: .userInitiated) {
                AudioWaveformThumbnail.samples(from: sourceURL, barCount: 64, isCancelled: { Task.isCancelled }) ?? []
            }
            let samples = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return }
            audioSamples = samples
            return
        }
        let images = await Self.filmstrip(url: url, duration: duration)
        guard !Task.isCancelled else { return }
        thumbnails = images
    }

    /// Evenly spaced frames for a timeline strip.
    static func filmstrip(url: URL, duration: Double, count: Int = 10) async -> [UIImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 100)
        let tolerance = CMTime(seconds: min(0.1, duration / Double(count * 2)), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var images: [UIImage] = []
        for index in 0..<count {
            guard !Task.isCancelled else { return [] }
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / Double(count), preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                images.append(UIImage(cgImage: image))
            }
        }
        return images
    }

    static func timestamp(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let hours = tenths / 36_000
        let minutes = (tenths / 600) % 60
        let rest = Double(tenths % 600) / 10
        return hours > 0 ? String(format: "%d:%02d:%04.1f", hours, minutes, rest)
            : String(format: "%d:%04.1f", minutes, rest)
    }
}

/// Top and bottom edges of the selected range. The window inside has rounded
/// corners matching the thumbnail strip, so a full selection fits it exactly.
private struct TrimSelectionFrame: Shape {
    let border: CGFloat
    let innerCornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        let window = rect.insetBy(dx: 0, dy: border)
        guard window.width > 0, window.height > 0 else { return path }
        let radius = max(0, min(innerCornerRadius, window.width / 2, window.height / 2))
        path.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: window))
        return path
    }
}

/// Chooses which Live Photo frame is exported as the still, like Key Photo in
/// Photos. The dot marks the photo's original key photo; the selection snaps to it.
struct LivePhotoKeyPhotoTimeline: View {
    let movieURL: URL
    let duration: Double
    /// Movie time of the original key photo, when the movie records it.
    let originalTime: Double?
    /// Movie time of the frame shown in the selector.
    @Binding var selection: Double
    let isOriginal: Bool
    var onInteractionBegan: () -> Void
    var onInteractionEnded: () -> Void
    var onUseOriginal: () -> Void

    @State private var thumbnails: [UIImage] = []
    @State private var isDragging = false
    @State private var isSnappedToOriginal = false

    private let selectorWidth: CGFloat = 34
    private let stripHeight: CGFloat = 48
    private let frameStep = 1.0 / 30

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CardHeader(title: "Key Photo")
                Spacer(minLength: 8)
                if isOriginal {
                    Text("Original")
                        .font(.footnote)
                        .foregroundStyle(Theme.textMuted)
                } else {
                    Button("Use Original", action: onUseOriginal)
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .tint(Theme.tint)
                        .accessibilityHint("Exports the photo's original key photo.")
                        .accessibilityIdentifier("livePhotoUseOriginalKeyPhoto")
                }
            }
            .frame(minHeight: 28)

            strip

            HStack {
                Text(VideoTrimTimeline.timestamp(0))
                Spacer()
                Text(VideoTrimTimeline.timestamp(selection))
                    .foregroundStyle(Theme.text)
                    .accessibilityLabel("Key photo time")
                Spacer()
                Text(VideoTrimTimeline.timestamp(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.textMuted)
        }
        .task(id: movieURL) {
            let images = await VideoTrimTimeline.filmstrip(url: movieURL, duration: duration)
            guard !Task.isCancelled else { return }
            thumbnails = images
        }
    }

    private var strip: some View {
        GeometryReader { proxy in
            let travel = max(1, proxy.size.width - selectorWidth)
            let selectorX = travel * fraction(selection)

            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if thumbnails.isEmpty {
                        Theme.fieldFill
                            .overlay(Image(systemName: "livephoto").foregroundStyle(Theme.textMuted))
                    } else {
                        ForEach(thumbnails.indices, id: \.self) { index in
                            Image(uiImage: thumbnails[index])
                                .resizable()
                                .scaledToFill()
                                .frame(width: proxy.size.width / CGFloat(thumbnails.count), height: stripHeight)
                                .clipped()
                        }
                    }
                }
                .frame(width: proxy.size.width, height: stripHeight)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .offset(y: 12)
                .accessibilityHidden(true)

                if let originalTime {
                    Circle()
                        .fill(Theme.tint)
                        .frame(width: 6, height: 6)
                        .offset(x: travel * fraction(originalTime) + selectorWidth / 2 - 3)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }

                selector
                    .offset(x: selectorX, y: 8)
            }
            .frame(width: proxy.size.width, height: 64, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onInteractionBegan()
                            Haptics.selection()
                        }
                        select(seconds: Double((value.location.x - selectorWidth / 2) / travel) * duration)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onInteractionEnded()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Key photo")
            .accessibilityValue(isOriginal ? "Original, \(VideoTrimTimeline.timestamp(selection))"
                                : VideoTrimTimeline.timestamp(selection))
            .accessibilityHint("Swipe up or down to choose a different frame.")
            .accessibilityAdjustableAction { direction in
                onInteractionBegan()
                select(seconds: selection + (direction == .increment ? 0.1 : -0.1))
                onInteractionEnded()
            }
            .accessibilityIdentifier("livePhotoKeyPhotoTimeline")
        }
        .frame(height: 64)
    }

    /// An enlarged frame, like the playhead: white with a shadow over any frame.
    private var selector: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.surface)
            .overlay {
                if let thumbnail = nearestThumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: selectorWidth, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(.white, lineWidth: 3)
            }
            .frame(width: selectorWidth, height: 56)
            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
            .allowsHitTesting(false)
    }

    private var nearestThumbnail: UIImage? {
        guard !thumbnails.isEmpty else { return nil }
        let index = Int(fraction(selection) * Double(thumbnails.count))
        return thumbnails[min(thumbnails.count - 1, max(0, index))]
    }

    private func fraction(_ seconds: Double) -> Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, seconds / duration))
    }

    private func select(seconds: Double) {
        // Whole frames only; the original key photo pulls the selector in.
        var next = (min(max(0, seconds), duration) / frameStep).rounded() * frameStep
        next = min(next, max(0, duration - frameStep))
        let snaps = originalTime.map { abs(next - $0) <= max(frameStep * 2, duration * 0.02) } ?? false
        if snaps, let originalTime {
            next = originalTime
            if !isSnappedToOriginal { Haptics.selection() }
        }
        isSnappedToOriginal = snaps
        selection = next
    }
}

/// A sampled overview, like the video timeline's thumbnail strip. Selection
/// positions always use exact source time, independent of the waveform samples.
struct AudioWaveformView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let step = size.width / CGFloat(samples.count)
            let barWidth = max(1, step * 0.6)
            for (index, sample) in samples.enumerated() {
                let height = max(barWidth, CGFloat(sample) * (size.height - 12))
                let rect = CGRect(x: CGFloat(index) * step + (step - barWidth) / 2, y: (size.height - height) / 2,
                                  width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(Theme.tint))
            }
        }
        .background(Theme.secondaryFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            if samples.isEmpty {
                Image(systemName: "waveform").foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityHidden(true)
    }
}
