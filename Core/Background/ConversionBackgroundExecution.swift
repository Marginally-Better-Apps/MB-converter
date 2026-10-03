import Foundation

enum ConversionBackgroundMode: Equatable {
    case preparing, extended, limited, foregroundOnly

    var description: String {
        switch self {
        case .preparing: "Preparing background processing…"
        case .extended: "Conversion can continue in the background."
        case .limited: "Background time is limited. Return to the app to keep converting."
        case .foregroundOnly: "Keep the app open to finish this conversion."
        }
    }
}

@MainActor
protocol ConversionBackgroundExecuting: AnyObject {
    func start(id: UUID, title: String, subtitle: String,
               ready: @escaping (ConversionBackgroundMode) -> Void,
               expired: @escaping () -> Void)
    func update(fraction: Double?, stage: String)
    func recordProcessedUnits(_ units: Int64)
    func tick()
    func setBackgrounded(_ backgrounded: Bool)
    func finish(success: Bool)
}

extension ConversionBackgroundExecuting {
    func recordProcessedUnits(_ units: Int64) {}
}

@MainActor
protocol ContinuedConversionTask: AnyObject {
    func update(fraction: Double?, stage: String, completedUnits: Int64)
    func finish(success: Bool)
}

@MainActor
protocol ConversionBackgroundPlatform: AnyObject {
    var remainingTime: TimeInterval { get }
    /// Returns false when unavailable; asynchronous rejection calls `failed`.
    func requestContinued(id: UUID, title: String, subtitle: String,
                          launched: @escaping (ContinuedConversionTask) -> Void,
                          expired: @escaping () -> Void,
                          failed: @escaping () -> Void) -> Bool
    func cancelRequest(id: UUID)
    /// The returned closure ends exactly this assertion.
    func beginLimited(expired: @escaping () -> Void) -> (() -> Void)?
}

@MainActor
protocol ConversionWarningNotifying: AnyObject {
    func requestPermission()
    func schedule(id: String, attemptID: UUID, after delay: TimeInterval)
    func remove(id: String)
}

/// Owns the OS execution lease, not the encoder. All transitions are serialized
/// on the main actor; every callback is scoped to one attempt.
@MainActor
final class ConversionBackgroundController: ConversionBackgroundExecuting {
    private let platform: ConversionBackgroundPlatform
    private let notifications: ConversionWarningNotifying
    private let now: () -> Date
    private var id: UUID?
    private var ready: ((ConversionBackgroundMode) -> Void)?
    private var expired: (() -> Void)?
    private var continued: ContinuedConversionTask?
    private var endLimited: (() -> Void)?
    private var mode = ConversionBackgroundMode.preparing
    private var backgrounded = false
    private var fraction: Double?
    private var completedUnits: Int64 = 0
    private var stage = "Preparing…"
    private var lastPublishedStage: String?
    private var lastPublishedAt: Date?
    private var warningID: String?
    private var warningDate: Date?

    init(platform: ConversionBackgroundPlatform, notifications: ConversionWarningNotifying,
         now: @escaping () -> Date = Date.init) {
        self.platform = platform
        self.notifications = notifications
        self.now = now
    }

    func start(id: UUID, title: String, subtitle: String,
               ready: @escaping (ConversionBackgroundMode) -> Void,
               expired: @escaping () -> Void) {
        precondition(self.id == nil, "Finish the previous background lease before starting another")
        self.id = id
        self.ready = ready
        self.expired = expired
        mode = .preparing
        fraction = nil
        completedUnits = 0
        stage = subtitle
        lastPublishedStage = nil
        lastPublishedAt = nil
        let submitted = platform.requestContinued(
            id: id, title: title, subtitle: subtitle,
            launched: { [weak self] task in
                guard let self, self.id == id, self.mode == .preparing else {
                    task.finish(success: false)
                    return
                }
                self.continued = task
                self.mode = .extended
                self.publishProgress()
                self.deliverReady()
            },
            expired: { [weak self] in self?.expire(id: id) },
            failed: { [weak self] in self?.startLimited(id: id) }
        )
        if !submitted { startLimited(id: id) }
    }

    private func startLimited(id: UUID) {
        guard self.id == id, mode == .preparing else { return }
        platform.cancelRequest(id: id)
        endLimited = platform.beginLimited { [weak self] in self?.expire(id: id) }
        mode = endLimited == nil ? .foregroundOnly : .limited
        if mode == .limited { notifications.requestPermission() }
        deliverReady()
        if backgrounded {
            if mode == .foregroundOnly { expire(id: id) }
            else { updateWarning() }
        }
    }

    private func deliverReady() {
        let callback = ready
        ready = nil
        callback?(mode)
    }

    private func expire(id: UUID) {
        guard self.id == id else { return }
        let callback = expired
        // Cancellation must be signalled before relinquishing execution time.
        callback?()
        if self.id == id { finish(success: false) }
    }

    func update(fraction: Double?, stage: String) {
        guard id != nil else { return }
        self.fraction = fraction.flatMap { $0.isFinite ? min(0.99, max(0, $0)) : nil }
        self.stage = stage
        if stage != lastPublishedStage { publishProgress() }
    }

    func tick() {
        guard id != nil else { return }
        if lastPublishedAt.map({ now().timeIntervalSince($0) >= 1 }) ?? true {
            publishProgress()
        }
        updateWarning()
    }

    func recordProcessedUnits(_ units: Int64) {
        // Actual decoded media time is useful to the scheduler even when the
        // total duration is unknown. It must never become a made-up percentage.
        completedUnits = max(completedUnits, units)
    }

    private func publishProgress() {
        guard let continued else { return }
        continued.update(fraction: fraction, stage: stage, completedUnits: completedUnits)
        lastPublishedStage = stage
        lastPublishedAt = now()
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard self.backgrounded != backgrounded else { return }
        self.backgrounded = backgrounded
        clearWarning()
        if backgrounded, let id, mode == .foregroundOnly { expire(id: id) }
        else { updateWarning() }
    }

    private func updateWarning() {
        guard backgrounded, mode == .limited, let id else { return }
        let remaining = platform.remainingTime
        // UIKit can return an effectively infinite value. This is only an
        // advisory estimate; cancellation never depends on it.
        guard remaining.isFinite, remaining > 0, remaining < Double.greatestFiniteMagnitude else { return }
        let currentDate = now()
        if let warningDate, warningDate <= currentDate { return } // one warning per background visit
        let delay = max(1, remaining - 10)
        let proposedDate = currentDate.addingTimeInterval(delay)
        if let warningDate, proposedDate.timeIntervalSince(warningDate) > -1 { return }
        let identifier = warningID ?? "conversion-warning.\(id).\(UUID())"
        warningID = identifier
        warningDate = proposedDate
        notifications.schedule(id: identifier, attemptID: id, after: delay)
    }

    private func clearWarning() {
        if let warningID { notifications.remove(id: warningID) }
        warningID = nil
        warningDate = nil
    }

    func finish(success: Bool) {
        guard let id else { return }
        self.id = nil
        ready = nil
        expired = nil
        clearWarning()
        platform.cancelRequest(id: id)
        if success { continued?.update(fraction: 1, stage: "Complete", completedUnits: completedUnits) }
        continued?.finish(success: success)
        continued = nil
        let end = endLimited
        endLimited = nil
        end?()
    }
}
