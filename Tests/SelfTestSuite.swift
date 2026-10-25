import Foundation
import Testing
@testable import Converter

/// Runs the in-app self-test catalog (Settings → Diagnostics → Self-Test) in CI, case by case,
/// so the checks people run on their phones are the checks that gate every pull request.
@Suite(.serialized, .timeLimit(.minutes(5)))
@MainActor
struct SelfTestSuite {
    static let toolIDs = SelfTestPlan.tools.map { "tool.\($0.id.rawValue)" }
    static let checkIDs = SelfTestCatalog.checkIDs

    @Test(arguments: toolIDs)
    func tool(_ id: String) async throws {
        try await expectPass(id)
    }

    @Test(arguments: checkIDs)
    func check(_ id: String) async throws {
        try await expectPass(id)
    }

    @Test func catalogCoversEveryTool() {
        let covered = Set(SelfTestCatalog.toolCases.map(\.id))
        let missing = ToolCatalog.all
            .filter { !$0.opensMediaConverter && !SelfTestPlan.networkTools.contains($0.id.rawValue) }
            .map { "tool.\($0.id.rawValue)" }
            .filter { !covered.contains($0) }
        #expect(missing.isEmpty, "Tools without a self-test case: \(missing)")
    }

    private func expectPass(_ id: String) async throws {
        let runner = SelfTestRunner()
        let testCase = try #require(runner.cases.first { $0.id == id }, "No self-test case \(id)")
        let result = await runner.run(testCase)
        switch result.status {
        case .passed:
            break
        case .skipped(let reason):
            // Only hardware the simulator lacks may be skipped, and only on the simulator.
            #expect(SelfTestRunner.isSimulator, "\(id) skipped on a device: \(reason)")
        case .failed(let problems):
            Issue.record("\(testCase.title) failed:\n\(problems.joined(separator: "\n"))")
        case .pending, .running:
            Issue.record("\(id) never finished")
        }
    }
}
