import AVFoundation
import SwiftUI
import UIKit

/// The live preview pinned above a tool's options: the tool's real output, refreshed as you edit.
struct ToolPreviewPanel: View {
    let kind: ToolPreviewKind
    let model: ToolPreviewModel
    @Binding var isExpanded: Bool

    @State private var showsOriginal = false
    @State private var fullScreen: IdentifiableURLs?

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            if isExpanded {
                surface
                    .containerRelativeFrame(.vertical) { height, _ in min(height * (kind == .audio ? 0.18 : 0.38), kind == .audio ? 140 : 440) }
                    .frame(maxWidth: .infinity)
                    .background(Theme.surfaceSunken, in: RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous))
                    .overlay(alignment: .topTrailing) { updatingBadge }
                    .overlay(alignment: .topLeading) { originalBadge }
                    .overlay(alignment: .bottomTrailing) { compareButton }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("tool.preview")
            }
            captionRow
        }
        .padding(.horizontal, Theme.Spacing.l)
        .padding(.top, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.s)
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .sheet(item: $fullScreen) { item in
            QuickLookPreview(urls: item.urls).ignoresSafeArea()
        }
    }

    // MARK: Surface

    @ViewBuilder private var surface: some View {
        if let result = model.result {
            switch kind {
            case .image, .pdf:
                pictures(result)
            case .animation:
                AnimatedFramesView(frames: result.frames, frameDelay: result.frameDelay)
                    .padding(Theme.Spacing.s)
            case .video:
                if let url = result.mediaURL { LoopingVideoView(url: url) }
            case .audio:
                if let url = result.mediaURL { WaveformPlayerView(url: url, waveform: result.waveform) }
            }
        } else if let message = model.message, let original = model.original, [.image, .pdf].contains(kind) {
            // The tool needs more input (e.g. caption text): keep showing the file, with the hint on it.
            ZStack(alignment: .bottom) {
                Image(decorative: original, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Label(message, systemImage: "info.circle")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 14)
            }
        } else if let message = model.message {
            Label(message, systemImage: "info.circle")
                .font(.subheadline)
                .foregroundStyle(Theme.textMuted)
                .multilineTextAlignment(.center)
                .padding()
        } else {
            VStack(spacing: Theme.Spacing.s) {
                ProgressView()
                Text("Preparing preview…").font(.footnote).foregroundStyle(Theme.textMuted)
            }
        }
    }

    @ViewBuilder private func pictures(_ result: ToolPreviewResult) -> some View {
        if result.images.count > 1 {
            // Tools that make several images (Split) show them all.
            let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: min(3, result.images.count))
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(result.images.enumerated()), id: \.offset) { _, image in
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
            }
            .padding(Theme.Spacing.s)
        } else if let image = (showsOriginal ? model.original : nil) ?? result.images.first {
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .padding(Theme.Spacing.s)
                .contentShape(Rectangle())
                // Hold to see the original; tap to open the real output full screen.
                .onLongPressGesture(minimumDuration: 0.15, maximumDistance: 40, perform: {}, onPressingChanged: { pressing in
                    showsOriginal = pressing && model.original != nil
                    if pressing { Haptics.impact(.light) }
                })
                .onTapGesture {
                    if let url = result.outputURL { fullScreen = IdentifiableURLs(urls: [url]) }
                }
                .accessibilityLabel(showsOriginal ? "Original" : "Preview of the result")
                .accessibilityHint("Touch and hold to compare with the original. Double-tap to view full screen.")
        }
    }

    // MARK: Overlays

    @ViewBuilder private var updatingBadge: some View {
        if model.isUpdating, model.result != nil {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Updating").font(.caption2.weight(.medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(8)
            .transition(.opacity)
            .accessibilityIdentifier("tool.preview.updating")
        }
    }

    private var canCompare: Bool {
        [.image, .pdf].contains(kind) && model.original != nil && (model.result?.images.count ?? 0) == 1
    }

    /// Before/after, visible (holding the picture works too).
    @ViewBuilder private var compareButton: some View {
        if canCompare {
            Button {
                Haptics.selection()
                showsOriginal.toggle()
            } label: {
                Label(showsOriginal ? "After" : "Before", systemImage: "square.split.2x1")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(8)
            .accessibilityLabel(showsOriginal ? "Show the result" : "Show the original")
            .accessibilityIdentifier("tool.preview.compare")
        }
    }

    @ViewBuilder private var originalBadge: some View {
        if showsOriginal {
            Text("Before")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: Capsule())
                .padding(8)
        }
    }

    private var captionRow: some View {
        HStack(spacing: Theme.Spacing.s) {
            if let message = model.message, model.result != nil {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(2)
            } else if let caption = model.result?.caption, isExpanded {
                Text(caption)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .lineLimit(1)
                    .accessibilityIdentifier("tool.preview.caption")
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Animated GIF/WebP

private struct AnimatedFramesView: UIViewRepresentable {
    let frames: [CGImage]
    let frameDelay: Double

    func makeUIView(context: Context) -> UIImageView {
        let view = UIImageView()
        view.contentMode = .scaleAspectFit
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateUIView(_ view: UIImageView, context: Context) {
        let images = frames.map { UIImage(cgImage: $0) }
        guard view.animationImages?.count != images.count || view.image == nil else { return }
        view.stopAnimating()
        view.animationImages = images
        view.animationDuration = frameDelay * Double(max(1, images.count))
        view.image = images.first
        view.startAnimating()
    }
}

// MARK: - Looping video

private struct LoopingVideoView: View {
    let url: URL
    @State private var player = AVQueuePlayer()
    @State private var looper: AVPlayerLooper?
    @State private var isMuted = true

    var body: some View {
        PlayerSurface(player: player)
            .overlay(alignment: .bottomTrailing) {
                Button {
                    isMuted.toggle()
                    player.isMuted = isMuted
                } label: {
                    Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.footnote)
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                }
                .padding(8)
                .accessibilityLabel(isMuted ? "Unmute preview" : "Mute preview")
            }
            .onAppear { load() }
            .onChange(of: url) { _, _ in load() }
            .onDisappear { player.pause() }
    }

    private func load() {
        player.pause()
        player.removeAllItems()
        let item = AVPlayerItem(url: url)
        looper = AVPlayerLooper(player: player, templateItem: item)
        player.isMuted = isMuted
        player.play()
    }
}

/// A bare video layer (no system controls); the surrounding UI owns playback.
struct PlayerSurface: UIViewRepresentable {
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
}

// MARK: - Audio

private struct WaveformPlayerView: View {
    let url: URL
    let waveform: [Float]
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var observer: Any?

    var body: some View {
        HStack(spacing: Theme.Spacing.m) {
            Button(action: toggle) {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .background(Theme.tint.opacity(0.15), in: Circle())
            }
            .accessibilityLabel(isPlaying ? "Pause preview" : "Play preview")
            GeometryReader { geometry in
                let bars = waveform.isEmpty ? Array(repeating: Float(0.1), count: 48) : waveform
                HStack(alignment: .center, spacing: 2) {
                    ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                        Capsule()
                            .fill(Double(index) / Double(bars.count) < progress ? Theme.tint : Theme.tint.opacity(0.3))
                            .frame(height: max(3, CGFloat(level) * geometry.size.height))
                    }
                }
                .frame(maxHeight: .infinity)
            }
        }
        .padding(Theme.Spacing.m)
        .onChange(of: url) { _, _ in stop() }
        .onDisappear { stop() }
    }

    private func toggle() {
        if isPlaying { stop(); return }
        let player = AVPlayer(url: url)
        self.player = player
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
            let duration = player.currentItem?.duration.seconds ?? 0
            progress = duration > 0 ? time.seconds / duration : 0
            if duration > 0, time.seconds >= duration - 0.05 { stop() }
        }
        player.play()
        isPlaying = true
    }

    private func stop() {
        if let observer, let player { player.removeTimeObserver(observer) }
        observer = nil
        player?.pause()
        player = nil
        isPlaying = false
        progress = 0
    }
}
