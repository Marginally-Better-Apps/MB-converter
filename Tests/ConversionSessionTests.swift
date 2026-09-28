import XCTest
@testable import Converter

@MainActor
final class ConversionSessionTests: XCTestCase {
    private let input = MediaFile(url: URL(fileURLWithPath: "/tmp/source.mp4"), originalFilename: "source.mp4",
                                  category: .video, sizeOnDisk: 1_000, duration: 10, containerFormat: "mp4")
    private let config = ConversionConfig(outputFormat: .webm)

    func testBackgroundCompletionRecordsHistoryBeforeReleasingLeaseExactlyOnce() async throws {
        let converter = ManualConverter()
        let started = expectation(description: "started")
        converter.didStart = { started.fulfill() }
        let background = FakeSessionBackground()
        var records = 0
        var clock = Date(timeIntervalSince1970: 100)
        let session = ProcessingViewModel(background: background, makeConverter: { _, _ in converter },
                                          recordResult: { _, _, _ in records += 1 }, validate: { _, _ in },
                                          now: { clock }, runsTimer: false)
        background.didFinish = { success in if success { XCTAssertEqual(records, 1) } }
        session.start(input: input, config: config)
        await fulfillment(of: [started], timeout: 2)
        session.setBackgrounded(true)
        clock.addTimeInterval(12)
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output.url) }
        converter.succeed(output)
        await waitUntil { session.result != nil }
        XCTAssertEqual(session.result, output)
        XCTAssertEqual(session.elapsedSeconds, 12)
        XCTAssertEqual(records, 1)
        XCTAssertEqual(background.finishes, [true])
        session.start(input: input, config: config) // view reconstruction
        session.cancel()
        XCTAssertEqual(records, 1)
        XCTAssertEqual(background.starts, 1)
    }

    func testExpirationRejectsLateSuccessAndRetryWaitsForPreviousWorker() async throws {
        let first = ManualConverter()
        let second = ManualConverter()
        let firstStarted = expectation(description: "first started")
        let secondStarted = expectation(description: "second started")
        first.didStart = { firstStarted.fulfill() }
        second.didStart = { secondStarted.fulfill() }
        let background = FakeSessionBackground()
        var created = 0
        var records = 0
        let session = ProcessingViewModel(background: background, makeConverter: { _, _ in
            created += 1
            return created == 1 ? first : second
        }, recordResult: { _, _, _ in records += 1 }, validate: { _, _ in }, runsTimer: false)
        session.start(input: input, config: config)
        await fulfillment(of: [firstStarted], timeout: 2)
        let oldID = session.attemptID
        let oldExpiry = background.expired
        oldExpiry?()
        XCTAssertTrue(session.isInterrupted)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(first.cancellations, 1)
        XCTAssertNotNil(session.errorMessage)
        session.retry(input: input, config: config)
        XCTAssertNotEqual(session.attemptID, oldID)
        oldExpiry?()
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(created, 1)
        let stale = try makeOutput()
        first.succeed(stale) // non-cooperative encoder returned after cancellation
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.url.path))
        first.emit(0.98)
        await Task.yield()
        XCTAssertEqual(session.progress, 0)
        XCTAssertEqual(records, 0)
        let output = try makeOutput()
        defer { try? FileManager.default.removeItem(at: output.url) }
        second.succeed(output)
        await waitUntil { session.result != nil }
        XCTAssertEqual(records, 1)
        XCTAssertEqual(background.finishes, [false, true])
    }

    func testProgressIsMonotonicAndReservesCompletionUntilFinalization() async throws {
        let converter = ManualConverter()
        let started = expectation(description: "started")
        converter.didStart = { started.fulfill() }
        let background = FakeSessionBackground()
        let session = ProcessingViewModel(background: background, makeConverter: { _, _ in converter },
                                          recordResult: { _, _, _ in }, validate: { _, _ in }, runsTimer: false)
        session.start(input: input, config: config)
        await fulfillment(of: [started], timeout: 2)
        converter.emit(0.44)
        await waitUntil { session.progress == 0.44 }
        XCTAssertEqual(session.passLabel, "Analyzing...")
        converter.emit(0.46)
        await waitUntil { session.progress == 0.46 }
        XCTAssertEqual(session.passLabel, "Encoding...")
        converter.emit(0.1)
        converter.emit(.nan)
        converter.emit(1)
        await waitUntil { session.progress == 0.99 }
        XCTAssertNil(session.result)
        XCTAssertTrue(session.isRunning)
        converter.fail(ConversionError.engineFailed("finalization failed"))
        await waitUntil { !session.isRunning }
        XCTAssertEqual(background.finishes, [false])
        XCTAssertNil(session.result)
    }

    func testUnknownDurationDoesNotPublishFakePercentage() async {
        let converter = ManualConverter()
        let started = expectation(description: "started")
        converter.didStart = { started.fulfill() }
        let background = FakeSessionBackground()
        let session = ProcessingViewModel(background: background, makeConverter: { _, _ in converter },
                                          recordResult: { _, _, _ in }, validate: { _, _ in }, runsTimer: false)
        let unknown = MediaFile(url: input.url, originalFilename: "stream.mp4", category: .video,
                                sizeOnDisk: 1_000, containerFormat: "mp4")
        session.start(input: unknown, config: config)
        await fulfillment(of: [started], timeout: 2)
        converter.emit(0)
        await waitUntil { !background.updates.isEmpty }
        XCTAssertNil(background.updates.last?.fraction)
        converter.emit(0.45)
        await waitUntil { session.progressIsDeterminate }
        XCTAssertEqual(session.progress, 0.45)
        session.cancel()
        converter.fail(ConversionError.cancelled)
    }

    func testDuplicateLaunchAndCancelBeforeLaunchDoNotCreateExtraWorkers() async {
        let background = FakeSessionBackground()
        background.launchImmediately = false
        var workers = 0
        let converter = ManualConverter()
        let started = expectation(description: "started")
        converter.didStart = { started.fulfill() }
        let session = ProcessingViewModel(background: background, makeConverter: { _, _ in workers += 1; return converter },
                                          recordResult: { _, _, _ in XCTFail("Cancelled work recorded") },
                                          validate: { _, _ in }, runsTimer: false)
        session.start(input: input, config: config)
        let oldReady = background.ready
        session.cancel()
        oldReady?(.extended)
        XCTAssertEqual(workers, 0)
        session.retry(input: input, config: config)
        background.ready?(.limited)
        background.ready?(.limited)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(workers, 1)
        session.cancel()
        converter.fail(ConversionError.cancelled)
    }

    func testValidationFailureNeverAcquiresBackgroundLease() {
        let background = FakeSessionBackground()
        let session = ProcessingViewModel(background: background, validate: { _, _ in throw ConversionError.unsupportedConversion }, runsTimer: false)
        session.start(input: input, config: config)
        XCTAssertEqual(background.starts, 0)
        XCTAssertFalse(session.isRunning)
        XCTAssertNotNil(session.errorMessage)
    }

    private func makeOutput() throws -> ConversionResult {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".webm")
        try Data([1, 2, 3]).write(to: url)
        return ConversionResult(url: url, outputFormat: .webm, sizeOnDisk: 3)
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
private final class FakeSessionBackground: ConversionBackgroundExecuting {
    var ready: ((ConversionBackgroundMode) -> Void)?
    var expired: (() -> Void)?
    var launchImmediately = true
    var starts = 0
    var finishes: [Bool] = []
    var updates: [(fraction: Double?, stage: String)] = []
    var didFinish: ((Bool) -> Void)?
    func start(id: UUID, title: String, subtitle: String, ready: @escaping (ConversionBackgroundMode) -> Void, expired: @escaping () -> Void) {
        starts += 1
        self.ready = ready
        self.expired = expired
        if launchImmediately { ready(.limited) }
    }
    func update(fraction: Double?, stage: String) { updates.append((fraction, stage)) }
    func tick() {}
    func setBackgrounded(_ backgrounded: Bool) {}
    func finish(success: Bool) { finishes.append(success); didFinish?(success) }
}

private final class ManualConverter: Converter, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ConversionResult, Error>?
    private var progress: (@Sendable (Double) -> Void)?
    var didStart: (() -> Void)?
    private(set) var cancellations = 0
    func convert(input: MediaFile, config: ConversionConfig, progress: @escaping @Sendable (Double) -> Void,
                 encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?) async throws -> ConversionResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            self.continuation = continuation
            self.progress = progress
            lock.unlock()
            didStart?()
        }
    }
    func cancel() { lock.lock(); cancellations += 1; lock.unlock() }
    func emit(_ value: Double) { lock.lock(); let callback = progress; lock.unlock(); callback?(value) }
    func succeed(_ result: ConversionResult) { takeContinuation()?.resume(returning: result) }
    func fail(_ error: Error) { takeContinuation()?.resume(throwing: error) }
    private func takeContinuation() -> CheckedContinuation<ConversionResult, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
