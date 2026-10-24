#if DEBUG
import Foundation
import UIKit

/// Debug-only deep links for screenshots and manual QA:
///   -MBRoute tab:convert|tools|history | category:pdf | tool:pdf.merge | hub | result:pdf.compress
///   -MBInputs /path/one.pdf,/path/two.pdf   (host paths are readable from the simulator)
///   -MBEditor 1                              (auto-open the tool's editor)
///   -MBThen tab:history                      (after a result: switch tabs, e.g. to check History)
///   -MBResetState 1                          (start with empty saved history; UI tests)
///   -MBSavedHistory 1|0                      (turn saved history on or off before launch)
///   -MBNoAnimations 1                        (faster, steadier UI tests)
enum DebugLaunchRouter {
    static var arguments: [String: String] {
        let args = ProcessInfo.processInfo.arguments
        var result: [String: String] = [:]
        for (index, arg) in args.enumerated() where arg.hasPrefix("-MB") && index + 1 < args.count {
            result[String(arg.dropFirst())] = args[index + 1]
        }
        return result
    }

    static var opensEditor: Bool { arguments["MBEditor"] == "1" }

    /// Runs before any store is created, so tests start from a known state.
    static func prepareState() {
        let args = arguments
        if args["MBResetState"] == "1" {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            try? FileManager.default.removeItem(at: support.appendingPathComponent("MBConverter/ConversionHistory", isDirectory: true))
        }
        if let saved = args["MBSavedHistory"] { ConversionHistoryUserDefaults.isEnabled = saved == "1" }
        if args["MBNoAnimations"] == "1" { UIView.setAnimationsEnabled(false) }
    }

    static func inputs() -> [ToolInputFile] {
        (arguments["MBInputs"] ?? "").split(separator: ",").compactMap { path in
            try? FileIntake.importFile(at: URL(fileURLWithPath: String(path)))
        }
    }

    @MainActor
    static func apply(selectTab: @escaping (RootSection) -> Void, push: @escaping (AppRoute) -> Void) {
        guard let route = arguments["MBRoute"] else { return }
        let parts = route.split(separator: ":", maxSplits: 1).map(String.init)
        let value = parts.count > 1 ? parts[1] : ""
        switch parts[0] {
        case "tab":
            selectTab(RootSection(rawValue: value) ?? .convert)
        case "category":
            if let category = ToolCategory(rawValue: value) { push(.category(category)) }
        case "tool":
            push(.tool(ToolID(rawValue: value), inputs: inputs()))
        case "media":
            guard let path = arguments["MBInputs"] else { return }
            Task {
                if let media = try? await ImportService().validatedMediaFile(at: URL(fileURLWithPath: path)) {
                    push(.inputDetail(media))
                }
            }
        case "hub":
            if let file = inputs().first { push(.fileHub(file)) }
        case "result":
            guard let tool = ToolCatalog.tool(ToolID(rawValue: value)) else { return }
            // Same path as tapping the tool's action button, including History.
            let model = ToolViewModel(tool: tool, inputs: inputs())
            Task {
                if let run = await model.run() {
                    push(.toolResult(run))
                    if let then = arguments["MBThen"], then.hasPrefix("tab:") {
                        try? await Task.sleep(for: .seconds(1.5))
                        selectTab(RootSection(rawValue: String(then.dropFirst(4))) ?? .history)
                    }
                }
            }
        default:
            break
        }
    }
}
#endif
