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
                    .containerRelativeFrame(.vertical) { height, _ in min(height * (kind == .audio ? 0.22 : 0.38), kind == .audio ? 160 : 440) }
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
            QuickLookSheet(urls: item.urls)
        }
    }

    // MARK: Surface

    @ViewBuilder private var surface: some View {
        if kind == .audio, model.result != nil || model.originalMediaURL != nil {
            // One player for "original only" and "Before/After", so your place survives each update.
            AudioCompareView(afterURL: model.result?.mediaURL, afterWaveform: model.result?.waveform ?? [],
                             beforeURL: model.originalMediaURL, beforeWaveform: model.originalWaveform,
                             hint: model.result == nil ? model.message : nil)
        } else if let result = model.result {
            switch kind {
            case .image, .pdf:
                pictures(result)
            case .animation:
                AnimatedFramesView(frames: result.frames, frameDelay: result.frameDelay)
                    .padding(Theme.Spacing.s)
            case .video:
                if let url = (showsOriginal ? model.originalMediaURL : nil) ?? result.mediaURL { LoopingVideoView(url: url) }
            case .audio:
                if let url = result.mediaURL {
                    AudioCompareView(afterURL: url, afterWaveform: result.waveform, beforeURL: nil, beforeWaveform: [])
                }
            }
        } else if kind == .video, let original = model.originalMediaURL, model.message != nil {
            LoopingVideoView(url: original)
                .overlay(alignment: .bottom) { waitingHint }
        } else if model.message != nil, let original = model.original, [.image, .pdf].contains(kind) {
            // The tool needs more input (e.g. caption text): keep showing the file, with the hint on it.
            ZStack(alignment: .bottom) {
                Image(decorative: original, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding(Theme.Spacing.s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                waitingHint
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

    @ViewBuilder private var waitingHint: some View {
        if let message = model.message {
            Label(message, systemImage: "info.circle")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 14)
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
        switch kind {
        case .image, .pdf: model.original != nil && (model.result?.images.count ?? 0) == 1
        // Audio has its own Before/After switch under the waveform.
        case .video: model.originalMediaURL != nil && model.result != nil
        default: false
        }
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

/// Plays the preview's audio with a waveform you can drag through, and a Before/After switch that
/// keeps your place, so you can hear exactly what a fade or volume change does. When the tool is
/// still waiting for a change, the original plays on its own.
struct AudioCompareView: View {
    /// The processed audio; nil until there's a change to hear.
    let afterURL: URL?
    let afterWaveform: [Float]
    let beforeURL: URL?
    let beforeWaveform: [Float]
    var hint: String?

    @State private var player = AVPlayer()
    @State private var loadedURL: URL?
    @State private var isPlaying = false
    @State private var position: Double = 0
    @State private var duration: Double = 0
    @State private var showsBefore = false
    @State private var isScrubbing = false
    @State private var observer: Any?
    @State private var endObserver: NSObjectProtocol?

    private var canCompare: Bool { afterURL != nil && beforeURL != nil }
    private var playingBefore: Bool { afterURL == nil || showsBefore }
    private var currentURL: URL? { playingBefore ? beforeURL : afterURL }
    private var bars: [Float] {
        let levels = playingBefore ? beforeWaveform : afterWaveform
        return levels.isEmpty ? Array(repeating: 0.12, count: 64) : levels
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            HStack(spacing: Theme.Spacing.m) {
                Button(action: togglePlayback) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .background(Theme.tint.opacity(0.15), in: Circle())
                }
                .accessibilityLabel(isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier("tool.preview.play")
                waveform
            }
            HStack(spacing: Theme.Spacing.s) {
                if canCompare {
                    Picker("Listen to", selection: $showsBefore) {
                        Text("Before").tag(true)
                        Text("After").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                    .accessibilityIdentifier("tool.preview.listen")
                } else if let hint {
                    Label(hint, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.textMuted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Text("\(Self.time(position)) / \(Self.time(duration))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
            }
        }
        .padding(Theme.Spacing.m)
        .onAppear { load(keepingPosition: false) }
        .onChange(of: currentURL) { _, _ in load(keepingPosition: true) }
        .onDisappear(perform: tearDown)
    }

    /// Tap or drag anywhere on the waveform to jump there; it keeps playing if it was.
    private var waveform: some View {
        GeometryReader { geometry in
            let progress = duration > 0 ? position / duration : 0
            HStack(alignment: .center, spacing: 2) {
                ForEach(Array(bars.enumerated()), id: \.offset) { index, level in
                    Capsule()
                        .fill(Double(index) / Double(bars.count) < progress ? Theme.tint : Theme.tint.opacity(0.3))
                        .frame(height: max(3, CGFloat(level) * geometry.size.height))
                }
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.text)
                    .frame(width: 2)
                    .offset(x: geometry.size.width * progress - 1)
                    .opacity(duration > 0 ? 1 : 0)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isScrubbing = true
                        seek(to: min(max(value.location.x / max(geometry.size.width, 1), 0), 1) * duration)
                    }
                    .onEnded { _ in isScrubbing = false }
            )
        }
        .frame(minHeight: 44)
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Self.time(position)) of \(Self.time(duration))")
        .accessibilityAdjustableAction { direction in
            seek(to: min(max(position + (direction == .increment ? 5 : -5), 0), duration))
        }
        .accessibilityIdentifier("tool.preview.waveform")
    }

    private func togglePlayback() {
        Haptics.impact(.light)
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, position >= duration - 0.05 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
    }

    /// Swaps in the current file. A new preview (or Before/After) keeps the playhead where it was.
    private func load(keepingPosition: Bool) {
        guard let url = currentURL, url != loadedURL else { return }
        loadedURL = url
        let resume = keepingPosition ? position : 0
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        if observer == nil {
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main) { time in
                MainActor.assumeIsolated {
                    if let seconds = player.currentItem?.duration.seconds, seconds.isFinite { duration = seconds }
                    if !isScrubbing { position = time.seconds }
                }
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            MainActor.assumeIsolated {
                isPlaying = false
                position = duration
            }
        }
        Task {
            if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite {
                duration = seconds
                seek(to: min(resume, seconds))
            }
        }
        if isPlaying { player.play() }
    }

    private func seek(to seconds: Double) {
        position = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    private func tearDown() {
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        loadedURL = nil
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
