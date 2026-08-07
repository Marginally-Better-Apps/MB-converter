import ExpoModulesCore
import Foundation

#if canImport(ffmpegkit)
@preconcurrency import ffmpegkit
#endif

public class FFmpegModule: Module {
  private let sessionLock = NSLock()
  private var activeSessionIds = Set<Int>()

  public func definition() -> ModuleDefinition {
    Name("FFmpegModule")

    Events("onProgress", "onLog")

    AsyncFunction("execute") { (command: Either<String, [String]>) -> [String: Any] in
      #if canImport(ffmpegkit)
      let commandString: String
      if let single: String = command.get() {
        commandString = single
      } else if let parts: [String] = command.get() {
        commandString = parts.joined(separator: " ")
      } else {
        throw Exception(name: "InvalidCommand", description: "execute() expects a string or string array")
      }

      return try await self.executeCommand(commandString)
      #else
      throw Exception(name: "FFmpegUnavailable", description: "FFmpegKit is not linked. Run ./scripts/download-ffmpeg-frameworks.sh and rebuild the Dev Client.")
      #endif
    }

    AsyncFunction("cancel") { (sessionId: String?) -> Bool in
      #if canImport(ffmpegkit)
      if let sessionId, let id = Int(sessionId) {
        FFmpegKit.cancel(id)
        self.sessionLock.lock()
        self.activeSessionIds.remove(id)
        self.sessionLock.unlock()
        return true
      }
      FFmpegKit.cancel()
      self.sessionLock.lock()
      self.activeSessionIds.removeAll()
      self.sessionLock.unlock()
      return true
      #else
      return false
      #endif
    }

    AsyncFunction("probe") { (path: String, timeoutMs: Int?) -> [String: Any] in
      #if canImport(ffmpegkit)
      let timeout = Int32(timeoutMs ?? 15_000)
      guard let session = FFprobeKit.getMediaInformation(path, withTimeout: timeout),
            let info = session.getMediaInformation() else {
        throw Exception(name: "ProbeFailed", description: "FFprobe could not read media information for path: \(path)")
      }

      if let properties = info.getAllProperties() as? [String: Any] {
        return Self.sanitizeJSON(properties)
      }

      var fallback: [String: Any] = [:]
      if let format = info.getFormat() { fallback["format"] = format }
      if let duration = info.getDuration() { fallback["duration"] = duration }
      if let bitrate = info.getBitrate() { fallback["bitrate"] = bitrate }
      if let filename = info.getFilename() { fallback["filename"] = filename }
      return fallback
      #else
      throw Exception(name: "FFmpegUnavailable", description: "FFmpegKit is not linked.")
      #endif
    }

    Function("getRuntimeInfo") { () -> [String: Any] in
      #if canImport(ffmpegkit)
      let libraries = (Packages.getExternalLibraries() as? [String]) ?? []
      return [
        "packageName": Packages.getPackageName() ?? "unknown",
        "ffmpegVersion": FFmpegKitConfig.getFFmpegVersion() ?? "unknown",
        "ffmpegKitVersion": FFmpegKitConfig.getVersion() ?? "unknown",
        "buildDate": FFmpegKitConfig.getBuildDate() ?? "unknown",
        "externalLibraries": libraries,
        "releaseTag": "min.v5.1.2.6",
        "vendor": "tylerjonesio/ffmpeg-kit-spm",
      ]
      #else
      return [
        "packageName": "unlinked",
        "ffmpegVersion": "unavailable",
        "ffmpegKitVersion": "unavailable",
        "buildDate": "unavailable",
        "externalLibraries": [] as [String],
        "releaseTag": "min.v5.1.2.6",
        "vendor": "tylerjonesio/ffmpeg-kit-spm",
      ]
      #endif
    }
  }

  #if canImport(ffmpegkit)
  private func executeCommand(_ command: String) async throws -> [String: Any] {
    try await withCheckedThrowingContinuation { continuation in
      let guardBox = ResumeOnce(continuation)
      let started = FFmpegKit.executeAsync(
        command,
        withCompleteCallback: { [weak self] session in
          let sessionId = Self.sessionIdentifier(session)
          self?.sessionLock.lock()
          self?.activeSessionIds.remove(sessionId)
          self?.sessionLock.unlock()

          let returnCodeValue: Int
          if let code = session?.getReturnCode() {
            returnCodeValue = Int(code.getValue())
          } else {
            returnCodeValue = -1
          }

          guardBox.resume(returning: [
            "sessionId": String(sessionId),
            "returnCode": returnCodeValue,
          ])
        },
        withLogCallback: { [weak self] log in
          guard let log, let message = log.getMessage() else { return }
          self?.sendEvent("onLog", [
            "message": message,
            "level": Int(log.getLevel()),
            "sessionId": String(log.getSessionId()),
          ])
        },
        withStatisticsCallback: { [weak self] statistics in
          guard let statistics else { return }
          self?.sendEvent("onProgress", [
            "sessionId": String(statistics.getSessionId()),
            "timeMilliseconds": Int(statistics.getTime()),
            "videoFrameNumber": Int(statistics.getVideoFrameNumber()),
            "videoFps": Double(statistics.getVideoFps()),
            "size": Int(statistics.getSize()),
            "bitrate": Double(statistics.getBitrate()),
            "speed": Double(statistics.getSpeed()),
          ])
        }
      )

      if let started {
        let id = Self.sessionIdentifier(started)
        self.sessionLock.lock()
        self.activeSessionIds.insert(id)
        self.sessionLock.unlock()
      } else {
        guardBox.resume(throwing: Exception(name: "ExecuteFailed", description: "FFmpegKit.executeAsync returned nil session"))
      }
    }
  }

  private static func sessionIdentifier(_ session: FFmpegSession?) -> Int {
    guard let session else { return 0 }
    // ObjC -getSessionId is imported as getId() on Session in Swift.
    return Int((session as Session).getId())
  }

  private static func sanitizeJSON(_ value: Any) -> [String: Any] {
    var result: [String: Any] = [:]
    guard let dict = value as? [String: Any] else { return result }
    for (key, raw) in dict {
      if JSONSerialization.isValidJSONObject([key: raw]) {
        result[key] = raw
      } else if let nested = raw as? [String: Any] {
        result[key] = sanitizeJSON(nested)
      } else if let array = raw as? [Any] {
        result[key] = array.map { item -> Any in
          if let nested = item as? [String: Any] {
            return sanitizeJSON(nested)
          }
          return "\(item)"
        }
      } else {
        result[key] = "\(raw)"
      }
    }
    return result
  }
  #endif
}

private final class ResumeOnce<T> {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<T, Error>?

  init(_ continuation: CheckedContinuation<T, Error>) {
    self.continuation = continuation
  }

  func resume(returning value: T) {
    lock.lock()
    defer { lock.unlock() }
    continuation?.resume(returning: value)
    continuation = nil
  }

  func resume(throwing error: Error) {
    lock.lock()
    defer { lock.unlock() }
    continuation?.resume(throwing: error)
    continuation = nil
  }
}
