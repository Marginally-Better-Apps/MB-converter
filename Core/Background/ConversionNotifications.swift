import Foundation
import UserNotifications

extension Notification.Name {
    static let conversionWarningOpened = Notification.Name("conversionWarningOpened")
}

@MainActor
final class ConversionNotifications: NSObject, ConversionWarningNotifying, UNUserNotificationCenterDelegate {
    static let shared = ConversionNotifications()
    private let center: ConversionNotificationClient
    private let now: () -> Date

    init(center: ConversionNotificationClient? = nil, now: @escaping () -> Date = Date.init) {
        self.center = center ?? SystemConversionNotificationClient()
        self.now = now
        super.init()
    }
    private var permissionTask: Task<Void, Never>?
    private var operation: Task<Void, Never>?
    private var desired: [String: UUID] = [:]

    func install() {
        center.delegate = self
        // Attempts do not survive process termination. Remove only our own
        // stale warnings, never other notification categories.
        Task {
            let pending = await center.pendingIdentifiers()
            let delivered = await center.deliveredIdentifiers()
            let ids = Set(pending + delivered)
                .filter { $0.hasPrefix("conversion-warning.") && desired[$0] == nil }
            center.removePendingNotificationRequests(withIdentifiers: Array(ids))
            center.removeDeliveredNotifications(withIdentifiers: Array(ids))
        }
    }

    func requestPermission() {
        guard permissionTask == nil else { return }
        permissionTask = Task {
            let settings = await center.settings()
            guard settings.needsPermission else { return }
            do {
                _ = try await center.requestAuthorization()
            } catch {
                DiagnosticsLog.shared.record(error: error, context: "Authorize conversion warnings")
            }
        }
    }

    func schedule(id: String, attemptID: UUID, after delay: TimeInterval) {
        let revision = UUID()
        desired[id] = revision
        let deliveryDate = now().addingTimeInterval(delay)
        let previous = operation
        operation = Task {
            await previous?.value
            await permissionTask?.value
            guard desired[id] == revision else { return }
            let settings = await center.settings()
            guard desired[id] == revision,
                  settings.alerts else { return }

            let content = UNMutableNotificationContent()
            content.title = "Keep your conversion running"
            content.body = "Background time is running low. Open MB Converter to continue."
            content.userInfo = ["conversionAttemptID": attemptID.uuidString]
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(1, deliveryDate.timeIntervalSince(now())), repeats: false
            )
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                DiagnosticsLog.shared.record(error: error, context: "Schedule conversion warning")
            }
            // add() may finish after foregrounding/cancellation. Serializing
            // adds prevents this cleanup from deleting a newer replacement.
            if desired[id] != revision {
                center.removePendingNotificationRequests(withIdentifiers: [id])
                center.removeDeliveredNotifications(withIdentifiers: [id])
            }
        }
    }

    func remove(id: String) {
        desired[id] = nil
        center.removePendingNotificationRequests(withIdentifiers: [id])
        center.removeDeliveredNotifications(withIdentifiers: [id])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier,
           let value = response.notification.request.content.userInfo["conversionAttemptID"] as? String,
           let id = UUID(uuidString: value) {
            Task { @MainActor in
                NotificationCenter.default.post(name: .conversionWarningOpened, object: id)
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A late warning should never interrupt someone already in the app.
        completionHandler([])
    }
}


struct ConversionWarningAuthorization {
    var needsPermission: Bool
    var alerts: Bool
}

@MainActor
protocol ConversionNotificationClient: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func settings() async -> ConversionWarningAuthorization
    func requestAuthorization() async throws -> Bool
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
private final class SystemConversionNotificationClient: ConversionNotificationClient {
    private let center = UNUserNotificationCenter.current()
    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }
    func settings() async -> ConversionWarningAuthorization {
        let settings = await center.notificationSettings()
        return ConversionWarningAuthorization(
            needsPermission: settings.authorizationStatus == .notDetermined,
            alerts: (settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional)
                && settings.alertSetting == .enabled
        )
    }
    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert])
    }
    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }
    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}
