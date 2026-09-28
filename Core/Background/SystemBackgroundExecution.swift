@preconcurrency import BackgroundTasks
import UIKit

@MainActor
final class SystemBackgroundExecution: ConversionBackgroundPlatform {
    var remainingTime: TimeInterval { UIApplication.shared.backgroundTimeRemaining }

    private func identifier(for id: UUID) -> String {
        "\(Bundle.main.bundleIdentifier!).conversion.\(id.uuidString)"
    }

    func requestContinued(id: UUID, title: String, subtitle: String,
                          launched: @escaping (ContinuedConversionTask) -> Void,
                          expired: @escaping () -> Void,
                          failed: @escaping () -> Void) -> Bool {
        guard #available(iOS 26.0, *) else { return false }
        let identifier = identifier(for: id)
        let scheduler = BGTaskScheduler.shared
        // Register the concrete identifier once per attempt; the plist permits
        // the bundle-prefixed pattern. Never register the wildcard as a handler.
        guard scheduler.register(forTaskWithIdentifier: identifier, using: nil, launchHandler: { task in
            guard let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                Task { @MainActor in failed() }
                return
            }
            task.expirationHandler = {
                Task { @MainActor in expired() }
            }
            Task { @MainActor in
                launched(SystemContinuedConversionTask(task: task, title: title))
            }
        }) else { return false }

        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        request.strategy = .fail
        #if compiler(>=6.4)
        if #available(iOS 27.0, *) {
            // The completion-based API also reports service/connection errors
            // that the older submission API may fail to surface.
            DispatchQueue.global(qos: .userInitiated).async {
                scheduler.submitTaskRequest(request) { error in
                    guard let error else { return }
                    Task { @MainActor in
                        DiagnosticsLog.shared.record(error: error, context: "Request extended background conversion")
                        failed()
                    }
                }
            }
            return true
        }
        #endif
        do {
            try scheduler.submit(request)
            return true
        } catch {
            DiagnosticsLog.shared.record(error: error, context: "Request extended background conversion")
            return false
        }
    }

    func cancelRequest(id: UUID) {
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier(for: id))
        }
    }

    func beginLimited(expired: @escaping () -> Void) -> (() -> Void)? {
        let token = UIApplication.shared.beginBackgroundTask(withName: "Finish media conversion") {
            // UIKit invokes expiration on the main thread. Do not defer cleanup
            // past the handler's return with an unstructured Task.
            MainActor.assumeIsolated { expired() }
        }
        guard token != .invalid else { return nil }
        return { UIApplication.shared.endBackgroundTask(token) }
    }
}

@available(iOS 26.0, *)
@MainActor
private final class SystemContinuedConversionTask: ContinuedConversionTask {
    private let task: BGContinuedProcessingTask
    private let title: String
    private var finished = false

    init(task: BGContinuedProcessingTask, title: String) {
        self.task = task
        self.title = title
    }

    func update(fraction: Double?, stage: String, completedUnits: Int64) {
        guard !finished else { return }
        if let fraction {
            task.progress.totalUnitCount = 1_000
            task.progress.completedUnitCount = Int64(min(1, max(0, fraction)) * 1_000)
        } else {
            task.progress.totalUnitCount = -1
            task.progress.completedUnitCount = max(0, completedUnits)
        }
        task.updateTitle(title, subtitle: stage)
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        task.setTaskCompleted(success: success)
    }
}
