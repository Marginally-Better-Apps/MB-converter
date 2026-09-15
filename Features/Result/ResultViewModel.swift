import Foundation
import Observation
import UIKit

struct ResultSizeComparison: Hashable {
    enum Direction: Hashable {
        case smaller
        case larger
        case unchanged
        case unavailable
    }

    let before: String
    let after: String
    let change: String
    let direction: Direction
}

@MainActor
@Observable
final class ResultViewModel {
    let input: MediaFile
    let config: ConversionConfig
    let result: ConversionResult
    var errorMessage: String?
    var isCopyingToPasteboard = false
    var didCopyToPasteboard = false
    var editableBaseName: String

    init(input: MediaFile, config: ConversionConfig, result: ConversionResult) {
        self.input = input
        self.config = config
        self.result = result
        self.editableBaseName = ResultViewModel.defaultBaseName(input: input, result: result)
    }

    var sizeComparison: ResultSizeComparison {
        let before = MetadataFormatter.bytes(input.sizeOnDisk)
        let after = MetadataFormatter.bytes(result.sizeOnDisk)

        guard input.sizeOnDisk > 0 else {
            return ResultSizeComparison(
                before: before,
                after: after,
                change: "Not available",
                direction: .unavailable
            )
        }

        let change = 1 - (Double(result.sizeOnDisk) / Double(input.sizeOnDisk))
        let percentage = Int(abs(change) * 100)

        if change > 0 {
            return ResultSizeComparison(
                before: before,
                after: after,
                change: percentage == 0 ? "Less than 1% smaller" : "\(percentage)% smaller",
                direction: .smaller
            )
        }

        if change < 0 {
            return ResultSizeComparison(
                before: before,
                after: after,
                change: percentage == 0 ? "Less than 1% larger" : "\(percentage)% larger",
                direction: .larger
            )
        }

        return ResultSizeComparison(
            before: before,
            after: after,
            change: "No change",
            direction: .unchanged
        )
    }

    var canCopyToPasteboard: Bool {
        result.outputFormat.supportsClipboardCopy
    }

    var exportFilename: String {
        "\(sanitizedBaseName(from: editableBaseName)).\(result.outputFormat.fileExtension)"
    }

    func applyFilenameEdit(_ proposedName: String) {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let withoutExtension = URL(fileURLWithPath: trimmed).deletingPathExtension().lastPathComponent
        editableBaseName = withoutExtension.isEmpty ? sanitizedBaseName(from: trimmed) : withoutExtension
    }

    func prepareShareFileURL() throws -> URL {
        try ShareFileStaging.stage(sourceURL: result.url, filename: exportFilename)
    }

    func copyToPasteboard() async {
        guard result.outputFormat.supportsClipboardCopy else { return }
        isCopyingToPasteboard = true
        defer { isCopyingToPasteboard = false }

        let outputFileSize = await Task.detached(priority: .userInitiated) { [url = result.url] in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value
        }.value

        guard let outputFileSize, outputFileSize > 0 else {
            errorMessage = "Couldn't copy the file to the clipboard."
            DiagnosticsLog.shared.record(
                message: "The converted output is missing or empty.",
                context: "Copy converted file to clipboard",
                metadata: diagnosticMetadata
            )
            Haptics.error()
            return
        }

        let filename = exportFilename
        let stagedURL: URL
        do {
            stagedURL = try PasteboardFileStaging.stage(sourceURL: result.url, filename: filename)
        } catch {
            errorMessage = "Couldn't prepare the file for clipboard copy."
            DiagnosticsLog.shared.record(
                error: error,
                context: "Stage converted file for clipboard",
                metadata: diagnosticMetadata
            )
            Haptics.error()
            return
        }

        UIPasteboard.general.setItemProviders(
            [pasteboardItemProvider(stagedURL: stagedURL, filename: filename)],
            localOnly: false,
            expirationDate: nil
        )
        didCopyToPasteboard = true
        Haptics.success()
    }

    private func sanitizedBaseName(from proposedName: String) -> String {
        let filtered = proposedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        return filtered.isEmpty ? "converted" : filtered
    }

    private static func defaultBaseName(input: MediaFile, result: ConversionResult) -> String {
        let fallbackBaseName = result.url.deletingPathExtension().lastPathComponent
        let originalBaseName = input.originalFilename.isEmpty
            ? fallbackBaseName
            : URL(fileURLWithPath: input.originalFilename).deletingPathExtension().lastPathComponent
        return originalBaseName.isEmpty ? "converted" : originalBaseName
    }

    private func pasteboardItemProvider(stagedURL: URL, filename: String) -> NSItemProvider {
        let provider = NSItemProvider()
        let diagnosticMetadata = diagnosticMetadata
        provider.suggestedName = filename
        provider.registerObject(stagedURL as NSURL, visibility: .all)
        provider.registerFileRepresentation(
            forTypeIdentifier: result.outputFormat.pasteboardTypeIdentifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            do {
                let loadURL = try PasteboardFileStaging.makeLoadCopy(from: stagedURL, filename: filename)
                completion(loadURL, false, nil)
            } catch {
                DiagnosticsLog.shared.record(
                    error: error,
                    context: "Provide converted file to clipboard",
                    metadata: diagnosticMetadata
                )
                completion(nil, false, error)
            }
            return nil
        }
        return provider
    }

    private var diagnosticMetadata: [String: String] {
        [
            "Export filename": exportFilename,
            "Output format": result.outputFormat.displayName,
            "Output bytes": String(result.sizeOnDisk),
            "Output exists": String(FileManager.default.fileExists(atPath: result.url.path))
        ]
    }
}

private enum ShareFileStaging {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("share", isDirectory: true)
    }

    static func stage(sourceURL: URL, filename: String) throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        let destinationDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }
}

private enum PasteboardFileStaging {
    private static var directory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pasteboard", isDirectory: true)
    }

    static func stage(sourceURL: URL, filename: String) throws -> URL {
        try? FileManager.default.removeItem(at: directory)
        let destinationDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destinationURL = destinationDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        return destinationURL
    }

    static func makeLoadCopy(from stagedURL: URL, filename: String) throws -> URL {
        let loadDirectory = directory
            .appendingPathComponent("loads", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: loadDirectory, withIntermediateDirectories: true)
        let loadURL = loadDirectory.appendingPathComponent(filename)
        try FileManager.default.copyItem(at: stagedURL, to: loadURL)
        return loadURL
    }
}
