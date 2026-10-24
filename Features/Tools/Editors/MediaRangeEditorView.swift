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
                    RangeTrack(start: $start, end: $end, duration: duration, frames: frames) { time in
                        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
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
            VideoPlayer(player: player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                .padding(.horizontal, Theme.Spacing.l)
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
        hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
        start = min(initialRange?.start ?? 0, duration)
        end = min(initialRange?.end ?? duration, duration)
        player = AVPlayer(url: playable)
        if hasVideo, duration > 0 {
            let count = 8
            let times = (0 ..< count).map { duration * (Double($0) + 0.5) / Double(count) }
            frames = ((try? await MediaToolkit.frames(playable, times: times, maxSide: 160)) ?? []).map(UIImage.init(cgImage:))
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
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            if time.seconds >= end {
                player.pause()
                isPlaying = false
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
    }
}

/// A filmstrip track with two draggable handles.
private struct RangeTrack: View {
    @Binding var start: Double
    @Binding var end: Double
    let duration: Double
    let frames: [UIImage]
    let onScrub: (Double) -> Void

    private let handleWidth: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - handleWidth * 2
            let startX = duration > 0 ? CGFloat(start / duration) * width : 0
            let endX = duration > 0 ? CGFloat(end / duration) * width : width
            ZStack(alignment: .leading) {
                HStack(spacing: 0) {
                    if frames.isEmpty {
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
