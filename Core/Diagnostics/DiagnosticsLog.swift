import Darwin
import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct DiagnosticsLogEntry: Identifiable, Codable, Hashable, Sendable {
    enum Level: String, Codable, Hashable, Sendable {
        case session
        case error
    }

    let id: UUID
    let timestamp: Date
    let level: Level
    let context: String
    let message: String
    let sessionID: String
    let sourceFile: String
    let sourceFunction: String
    let sourceLine: UInt
    let thread: String
    let metadata: [String: String]
    let details: String?
    let callStack: [String]
    let errorType: String?
    let errorDomain: String?
    let errorCode: Int?

    var formattedText: String {
        var lines = [
            "[\(Self.timestamp(timestamp))] [\(level.rawValue.uppercased())] \(context)",
            "Message: \(message)",
            "Session: \(sessionID)",
            "Source: \(sourceFile):\(sourceLine) — \(sourceFunction)",
            "Thread: \(thread)"
        ]

        if let errorType { lines.append("Error type: \(errorType)") }
        if let errorDomain { lines.append("Error domain: \(errorDomain)") }
        if let errorCode { lines.append("Error code: \(errorCode)") }

        if !metadata.isEmpty {
            lines.append("Metadata:")
            for key in metadata.keys.sorted() {
                lines.append("  \(key): \(metadata[key] ?? "")")
            }
        }

        if let details, !details.isEmpty {
            lines.append("Details:")
            lines.append(Self.indented(details))
        }

        if !callStack.isEmpty {
            lines.append("Call stack:")
            lines.append(Self.indented(callStack.joined(separator: "\n")))
        }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func indented(_ value: String) -> String {
        value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
            .joined(separator: "\n")
    }
}

/// Persistent, thread-safe diagnostics with an in-memory copy so a filesystem
/// problem never makes a failure disappear from the current app session.
final class DiagnosticsLog: @unchecked Sendable {
    static let shared = DiagnosticsLog()

    private let lock = NSLock()
    private let fileManager: FileManager
    private let sessionID = UUID().uuidString
    private let maximumLogBytes = 5 * 1_024 * 1_024
    private var logURL: URL
    private var cachedEntries: [DiagnosticsLogEntry]
    private var persistenceIssue: String?

    private init() {
        let fileManager = FileManager.default
        self.fileManager = fileManager

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let primaryDirectory = appSupport.appendingPathComponent("MBConverter/Diagnostics", isDirectory: true)
        let fallbackDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MBConverter/Diagnostics", isDirectory: true)
        let primaryURL = primaryDirectory.appendingPathComponent("events.json", isDirectory: false)
        let fallbackURL = fallbackDirectory.appendingPathComponent("events.json", isDirectory: false)

        var setupIssue: String?
        do {
            try fileManager.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        } catch {
            setupIssue = "Could not create the persistent diagnostics directory: \(error.localizedDescription)"
        }
        try? fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)

        let existingURLs = [primaryURL, fallbackURL].filter { fileManager.fileExists(atPath: $0.path) }
        let newestExistingURL = existingURLs.max { lhs, rhs in
            Self.modificationDate(of: lhs, using: fileManager)
                < Self.modificationDate(of: rhs, using: fileManager)
        }
        let selectedURL = newestExistingURL ?? (setupIssue == nil ? primaryURL : fallbackURL)

        logURL = selectedURL
        persistenceIssue = setupIssue
        if let data = try? Data(contentsOf: selectedURL),
           let decoded = try? JSONDecoder().decode([DiagnosticsLogEntry].self, from: data) {
            cachedEntries = decoded
        } else {
            cachedEntries = []
        }

        let legacyURL = primaryDirectory.appendingPathComponent("error-log.txt", isDirectory: false)
        migrateLegacyLogIfNeeded(from: legacyURL)
    }

    func beginSession() {
        let runtime = FFmpegRuntimeInfo.current
        recordEvent(
            level: .session,
            context: "App launch",
            message: "Started a new app session.",
            metadata: [
                "FFmpeg package": runtime.packageName,
                "FFmpeg version": runtime.ffmpegVersion,
                "FFmpegKit version": runtime.ffmpegKitVersion
            ],
            details: nil,
            error: nil,
            includesCallStack: false,
            file: #fileID,
            function: #function,
            line: #line
        )
    }

    func record(
        error: Error,
        context: String,
        metadata: [String: String] = [:],
        details: String? = nil,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        let combinedDetails = [errorDetails(error), details]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        recordEvent(
            level: .error,
            context: context,
            message: error.localizedDescription,
            metadata: metadata,
            details: combinedDetails,
            error: error,
            includesCallStack: true,
            file: file,
            function: function,
            line: line
        )
    }

    func record(
        message: String,
        context: String,
        metadata: [String: String] = [:],
        details: String? = nil,
        file: StaticString = #fileID,
        function: StaticString = #function,
        line: UInt = #line
    ) {
        recordEvent(
            level: .error,
            context: context,
            message: message,
            metadata: metadata,
            details: details,
            error: nil,
            includesCallStack: true,
            file: file,
            function: function,
            line: line
        )
    }

    func entries() -> [DiagnosticsLogEntry] {
        lock.lock()
        defer { lock.unlock() }
        return cachedEntries.sorted { $0.timestamp > $1.timestamp }
    }

    func report() -> String {
        lock.lock()
        let entries = cachedEntries.sorted { $0.timestamp > $1.timestamp }
        let persistenceIssue = persistenceIssue
        lock.unlock()

        let runtime = FFmpegRuntimeInfo.current
        let processInfo = ProcessInfo.processInfo
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let libraries = runtime.externalLibraries.isEmpty
            ? "none"
            : runtime.externalLibraries.sorted().joined(separator: ", ")
        let persistenceStatus = persistenceIssue ?? "Available on disk and in memory"

        let header = """
        MB Converter Diagnostic Report
        Generated: \(Self.timestamp(Date()))
        App version: \(version) (\(build))
        Bundle identifier: \(bundle.bundleIdentifier ?? "unknown")
        OS: \(processInfo.operatingSystemVersionString)
        Device: \(UIDevice.current.model) (\(Self.hardwareIdentifier()))
        Locale: \(Locale.current.identifier)
        Time zone: \(TimeZone.current.identifier)
        Physical memory: \(ByteCountFormatter.string(fromByteCount: Int64(processInfo.physicalMemory), countStyle: .memory))
        FFmpeg package: \(runtime.packageName)
        FFmpeg version: \(runtime.ffmpegVersion)
        FFmpegKit version: \(runtime.ffmpegKitVersion)
        FFmpeg build date: \(runtime.buildDate)
        FFmpeg external libraries: \(libraries)
        Persistence: \(persistenceStatus)
        Log retention: newest 5 MB
        """

        let body = entries.map(\.formattedText).joined(separator: "\n\n")
        return "\(header)\n\n-------------------- Newest Events First --------------------\n\n"
            + (body.isEmpty ? "No errors have been recorded." : body)
            + "\n"
    }

    private func recordEvent(
        level: DiagnosticsLogEntry.Level,
        context: String,
        message: String,
        metadata: [String: String],
        details: String?,
        error: Error?,
        includesCallStack: Bool,
        file: StaticString,
        function: StaticString,
        line: UInt
    ) {
        let nsError = error.map { $0 as NSError }
        let entry = DiagnosticsLogEntry(
            id: UUID(),
            timestamp: Date(),
            level: level,
            context: context,
            message: message,
            sessionID: sessionID,
            sourceFile: String(describing: file),
            sourceFunction: String(describing: function),
            sourceLine: line,
            thread: Thread.isMainThread ? "main" : "background",
            metadata: metadata.mapValues { Self.limited($0) },
            details: details.map { Self.limited($0, limit: 64 * 1_024) },
            callStack: includesCallStack ? Array(Thread.callStackSymbols.prefix(24)) : [],
            errorType: error.map { String(reflecting: type(of: $0)) },
            errorDomain: nsError?.domain,
            errorCode: nsError?.code
        )

        lock.lock()
        cachedEntries.append(entry)
        persistLocked()
        lock.unlock()
        print("[DIAGNOSTICS] [\(level.rawValue.uppercased())] \(context): \(message)")
    }

    private func persistLocked() {
        guard var data = try? JSONEncoder().encode(cachedEntries) else {
            persistenceIssue = "The diagnostic events could not be encoded. They remain available in memory."
            return
        }

        while data.count > maximumLogBytes, cachedEntries.count > 1 {
            cachedEntries.removeFirst(max(1, cachedEntries.count / 10))
            guard let smallerData = try? JSONEncoder().encode(cachedEntries) else { break }
            data = smallerData
        }

        do {
            try data.write(to: logURL, options: .atomic)
            persistenceIssue = nil
        } catch {
            let primaryFailure = error.localizedDescription
            let fallbackDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("MBConverter/Diagnostics", isDirectory: true)
            let fallbackURL = fallbackDirectory.appendingPathComponent("events.json", isDirectory: false)
            do {
                try fileManager.createDirectory(at: fallbackDirectory, withIntermediateDirectories: true)
                try data.write(to: fallbackURL, options: .atomic)
                logURL = fallbackURL
                persistenceIssue = "Persistent storage failed (\(primaryFailure)); using temporary storage."
            } catch {
                persistenceIssue = "Disk writes failed; current-session events remain available in memory. "
                    + "Primary: \(primaryFailure). Fallback: \(error.localizedDescription)"
            }
        }
    }

    private func migrateLegacyLogIfNeeded(from legacyURL: URL) {
        guard cachedEntries.isEmpty,
              let data = try? Data(contentsOf: legacyURL),
              let text = String(data: data, encoding: .utf8),
              text.contains("[ERROR]")
        else { return }

        let entry = DiagnosticsLogEntry(
            id: UUID(),
            timestamp: Self.modificationDate(of: legacyURL, using: fileManager),
            level: .error,
            context: "Earlier diagnostic events",
            message: "Imported errors recorded before the organized log format was added.",
            sessionID: "legacy",
            sourceFile: "Legacy diagnostics",
            sourceFunction: "Migration",
            sourceLine: 0,
            thread: "unknown",
            metadata: [:],
            details: Self.limited(text, limit: 256 * 1_024),
            callStack: [],
            errorType: nil,
            errorDomain: nil,
            errorCode: nil
        )
        cachedEntries.append(entry)
        persistLocked()
    }

    private func errorDetails(_ error: Error) -> String {
        var sections: [String] = []
        var current: Error? = error
        var depth = 0

        while let currentError = current, depth < 8 {
            let nsError = currentError as NSError
            var lines = [
                "Error \(depth + 1): \(String(reflecting: type(of: currentError)))",
                "Domain: \(nsError.domain)",
                "Code: \(nsError.code)",
                "Localized description: \(nsError.localizedDescription)"
            ]
            if let reason = nsError.localizedFailureReason, !reason.isEmpty {
                lines.append("Failure reason: \(reason)")
            }
            if let suggestion = nsError.localizedRecoverySuggestion, !suggestion.isEmpty {
                lines.append("Recovery suggestion: \(suggestion)")
            }

            let printableUserInfo = nsError.userInfo
                .filter { $0.key != NSUnderlyingErrorKey }
                .map { (String(describing: $0.key), String(reflecting: $0.value)) }
                .sorted { $0.0 < $1.0 }
            if !printableUserInfo.isEmpty {
                lines.append("User info:")
                lines.append(contentsOf: printableUserInfo.map { "  \($0.0): \(Self.limited($0.1))" })
            }

            sections.append(lines.joined(separator: "\n"))
            current = nsError.userInfo[NSUnderlyingErrorKey] as? Error
            depth += 1
        }
        return sections.joined(separator: "\n\nUnderlying error:\n")
    }

    private static func modificationDate(of url: URL, using fileManager: FileManager) -> Date {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date ?? .distantPast
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func hardwareIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func limited(_ value: String, limit: Int = 8 * 1_024) -> String {
        guard value.count > limit else { return value }
        let end = value.index(value.startIndex, offsetBy: limit)
        return String(value[..<end]) + "… [truncated]"
    }
}

struct DiagnosticsLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            text = ""
            return
        }
        text = String(decoding: data, as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
