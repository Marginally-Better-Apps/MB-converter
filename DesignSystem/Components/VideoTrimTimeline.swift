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
            player.playImmediately(atRate: 1)
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
            player.playImmediately(atRate: 1)
        }
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

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.tint)
                    .frame(width: 40, height: 56)
                    .background(Theme.secondaryFill, in: RoundedRectangle(cornerRadius: 5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.tint.opacity(0.18), lineWidth: 1)
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isPlaying ? (isAudio ? "Pause audio" : "Pause video") : (isAudio ? "Play audio" : "Play video"))
            .accessibilityIdentifier(isAudio ? "audioTrimPlayPause" : "videoTrimPlayPause")

            timeline
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(Theme.surface.opacity(0.96))
        .task(id: url) { await loadThumbnails() }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                            Theme.surface
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
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .offset(x: handleWidth)
                    .accessibilityHidden(true)

                    Color.black.opacity(0.6)
                        .frame(width: max(0, left - handleWidth), height: 48)
                        .offset(x: handleWidth)
                        .allowsHitTesting(false)
                    Color.black.opacity(0.6)
                        .frame(width: max(0, handleWidth + width - right), height: 48)
                        .offset(x: right)
                        .allowsHitTesting(false)

                    Rectangle()
                        .strokeBorder(Theme.tint, lineWidth: 3)
                        .frame(width: max(1, right - left), height: 52)
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

                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.white)
                        .frame(width: 3, height: 60)
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.white)
                                .frame(width: 9, height: 6)
                        }
                        .shadow(color: .black.opacity(0.8), radius: 1)
                        .offset(x: playheadX - 1.5)
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
        RoundedRectangle(cornerRadius: 5)
            .fill(Theme.tint)
            .frame(width: handleWidth, height: 56)
            .overlay {
                Capsule().fill(.white).frame(width: 3, height: 22)
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
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 100)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        var images: [UIImage] = []
        for index in 0..<10 {
            guard !Task.isCancelled else { return }
            let time = CMTime(seconds: duration * (Double(index) + 0.5) / 10, preferredTimescale: 600)
            if let (image, _) = try? await generator.image(at: time) {
                images.append(UIImage(cgImage: image))
            }
        }
        guard !Task.isCancelled else { return }
        thumbnails = images
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

/// A sampled overview, like the video timeline's thumbnail strip. Selection
/// positions always use exact source time, independent of the waveform samples.
struct AudioWaveformView: View {
    let samples: [Float]

    var body: some View {
        Canvas { context, size in
            guard !samples.isEmpty else { return }
            let step = size.width / CGFloat(samples.count)
            for (index, sample) in samples.enumerated() {
                let height = max(2, CGFloat(sample) * (size.height - 8))
                let rect = CGRect(x: CGFloat(index) * step, y: (size.height - height) / 2,
                                  width: max(1, step * 0.65), height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(Theme.tint))
            }
        }
        .background(Theme.secondaryFill)
        .overlay {
            if samples.isEmpty {
                Image(systemName: "waveform").foregroundStyle(Theme.textMuted)
            }
        }
        .accessibilityHidden(true)
    }
}
