import XCTest
import UserNotifications
@testable import Converter

@MainActor
final class ConversionNotificationTests: XCTestCase {
    func testDeniedPermissionDoesNotScheduleAndRequestsOnlyOnce() async {
        let center = FakeNotificationClient()
        center.authorization = .init(needsPermission: true, alerts: false)
        let service = ConversionNotifications(center: center)
        service.requestPermission()
        service.requestPermission()
        service.schedule(id: "warning", attemptID: UUID(), after: 10)
        await waitUntil { center.settingsReads >= 2 }
        XCTAssertEqual(center.permissionRequests, 1)
        XCTAssertTrue(center.adds.isEmpty)
    }

    func testWarningContainsAttemptAndDoesNotRequestSound() async {
        let center = FakeNotificationClient()
        let clock = Date(timeIntervalSince1970: 100)
        let service = ConversionNotifications(center: center, now: { clock })
        let id = UUID()
        service.schedule(id: "warning", attemptID: id, after: 20)
        await waitUntil { center.adds.count == 1 }
        let request = center.adds[0]
        XCTAssertEqual(request.content.title, "Keep your conversion running")
        XCTAssertEqual(request.content.userInfo["conversionAttemptID"] as? String, id.uuidString)
        XCTAssertNil(request.content.sound)
        XCTAssertEqual((request.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval, 20)
    }

    func testCompletionDuringPendingAddRemovesLateNotification() async {
        let center = FakeNotificationClient()
        center.holdAdds = true
        let service = ConversionNotifications(center: center)
        service.schedule(id: "warning", attemptID: UUID(), after: 10)
        await waitUntil { center.addContinuation != nil }
        service.remove(id: "warning")
        center.completeAdd()
        await waitUntil { center.pendingRemovals.count >= 2 }
        XCTAssertFalse(center.pending.contains("warning"))
        XCTAssertEqual(center.deliveredRemovals, ["warning", "warning"])
    }

    func testReplacementsAreSerializedAndCannotOverwriteEarlierDeadline() async {
        let center = FakeNotificationClient()
        center.holdAdds = true
        let service = ConversionNotifications(center: center)
        let id = UUID()
        service.schedule(id: "warning", attemptID: id, after: 20)
        await waitUntil { center.addContinuation != nil }
        service.schedule(id: "warning", attemptID: id, after: 5)
        XCTAssertEqual(center.adds.count, 1)
        center.holdAdds = false
        center.completeAdd()
        await waitUntil { center.adds.count == 2 }
        let lastDelay = (center.adds.last?.trigger as? UNTimeIntervalNotificationTrigger)?.timeInterval
        XCTAssertLessThanOrEqual(lastDelay ?? 100, 5)
        XCTAssertTrue(center.pending.contains("warning"))
        service.remove(id: "warning")
    }

    func testCancelBeforeSchedulingAndStartupCleanupAreScoped() async {
        let center = FakeNotificationClient()
        center.pending = ["conversion-warning.old", "other-feature"]
        let service = ConversionNotifications(center: center)
        service.install()
        service.schedule(id: "conversion-warning.current", attemptID: UUID(), after: 10)
        service.remove(id: "conversion-warning.current")
        await waitUntil { center.pendingRemovals.contains("conversion-warning.old") }
        XCTAssertTrue(center.adds.isEmpty)
        XCTAssertEqual(center.pending, ["other-feature"])
    }

    private func waitUntil(_ condition: @escaping () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition never became true", file: file, line: line)
    }
}

@MainActor
private final class FakeNotificationClient: ConversionNotificationClient {
    weak var delegate: UNUserNotificationCenterDelegate?
    var authorization = ConversionWarningAuthorization(needsPermission: false, alerts: true)
    var permissionRequests = 0
    var settingsReads = 0
    var pending: Set<String> = []
    var adds: [UNNotificationRequest] = []
    var pendingRemovals: [String] = []
    var deliveredRemovals: [String] = []
    var holdAdds = false
    var addContinuation: CheckedContinuation<Void, Never>?
    func settings() async -> ConversionWarningAuthorization { settingsReads += 1; return authorization }
    func requestAuthorization() async throws -> Bool {
        permissionRequests += 1
        authorization.needsPermission = false
        return authorization.alerts
    }
    func pendingIdentifiers() async -> [String] { Array(pending) }
    func deliveredIdentifiers() async -> [String] { [] }
    func add(_ request: UNNotificationRequest) async throws {
        adds.append(request)
        if holdAdds { await withCheckedContinuation { addContinuation = $0 } }
        pending.insert(request.identifier)
    }
    func completeAdd() { let continuation = addContinuation; addContinuation = nil; continuation?.resume() }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pendingRemovals += identifiers
        pending.subtract(identifiers)
    }
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) { deliveredRemovals += identifiers }
}
