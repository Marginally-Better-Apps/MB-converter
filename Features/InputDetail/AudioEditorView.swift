import AVFoundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AudioEditorPreview {
    let playback = TrimVideoPlayback()
    private(set) var isPreparing = false
    private(set) var progress = 0.0
    var errorMessage: String?
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var cachedURL: URL?
    private var cachedEdits: AudioEditSettings?
    private var cachedDuration = 0.0

    func play(sourceURL: URL, duration: Double, edits: AudioEditSettings, position: Double,
              onPositionChange: @escaping (Double) -> Void) {
        pause()
        if cachedEdits == edits, cachedURL != nil {
            playCached(position: position, edits: edits)
            return
        }
        invalidate()
        let id = requestID
        isPreparing = true
        progress = 0
        errorMessage = nil
        task = Task { @MainActor in
            do {
                let output = try await AudioEditRenderer.preview(
                    sourceURL: sourceURL, sourceDuration: duration, edits: edits,
                    progress: { value in
                        Task { @MainActor in
                            guard self.requestID == id else { return }
                            self.progress = value
                        }
                    }
                )
                guard !Task.isCancelled, requestID == id else {
                    try? FileManager.default.removeItem(at: output)
                    return
                }
                cachedURL = output
                cachedEdits = edits
                cachedDuration = edits.outputDuration(sourceDuration: duration)
                playback.prepare(url: output) { time in
                    onPositionChange(min(edits.trimEnd ?? duration, edits.trimStart + time * edits.speed))
                }
                isPreparing = false
                playCached(position: position, edits: edits)
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                isPreparing = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func playCached(position: Double, edits: AudioEditSettings) {
        playback.play(from: max(0, (position - edits.trimStart) / edits.speed),
                      range: VideoTrimRange(start: 0, end: cachedDuration))
    }

    func seek(to position: Double, edits: AudioEditSettings) {
        pause()
        guard cachedEdits == edits else { return }
        playback.seek(to: max(0, (position - edits.trimStart) / edits.speed),
                      range: VideoTrimRange(start: 0, end: cachedDuration))
    }

    func pause() {
        requestID = UUID()
        task?.cancel()
        task = nil
        isPreparing = false
        playback.pause()
    }

    func invalidate() {
        pause()
        playback.stop()
        if let cachedURL { try? FileManager.default.removeItem(at: cachedURL) }
        cachedURL = nil
        cachedEdits = nil
    }
}

struct AudioEditorView: View {
    let url: URL
    let filename: String
    let duration: Double
    @Binding var settings: AudioEditSettings
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @State private var live: AudioEditSettings
    @State private var preview = AudioEditorPreview()
    @State private var playhead: Double
    @State private var undoHistory: [AudioEditSettings] = []
    @State private var interactionStart: AudioEditSettings?
    @State private var preservePitchPopoverPresented = false
    @State private var volumeOptionsPopoverPresented = false

    private let sliderLabelWidth: CGFloat = 88
    private let sliderColumnSpacing: CGFloat = 12

    init(url: URL, filename: String? = nil, duration: Double, settings: Binding<AudioEditSettings>) {
        self.url = url
        self.filename = filename ?? url.lastPathComponent
        self.duration = duration
        self._settings = settings
        self._live = State(initialValue: settings.wrappedValue)
        self._playhead = State(initialValue: settings.wrappedValue.trimStart)
    }

    private var range: VideoTrimRange {
        VideoTrimRange(start: live.trimStart, end: live.trimEnd ?? duration)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        audioPreview
                            .frame(minHeight: 180, maxHeight: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.top, 12)
                            .padding(.bottom, 10)
                            .background(Theme.background, ignoresSafeAreaEdges: [])

                        editingControls
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(minHeight: geometry.size.height)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
            .background(Theme.surface.ignoresSafeArea())
            .navigationTitle("Edit Audio")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        endInteraction()
                        settings = live
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .accessibilityIdentifier("audioEditDone")
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button {
                        endInteraction()
                        guard let previous = undoHistory.popLast() else { return }
                        preview.invalidate()
                        live = previous
                        playhead = range.clampedPlayhead(playhead)
                        Haptics.selection()
                    } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(undoHistory.isEmpty && interactionStart == nil)
                    .accessibilityLabel("Undo last audio edit")
                }
            }
            .toolbarBackground(Theme.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(Theme.surface, for: .bottomBar)
            .toolbarBackground(.visible, for: .bottomBar)
        }
        .tint(Theme.tint)
        .onAppear { PreviewAudioSession.configureForPlayback() }
        .onChange(of: live) { _, _ in preview.invalidate() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { preview.pause() }
        }
        .onDisappear {
            preview.invalidate()
            PreviewAudioSession.deactivate()
        }
        .alert("Couldn't preview audio", isPresented: Binding(
            get: { preview.errorMessage != nil },
            set: { if !$0 { preview.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { preview.errorMessage = nil }
        } message: {
            Text(preview.errorMessage ?? "")
        }
    }

    private var audioPreview: some View {
        ZStack {
            Color(white: 0.08)

            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 48, weight: .light))
                    .accessibilityHidden(true)
                Text(filename)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("audioPreviewFilename")
            }
            .foregroundStyle(.white)
            .padding(24)
            .frame(maxWidth: 560)
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Theme.separator, lineWidth: 1)
        }
    }

    private var editingControls: some View {
        VStack(spacing: 0) {
            trimControl

            VStack(spacing: 4) {
                channelControl
                volumeControl
                speedControl
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
        .foregroundStyle(Theme.text)
        .background(Theme.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.separator).frame(height: 1)
        }
    }

    private var trimControl: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Text(VideoTrimTimeline.timestamp(live.outputDuration(sourceDuration: duration)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                    .accessibilityLabel("Output duration")
            }
            .padding(.horizontal, 20)

            VideoTrimTimeline(
                url: url, duration: duration,
                selection: Binding(get: { range }, set: { selection in
                    live.trimStart = selection.start
                    live.trimEnd = abs(selection.end - duration) < 0.000001 ? nil : selection.end
                }),
                playhead: Binding(get: { playhead }, set: { time in
                    preview.seek(to: time, edits: live)
                    playhead = range.clampedPlayhead(time)
                }),
                isPlaying: preview.playback.isPlaying || preview.isPreparing,
                onTogglePlayback: {
                    endInteraction()
                    Haptics.selection()
                    if preview.playback.isPlaying || preview.isPreparing {
                        preview.pause()
                    } else {
                        preview.play(sourceURL: url, duration: duration, edits: live, position: playhead) {
                            playhead = range.clampedPlayhead($0)
                        }
                    }
                },
                onInteractionBegan: beginInteraction,
                onInteractionEnded: endInteraction,
                isAudio: true
            )
            if preview.isPreparing {
                ProgressView(value: preview.progress) {
                    Text("Preparing preview…").font(.caption)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }
        }
        .padding(.top, 10)
    }

    private var volumeControl: some View {
        sliderRow("Volume", systemImage: live.volume == 0 ? "speaker.slash" : "speaker.wave.2",
                  value: "\(Int((live.volume * 100).rounded()))%", identifier: "audioVolumeValue",
                  trailing: { volumeOptionsMenuButton }) {
            Slider(value: sliderBinding(\.volume), in: 0...2, step: 0.05, onEditingChanged: sliderInteraction)
                .accessibilityLabel("Export volume")
                .accessibilityValue("\(Int((live.volume * 100).rounded())) percent")
                .accessibilityIdentifier("audioVolumeSlider")
        }
    }

    private var volumeOptionsMenuButton: some View {
        Button {
            volumeOptionsPopoverPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Volume options")
        .accessibilityIdentifier("audioVolumeOptions")
        .popover(isPresented: $volumeOptionsPopoverPresented) {
            VStack(spacing: 0) {
                Button {
                    performEdit { live.limiterEnabled.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: live.limiterEnabled ? "square" : "checkmark.square.fill")
                            .foregroundStyle(Theme.tint)
                        Text("Allow clipping")
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(live.limiterEnabled ? "Off" : "On")
                .accessibilityIdentifier("audioRemoveLimiterToggle")
            }
            .padding(8)
            .frame(width: 220)
            .presentationCompactAdaptation(.popover)
        }
    }

    private var speedControl: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: sliderColumnSpacing))

        return layout {
            HStack(spacing: 8) {
                Image(systemName: "speedometer")
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text("Speed")
            }
            .font(.subheadline)
            .frame(width: sliderLabelWidth, alignment: .leading)

            HStack(spacing: sliderColumnSpacing) {
                Slider(value: sliderBinding(\.speed), in: 0.5...2, step: 0.05, onEditingChanged: sliderInteraction)
                    .accessibilityLabel("Export speed")
                    .accessibilityValue(String(format: "%.2f times", live.speed))
                    .accessibilityIdentifier("audioSpeedSlider")
                    .frame(minWidth: 80)
                sliderValue(String(format: "%.2f×", live.speed))
                    .accessibilityIdentifier("audioSpeedValue")
                preservePitchMenuButton
            }
        }
        .frame(minHeight: 44)
    }

    private var preservePitchMenuButton: some View {
        Button {
            preservePitchPopoverPresented = true
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Speed options")
        .accessibilityIdentifier("audioSpeedOptions")
        .popover(isPresented: $preservePitchPopoverPresented) {
            VStack(spacing: 0) {
                Button {
                    performEdit { live.preservePitch.toggle() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: live.preservePitch ? "checkmark.square.fill" : "square")
                            .foregroundStyle(Theme.tint)
                        Text("Preserve pitch")
                            .foregroundStyle(Theme.text)
                        Spacer(minLength: 0)
                    }
                    .font(.body)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(live.preservePitch ? "On" : "Off")
                .accessibilityIdentifier("audioPreservePitchToggle")
            }
            .padding(8)
            .frame(width: 220)
            // Keep the content transparent so the system popover supplies one surface.
            .presentationCompactAdaptation(.popover)
        }
    }

    private var channelControl: some View {
        HStack {
            Label("Channels", systemImage: "hifispeaker.2").font(.subheadline)
            Spacer()
            PopoverDropdown(
                title: live.channels.label,
                accessibilityLabel: "Channels",
                options: AudioChannelMode.allCases,
                optionTitle: { $0.label },
                isSelected: { $0 == live.channels },
                onSelect: { mode in performEdit { live.channels = mode } }
            )
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("audioChannelPicker")
        }
        .frame(minHeight: 44)
    }

    private func sliderRow<Content: View, Trailing: View>(_ title: String, systemImage: String, value: String,
                                                         identifier: String, @ViewBuilder trailing: () -> Trailing,
                                                         @ViewBuilder slider: () -> Content) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: sliderColumnSpacing))

        return layout {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
            }
            .font(.subheadline)
            .frame(width: sliderLabelWidth, alignment: .leading)
            HStack(spacing: sliderColumnSpacing) {
                slider()
                    .frame(minWidth: 80)
                sliderValue(value)
                    .accessibilityIdentifier(identifier)
                trailing()
            }
        }
        .frame(minHeight: 44)
    }

    private func sliderValue(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.monospacedDigit())
            .frame(minWidth: 52, alignment: .trailing)
            .fixedSize()
    }

    private func sliderInteraction(_ editing: Bool) {
        if editing { beginInteraction() } else { endInteraction() }
    }

    private func sliderBinding(_ keyPath: WritableKeyPath<AudioEditSettings, Double>) -> Binding<Double> {
        Binding(get: { live[keyPath: keyPath] }, set: { value in
            if interactionStart != nil {
                live[keyPath: keyPath] = value
            } else {
                // Accessibility adjustments may not send slider touch callbacks.
                performEdit { live[keyPath: keyPath] = value }
            }
        })
    }

    private func beginInteraction() {
        preview.pause()
        if interactionStart == nil { interactionStart = live }
    }

    private func endInteraction() {
        guard let previous = interactionStart else { return }
        interactionStart = nil
        if previous != live { undoHistory.append(previous) }
    }

    private func performEdit(_ action: () -> Void) {
        endInteraction()
        beginInteraction()
        action()
        endInteraction()
        Haptics.selection()
    }
}
