import AVFoundation
import Observation

/// Owns preparation, fallback retry, and the lifetime of the temporary playback file.
@MainActor
@Observable
final class MediaPreviewPlayback {
    private(set) var player: AVPlayer?
    private(set) var isPreparing = false
    private(set) var progress = 0.0
    private(set) var errorMessage: String?

    private var preparation: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var resource: MediaPreviewResource?
    private var requestID = UUID()
    private var isActive = true

    func prepare(
        sourceURL: URL,
        category: MediaCategory,
        initialTime: Double? = nil,
        makePlayerItem: @escaping @MainActor (URL) async throws -> AVPlayerItem = { AVPlayerItem(url: $0) }
    ) {
        stop()
        let id = requestID
        beginPreparation(sourceURL: sourceURL, category: category, initialTime: initialTime,
                         makePlayerItem: makePlayerItem, forceFallback: false, id: id)
    }

    private func beginPreparation(
        sourceURL: URL,
        category: MediaCategory,
        initialTime: Double?,
        makePlayerItem: @escaping @MainActor (URL) async throws -> AVPlayerItem,
        forceFallback: Bool,
        id: UUID
    ) {
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        resource = nil
        isPreparing = true
        progress = 0
        errorMessage = nil
        preparation = Task { @MainActor [self] in
            do {
                let prepared = try await MediaPreviewRenderer.playablePreview(
                    sourceURL: sourceURL, category: category, forceFallback: forceFallback,
                    progress: { value in
                        Task { @MainActor [weak self] in
                            guard let self, self.requestID == id, self.isPreparing else { return }
                            self.progress = max(self.progress, min(1, max(0, value)))
                        }
                    }
                )
                try Task.checkCancellation()
                let item = try await makePlayerItem(prepared.url)
                try Task.checkCancellation()
                guard requestID == id else { return }
                let newPlayer = AVPlayer(playerItem: item)
                newPlayer.allowsExternalPlayback = false
                newPlayer.usesExternalPlaybackWhileExternalScreenIsActive = false
                newPlayer.audiovisualBackgroundPlaybackPolicy = .pauses
                if let initialTime, initialTime.isFinite, initialTime > 0 {
                    _ = await withTaskCancellationHandler {
                        await newPlayer.seek(to: CMTime(seconds: initialTime, preferredTimescale: 600),
                                             toleranceBefore: .zero, toleranceAfter: .zero)
                    } onCancel: {
                        item.cancelPendingSeeks()
                    }
                    try Task.checkCancellation()
                }
                guard requestID == id else { return }
                resource = prepared
                player = newPlayer
                isPreparing = false
                statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                    let status = item.status
                    Task { @MainActor [weak self] in
                        guard let self, self.requestID == id, self.player?.currentItem === item else { return }
                        if status == .failed {
                            self.handleFailure(item.error, sourceURL: sourceURL, category: category,
                                               initialTime: self.player?.currentTime().seconds ?? initialTime,
                                               makePlayerItem: makePlayerItem, forceFallback: forceFallback, id: id)
                        }
                    }
                }
                if isActive {
                    PreviewAudioSession.configureForPlayback()
                    newPlayer.play()
                }
            } catch {
                guard !Task.isCancelled, requestID == id else { return }
                handleFailure(error, sourceURL: sourceURL, category: category, initialTime: initialTime,
                              makePlayerItem: makePlayerItem, forceFallback: forceFallback, id: id)
            }
        }
    }

    private func handleFailure(
        _ error: Error?, sourceURL: URL, category: MediaCategory, initialTime: Double?,
        makePlayerItem: @escaping @MainActor (URL) async throws -> AVPlayerItem,
        forceFallback: Bool, id: UUID
    ) {
        if !forceFallback {
            // Invalidate queued callbacks from the native/remux attempt before retrying.
            preparation?.cancel()
            requestID = UUID()
            beginPreparation(sourceURL: sourceURL, category: category, initialTime: initialTime,
                             makePlayerItem: makePlayerItem, forceFallback: true, id: requestID)
            return
        }
        if let error {
            DiagnosticsLog.shared.record(error: error, context: "Prepare media preview",
                                         metadata: ["Filename": sourceURL.lastPathComponent])
        }
        stop()
        errorMessage = "This file could not be prepared for playback."
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active {
            player?.pause()
            PreviewAudioSession.deactivate()
        }
    }

    func stop() {
        requestID = UUID()
        preparation?.cancel()
        preparation = nil
        statusObservation = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        resource = nil
        isPreparing = false
        progress = 0
        errorMessage = nil
        PreviewAudioSession.deactivate()
    }
}
