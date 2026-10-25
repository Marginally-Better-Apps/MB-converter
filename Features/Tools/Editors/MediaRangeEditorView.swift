import AVFoundation
import AVKit
import SwiftUI

struct MediaRangeEditorView: View {
    let url: URL
    let onDone: (Double, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var duration: Double = 0
    @State private var start: Double = 0
    @State private var end: Double = 0
    @State private var hasVideo = true
    @State private var frames: [UIImage] = []
    @State private var isPlaying = false
    @State private var timeObserver: Any?
    @State private var aspectRatio: CGFloat = 16 / 9
    @State private var playhead: Double?
    @State private var waveform: [Float] = []
    @State private var seeker = SmoothSeeker()
    private let initialRange: (start: Double, end: Double)?

    init(url: URL, initialRange: (start: Double, end: Double)?, onDone: @escaping (Double, Double) -> Void) {
        self.url = url
        self.initialRange = initialRange
        self.onDone = onDone
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: Theme.Spacing.xl) {
                preview
                VStack(spacing: Theme.Spacing.m) {
                    RangeTrack(start: $start, end: $end, duration: duration, frames: frames, waveform: waveform, playhead: playhead) { time in
                        // Show the frame under the handle as you drag, without queuing up stale seeks.
                        if isPlaying { stop() }
                        seeker.seek(player, to: time)
                    }
                    .frame(height: 56)
                    HStack {
                        timeLabel("Start", start)
                        Spacer()
                        timeLabel("Length", end - start)
                        Spacer()
                        timeLabel("End", end)
                    }
                    Button {
                        togglePlayback()
                    } label: {
                        Label(isPlaying ? "Pause" : "Play Selection", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .frame(maxWidth: 260)
                }
                .padding(.horizontal, Theme.Spacing.l)
                Spacer()
            }
            .padding(.top, Theme.Spacing.l)
            .screenBackground()
            .navigationTitle("Choose Range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { stop(); dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        stop()
                        onDone(start, end)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(end - start < 0.1)
                }
            }
        }
        .task { await load() }
        .onDisappear { stop() }
    }

    @ViewBuilder
    private var preview: some View {
        if hasVideo, let player {
            PlayerSurface(player: player)
                .aspectRatio(aspectRatio, contentMode: .fit)
                .frame(maxHeight: 420)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .contentShape(Rectangle())
                .onTapGesture { togglePlayback() }
                .padding(.horizontal, Theme.Spacing.l)
                .accessibilityLabel("Video preview")
                .accessibilityHint("Double-tap to play or pause the selection.")
        } else {
            VStack(spacing: Theme.Spacing.s) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .light))
                    .foregroundStyle(Theme.tint)
                Text(url.lastPathComponent)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
            .card()
            .padding(.horizontal, Theme.Spacing.l)
        }
    }

    private func timeLabel(_ title: String, _ value: Double) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.caption).foregroundStyle(Theme.textMuted)
            Text(Self.format(value)).font(.subheadline.monospacedDigit().weight(.medium)).foregroundStyle(Theme.text)
        }
    }

    static func format(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let minutes = Int(clamped) / 60
        let rest = clamped - Double(minutes * 60)
        return String(format: "%d:%04.1f", minutes, rest)
    }

    private func load() async {
        guard player == nil else { return }
        let playable = (try? await MediaToolkit.decodableURL(url)) ?? url
        let asset = AVURLAsset(url: playable)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : ((try? await MediaToolkit.probe(url).duration) ?? 0)
        let videoTracks = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        hasVideo = !videoTracks.isEmpty
        if let track = videoTracks.first,
           let natural = try? await track.load(.naturalSize),
           let transform = try? await track.load(.preferredTransform) {
            // Portrait phone videos are stored landscape with a rotation; show them as recorded.
            let shown = CGRect(origin: .zero, size: natural).applying(transform)
            if abs(shown.width) > 0, abs(shown.height) > 0 { aspectRatio = abs(shown.width) / abs(shown.height) }
        }
        start = min(initialRange?.start ?? 0, duration)
        end = min(initialRange?.end ?? duration, duration)
        player = AVPlayer(url: playable)
        if hasVideo, duration > 0 {
            let count = 8
            let times = (0 ..< count).map { duration * (Double($0) + 0.5) / Double(count) }
            frames = ((try? await MediaToolkit.frames(playable, times: times, maxSide: 160)) ?? []).map(UIImage.init(cgImage:))
        } else if !hasVideo {
            waveform = await Task.detached(priority: .userInitiated) { AudioWaveformThumbnail.samples(from: playable, barCount: 64) ?? [] }.value
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        if let observer = timeObserver { player.removeTimeObserver(observer) }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.03, preferredTimescale: 600), queue: .main) { time in
            playhead = time.seconds
            if time.seconds >= end {
                player.pause()
                isPlaying = false
                playhead = nil
            }
        }
        player.play()
        isPlaying = true
    }

    private func stop() {
        player?.pause()
        if let observer = timeObserver { player?.removeTimeObserver(observer) }
        timeObserver = nil
        isPlaying = false
        playhead = nil
    }
}

/// Keeps scrubbing smooth: at most one precise seek in flight, always heading to the latest
/// requested time, instead of a backlog of seeks to positions the finger has already left.
@MainActor
final class SmoothSeeker {
    private var target: CMTime?
    private var isSeeking = false

    func seek(_ player: AVPlayer?, to seconds: Double) {
        guard let player else { return }
        target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        guard !isSeeking else { return }
        perform(player)
    }

    private func perform(_ player: AVPlayer) {
        guard let time = target else { return }
        target = nil
        isSeeking = true
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.isSeeking = false
                if self.target != nil { self.perform(player) }
            }
        }
    }
}

/// A filmstrip track with two draggable handles.
private struct RangeTrack: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let frames: [UIImage]
    var waveform: [Float] = []
    var playhead: Double?
    let onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - handleWidth * 2
            let startX = duration > 0 ? CGFloat(start / duration) * width : 0
            let endX = duration > 0 ? CGFloat(end / duration) * width : width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if frames.isEmpty, !waveform.isEmpty {
                        // Audio: the waveform shows where the loud and quiet parts are.
                        HStack(alignment: .center, spacing: 1.5) {
                            ForEach(Array(waveform.enumerated()), id: \.offset) { _, level in
                                Capsule().fill(Theme.tint.opacity(0.7)).frame(height: max(3, CGFloat(level) * geometry.size.height * 0.85))
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.surfaceSunken)
                    } else if frames.isEmpty {
                        Theme.surfaceSunken
                    } else {
                        ForEach(Array(frames.enumerated()), id: \.offset) { _, frame in
                            Image(uiImage: frame).resizable().scaledToFill().frame(maxWidth: .infinity).clipped()
                        }
                    }
                }
                .frame(width: width, height: geometry.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .offset(x: handleWidth)

                // Dim the unselected parts.
                Rectangle().fill(Color.black.opacity(0.5)).frame(width: startX, height: geometry.size.height).offset(x: handleWidth)
                Rectangle().fill(Color.black.opacity(0.5)).frame(width: max(0, width - endX), height: geometry.size.height).offset(x: handleWidth + endX)

                if let playhead, duration > 0 {
                    // Where playback is right now.
                    Capsule()
                        .fill(Color.white)
                        .shadow(color: .black.opacity(0.4), radius: 1)
                        .frame(width: 3, height: geometry.size.height + 8)
                        .offset(x: handleWidth + CGFloat(playhead / duration) * width - 1.5)
                        .allowsHitTesting(false)
                }

                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Theme.primary, lineWidth: 3)
                    .frame(width: endX - startX + handleWidth * 2, height: geometry.size.height)
                    .offset(x: startX)
                    .allowsHitTesting(false)

                handle(systemName: "chevron.compact.left")
                    .offset(x: startX)
                    .gesture(DragGesture(coordinateSpace: .named("track")).onChanged { value in
                        let time = Double((value.location.x - handleWidth / 2) / width) * duration
                        start = min(max(0, time), end - 0.1)
                        onScrub(start)
                    })
                    .accessibilityLabel("Start")
                    .accessibilityValue(MediaRangeEditorView.format(start))
                    .accessibilityAdjustableAction { direction in
                        start = min(max(0, start + (direction == .increment ? 0.5 : -0.5)), end - 0.1)
                    }

                handle(systemName: "chevron.compact.right")
                    .offset(x: endX + handleWidth)
                    .gesture(DragGesture(coordinateSpace: .named("track")).onChanged { value in
                        let time = Double((value.location.x - handleWidth * 1.5) / width) * duration
                        end = max(min(duration, time), start + 0.1)
                        onScrub(end)
                    })
                    .accessibilityLabel("End")
                    .accessibilityValue(MediaRangeEditorView.format(end))
                    .accessibilityAdjustableAction { direction in
                        end = max(min(duration, end + (direction == .increment ? 0.5 : -0.5)), start + 0.1)
                    }
            }
            .coordinateSpace(name: "track")
        }
    }

    private func handle(systemName: String) -> some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(Theme.primary)
            .frame(width: handleWidth)
            .overlay { Image(systemName: systemName).font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.onPrimary) }
            .contentShape(Rectangle().inset(by: -12))
    }
}
