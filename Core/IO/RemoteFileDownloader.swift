import Foundation

struct RemoteDownloadProgress: Equatable {
    let bytesReceived: Int64
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(Double(bytesReceived) / Double(totalBytes), 1)
    }

    /// Value for a determinate `ProgressView` when the server omits a total size: monotonic in `bytesReceived`, capped so completion can set the bar near full in the last update.
    var displayFraction: Double {
        if let t = totalBytes, t > 0 {
            return min(1, Double(bytesReceived) / Double(t))
        }
        // No Content-Length (chunked, etc.): show a monotonic 0...<1 curve vs the import cap so the bar still advances.
        let b = max(0, Double(bytesReceived))
        let cap = Double(RemoteFileDownloader.maxBytes)
        guard cap > 0 else { return 0 }
        return min(0.99, log(1 + b) / log(1 + cap))
    }
}

/// Streams remote imports to disk. HTTP success and filename extensions alone do
/// not establish that a response contains media; inspection follows the download.
struct RemoteFileDownloader {
    static let maxBytes: Int64 = 150 * 1024 * 1024
    var session: URLSession = .shared

    func download(
        _ string: String,
        progress: ((RemoteDownloadProgress) async -> Void)? = nil
    ) async throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = Self.normalizedRemoteURL(from: trimmed),
              let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
            throw ImportError.invalidRemoteURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw ImportError.networkFailed(error.localizedDescription)
        }
        // Header validation can fail before the stream is consumed.
        defer { bytes.task.cancel() }
        try Task.checkCancellation()

        guard let http = response as? HTTPURLResponse else {
            throw ImportError.networkFailed("Not an HTTP response.")
        }
        guard (200 ... 299).contains(http.statusCode) else {
            throw ImportError.networkFailed("Server returned status \(http.statusCode).")
        }
        // No Range was requested: a partial response must not become an input file.
        guard http.statusCode != 206, http.value(forHTTPHeaderField: "Content-Range") == nil else {
            throw ImportError.networkFailed("The server returned only part of the file. Try a direct download link.")
        }
        if let mime = http.mimeType?.lowercased(),
           mime.hasPrefix("text/") || mime == "application/xhtml+xml"
            || mime == "application/json" || mime.hasSuffix("+json")
            || mime == "application/xml" || mime.hasSuffix("+xml") {
            throw ImportError.remoteResponseNotMedia
        }

        let declaredContentLength = Self.declaredContentLength(from: http)
        if let declared = declaredContentLength, declared > Self.maxBytes {
            throw ImportError.fileTooLarge(limitBytes: Self.maxBytes)
        }
        guard let ext = Self.inferredFileExtension(remoteURL: url, response: http) else {
            throw ImportError.couldNotDetermineRemoteFileType
        }

        let outputURL = ImportStorage.url(originalName: "download.\(ext)", fallbackExtension: ext)
        var completed = false
        defer {
            if !completed { try? FileManager.default.removeItem(at: outputURL) }
        }
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw ImportError.copyFailed("Could not create a temporary file.")
        }
        let handle: FileHandle
        do {
            handle = try FileHandle(forWritingTo: outputURL)
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        defer { try? handle.close() }

        func reportProgress(_ byteCount: Int64) async {
            await progress?(RemoteDownloadProgress(bytesReceived: byteCount, totalBytes: declaredContentLength))
        }
        await reportProgress(0)

        var total: Int64 = 0
        let chunkCapacity = 256 * 1024
        var scratch = [UInt8](repeating: 0, count: chunkCapacity)
        var scratchCount = 0
        do {
            for try await byte in bytes {
                scratch[scratchCount] = byte
                scratchCount += 1
                total += 1
                if total > Self.maxBytes {
                    throw ImportError.fileTooLarge(limitBytes: Self.maxBytes)
                }
                if scratchCount == chunkCapacity {
                    try Task.checkCancellation()
                    try handle.write(contentsOf: scratch)
                    scratchCount = 0
                    await reportProgress(total)
                }
            }
            try Task.checkCancellation()
            guard total > 0 else {
                throw ImportError.networkFailed("The server returned an empty file.")
            }
            if let declaredContentLength, total != declaredContentLength {
                throw ImportError.networkFailed("The download is incomplete. Please try again.")
            }
            if scratchCount > 0 {
                try handle.write(contentsOf: scratch[0 ..< scratchCount])
            }
            try handle.close()
        } catch let error as ImportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ImportError.networkFailed(error.localizedDescription)
        }

        await progress?(RemoteDownloadProgress(bytesReceived: total, totalBytes: declaredContentLength ?? total))
        try Task.checkCancellation()
        completed = true
        return outputURL
    }

    private static let mimeToExtension: [String: String] = [
        "video/mp4": "mp4",
        "video/x-m4v": "m4v",
        "video/quicktime": "mov",
        "video/webm": "webm",
        "video/x-matroska": "mkv",
        "video/ogg": "ogv",
        "video/3gpp": "3gp",
        "video/mpeg": "mpeg",
        "video/x-msvideo": "avi",
        "video/x-flv": "flv",
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/aac": "aac",
        "audio/flac": "flac",
        "audio/ogg": "ogg",
        "audio/opus": "opus",
        "image/jpeg": "jpg",
        "image/png": "png",
        "image/gif": "gif",
        "image/webp": "webp",
        "image/heic": "heic",
        "image/heif": "heic",
        "image/tiff": "tiff",
        "image/avif": "avif"
    ]

    private static func declaredContentLength(from response: HTTPURLResponse) -> Int64? {
        // URLSession transparently decodes compressed bodies. Their wire length
        // cannot be compared to the decoded byte count or used as progress total.
        if let encoding = response.value(forHTTPHeaderField: "Content-Encoding"),
           encoding.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != "identity" {
            return nil
        }
        if response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        if let lengthHeader = response.value(forHTTPHeaderField: "Content-Length") {
            let firstToken = lengthHeader
                .split(separator: ",")
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? lengthHeader.trimmingCharacters(in: .whitespacesAndNewlines)
            if let declared = Int64(firstToken), declared > 0 {
                return declared
            }
        }
        return nil
    }

    private static func normalizedRemoteURL(from string: String) -> URL? {
        if let u = URL(string: string), u.scheme != nil { return u }
        if let u = URL(string: "https://\(string)"), u.host != nil { return u }
        return nil
    }

    private static func inferredFileExtension(remoteURL: URL, response: HTTPURLResponse) -> String? {
        var candidates: [String] = []
        if let cd = response.value(forHTTPHeaderField: "Content-Disposition"),
           let name = filenameFromContentDisposition(cd) {
            candidates.append(URL(fileURLWithPath: name).pathExtension)
        }
        if let finalURL = response.url { candidates.append(finalURL.pathExtension) }
        candidates.append(remoteURL.pathExtension)
        if let mime = response.mimeType?.lowercased(), let ext = mimeToExtension[mime] {
            candidates.append(ext)
        }
        return candidates.map { $0.lowercased() }.first {
            !$0.isEmpty && FormatMatrix.detectCategory(from: URL(fileURLWithPath: "download.\($0)")) != nil
        }
    }

    private static func filenameFromContentDisposition(_ value: String) -> String? {
        let segments = value.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        for segment in segments where segment.lowercased().hasPrefix("filename*=") {
            var rest = String(segment.dropFirst("filename*=".count)).trimmingCharacters(in: .whitespaces)
            if let sep = rest.range(of: "''", options: .literal) {
                rest = String(rest[sep.upperBound...])
            }
            let token = rest.split(separator: ";").first.map(String.init) ?? rest
            let decoded = token.removingPercentEncoding ?? token
            if !decoded.isEmpty { return decoded }
        }
        for segment in segments where segment.lowercased().hasPrefix("filename=") {
            var name = String(segment.dropFirst("filename=".count)).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                name = String(name.dropFirst().dropLast())
            } else {
                name = String(name.split(separator: ";").first ?? Substring(name))
            }
            if !name.isEmpty { return name }
        }
        return nil
    }

}
