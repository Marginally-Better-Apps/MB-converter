import XCTest
@testable import Converter

@MainActor
final class ConversionBackgroundTests: XCTestCase {
    func testExtendedTaskWaitsForLaunchAndFinishesOnce() {
        let platform = FakeBackgroundPlatform()
        let warnings = FakeWarnings()
        var clock = Date(timeIntervalSince1970: 1_000)
        let controller = ConversionBackgroundController(platform: platform, notifications: warnings, now: { clock })
        var modes: [ConversionBackgroundMode] = []
        controller.start(id: UUID(), title: "movie.mp4", subtitle: "Preparing", ready: { modes.append($0) }, expired: {})
        XCTAssertTrue(modes.isEmpty)
        let task = FakeContinuedTask()
        platform.launched?(task)
        XCTAssertEqual(modes, [.extended])
        controller.update(fraction: 0.2, stage: "Encoding")
        let count = task.updates.count
        controller.update(fraction: 0.4, stage: "Encoding")
        controller.tick()
        XCTAssertEqual(task.updates.count, count)
        clock.addTimeInterval(1)
        controller.tick()
        XCTAssertEqual(task.updates.last?.fraction, 0.4)
        controller.recordProcessedUnits(5_000)
        controller.update(fraction: nil, stage: "Reading timing")
        XCTAssertNil(task.updates.last?.fraction)
        XCTAssertEqual(task.completedUnits, 5_000)
        controller.update(fraction: 1, stage: "Finishing")
        XCTAssertEqual(task.updates.last?.fraction, 0.99)
        controller.finish(success: true)
        controller.finish(success: true)
        XCTAssertEqual(task.finishes, [true])
        XCTAssertEqual(task.updates.last?.fraction, 1)
        XCTAssertEqual(warnings.permissionRequests, 0)
    }

    func testUnavailableAndRejectedRequestsFallBackWithoutDuplicateStarts() {
        for available in [false, true] {
            let platform = FakeBackgroundPlatform()
            platform.available = available
            let warnings = FakeWarnings()
            let controller = ConversionBackgroundController(platform: platform, notifications: warnings)
            var modes: [ConversionBackgroundMode] = []
            controller.start(id: UUID(), title: "x", subtitle: "Preparing", ready: { modes.append($0) }, expired: {})
            if available { platform.failed?(); platform.failed?() }
            XCTAssertEqual(modes, [.limited])
            XCTAssertEqual(platform.begins, 1)
            XCTAssertEqual(warnings.permissionRequests, 1)
            let late = FakeContinuedTask()
            platform.launched?(late)
            XCTAssertEqual(late.finishes, available ? [false] : [])
            controller.finish(success: false)
            controller.finish(success: false)
            XCTAssertEqual(platform.ends, 1)
        }
    }

    func testExpirationCancelsBeforeLeaseEndsAndIgnoresStaleCallback() {
        let platform = FakeBackgroundPlatform()
        platform.available = false
        let controller = ConversionBackgroundController(platform: platform, notifications: FakeWarnings())
        var expirations = 0
        controller.start(id: UUID(), title: "x", subtitle: "Preparing", ready: { _ in }, expired: {
            XCTAssertEqual(platform.ends, 0)
            expirations += 1
        })
        let oldExpiry = platform.limitedExpiry
        oldExpiry?()
        XCTAssertEqual(platform.ends, 1)
        controller.start(id: UUID(), title: "y", subtitle: "Preparing", ready: { _ in }, expired: { expirations += 1 })
        oldExpiry?()
        XCTAssertEqual(expirations, 1)
        controller.finish(success: false)
        XCTAssertEqual(platform.ends, 2)
    }

    func testSystemCancellationCompletesContinuedTaskAsFailure() {
        let platform = FakeBackgroundPlatform()
        let controller = ConversionBackgroundController(platform: platform, notifications: FakeWarnings())
        var interrupted = false
        controller.start(id: UUID(), title: "x", subtitle: "Preparing", ready: { _ in }, expired: { interrupted = true })
        let task = FakeContinuedTask()
        platform.launched?(task)
        platform.continuedExpiry?()
        platform.continuedExpiry?()
        XCTAssertTrue(interrupted)
        XCTAssertEqual(task.finishes, [false])
    }

    func testWarningMovesEarlierButNeverRepeatsWithinBackgroundVisit() {
        let platform = FakeBackgroundPlatform()
        platform.available = false
        platform.remainingTime = 30
        let warnings = FakeWarnings()
        var clock = Date(timeIntervalSince1970: 100)
        let controller = ConversionBackgroundController(platform: platform, notifications: warnings, now: { clock })
        let attempt = UUID()
        controller.start(id: attempt, title: "x", subtitle: "Preparing", ready: { _ in }, expired: {})
        controller.tick()
        XCTAssertTrue(warnings.scheduled.isEmpty)
        controller.setBackgrounded(true)
        XCTAssertEqual(warnings.scheduled.last?.delay, 20)
        XCTAssertEqual(warnings.scheduled.last?.attempt, attempt)
        clock.addTimeInterval(1)
        platform.remainingTime = 15
        controller.tick()
        XCTAssertEqual(warnings.scheduled.last?.delay, 5)
        XCTAssertEqual(Set(warnings.scheduled.map(\.id)).count, 1)
        platform.remainingTime = 50
        controller.tick()
        XCTAssertEqual(warnings.scheduled.count, 2)
        clock.addTimeInterval(6)
        platform.remainingTime = 3
        controller.tick()
        XCTAssertEqual(warnings.scheduled.count, 2)
        controller.setBackgrounded(false)
        XCTAssertEqual(warnings.removed.count, 1)
        controller.setBackgrounded(true)
        XCTAssertEqual(warnings.scheduled.count, 3)
        XCTAssertEqual(warnings.scheduled.last?.delay, 1)
        controller.finish(success: true)
        XCTAssertEqual(warnings.removed.count, 2)
    }

    func testUnknownEstimatesDoNotInventDeadlineOrCancel() {
        let platform = FakeBackgroundPlatform()
        platform.available = false
        let warnings = FakeWarnings()
        let controller = ConversionBackgroundController(platform: platform, notifications: warnings)
        var expired = false
        controller.start(id: UUID(), title: "x", subtitle: "Preparing", ready: { _ in }, expired: { expired = true })
        for value in [Double.infinity, .nan, .greatestFiniteMagnitude, 0, -1] {
            platform.remainingTime = value
            controller.setBackgrounded(true)
            controller.tick()
        }
        XCTAssertTrue(warnings.scheduled.isEmpty)
        XCTAssertFalse(expired)
        controller.finish(success: false)
    }

    func testFailureToAcquireAnyTimeStopsOnlyWhenBackgrounded() {
        let platform = FakeBackgroundPlatform()
        platform.available = false
        platform.limitedAvailable = false
        let controller = ConversionBackgroundController(platform: platform, notifications: FakeWarnings())
        var expired = false
        var mode: ConversionBackgroundMode?
        controller.start(id: UUID(), title: "x", subtitle: "Preparing", ready: { mode = $0 }, expired: { expired = true })
        XCTAssertEqual(mode, .foregroundOnly)
        XCTAssertFalse(expired)
        controller.setBackgrounded(true)
        XCTAssertTrue(expired)
        XCTAssertEqual(platform.ends, 0)
    }

    func testExtendedProcessingDoesNotScheduleTimeLimitWarnings() {
        let platform = FakeBackgroundPlatform()
        platform.remainingTime = 5
        let warnings = FakeWarnings()
        let controller = ConversionBackgroundController(platform: platform, notifications: warnings)
        controller.start(id: UUID(), title: "x", subtitle: "Preparing", ready: { _ in }, expired: {})
        platform.launched?(FakeContinuedTask())
        controller.setBackgrounded(true)
        controller.tick()
        XCTAssertTrue(warnings.scheduled.isEmpty)
        controller.finish(success: false)
    }
}

@MainActor
final class FakeBackgroundPlatform: ConversionBackgroundPlatform {
    var available = true
    var limitedAvailable = true
    var remainingTime: TimeInterval = .greatestFiniteMagnitude
    var launched: ((ContinuedConversionTask) -> Void)?
    var failed: (() -> Void)?
    var limitedExpiry: (() -> Void)?
    var continuedExpiry: (() -> Void)?
    var begins = 0
    var ends = 0
    var cancelledRequests: [UUID] = []
    func requestContinued(id: UUID, title: String, subtitle: String,
                          launched: @escaping (ContinuedConversionTask) -> Void,
                          expired: @escaping () -> Void, failed: @escaping () -> Void) -> Bool {
        guard available else { return false }
        self.launched = launched
        self.failed = failed
        continuedExpiry = expired
        return true
    }
    func cancelRequest(id: UUID) { cancelledRequests.append(id) }
    func beginLimited(expired: @escaping () -> Void) -> (() -> Void)? {
        begins += 1
        limitedExpiry = expired
        guard limitedAvailable else { return nil }
        return { self.ends += 1 }
    }
}

@MainActor
final class FakeContinuedTask: ContinuedConversionTask {
    var updates: [(fraction: Double?, stage: String)] = []
    var finishes: [Bool] = []
    var completedUnits: Int64 = 0
    func update(fraction: Double?, stage: String, completedUnits: Int64) {
        updates.append((fraction, stage))
        self.completedUnits = completedUnits
    }
    func finish(success: Bool) { finishes.append(success) }
}

@MainActor
final class FakeWarnings: ConversionWarningNotifying {
    var permissionRequests = 0
    var scheduled: [(id: String, attempt: UUID, delay: TimeInterval)] = []
    var removed: [String] = []
    func requestPermission() { permissionRequests += 1 }
    func schedule(id: String, attemptID: UUID, after delay: TimeInterval) { scheduled.append((id, attemptID, delay)) }
    func remove(id: String) { removed.append(id) }
}
