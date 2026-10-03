import Foundation
import zlib

/// Small ZIP reader/writer for document packages and exports. Payloads use
/// streaming deflate. Document reads have an explicit expansion ceiling.
enum FileArchive {
    struct Entry {
        var name: String
        var url: URL
    }

    static func zip(_ entries: [Entry], to output: URL, check: () throws -> Void = {}) throws {
        guard entries.count <= 65_535 else { throw ConversionError.invalidInput("Too many archive entries") }
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? writer.close() }
        var directory = Data()
        for entry in entries {
            try check()
            guard safeName(entry.name), let name = entry.name.data(using: .utf8), name.count <= 65_535 else {
                throw ConversionError.invalidInput("Invalid archive filename")
            }
            let packed = output.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".deflate")
            defer { try? FileManager.default.removeItem(at: packed) }
            let info = try deflateFile(entry.url, to: packed, windowBits: -MAX_WBITS, check: check)
            let stored = entry.name == "mimetype"
            let method: UInt16 = stored ? 0 : 8
            let packedSize = stored ? info.bytes : info.compressed
            let offset = try writer.offset()
            guard info.bytes <= UInt64(UInt32.max), info.compressed <= UInt64(UInt32.max), offset <= UInt64(UInt32.max) else {
                throw ConversionError.invalidInput("ZIP files are limited to 4 GB per entry")
            }
            var header = Data()
            header.le(UInt32(0x04034b50)); header.le(UInt16(20)); header.le(UInt16(0x800)); header.le(method)
            header.le(UInt16(0)); header.le(UInt16(0x21)); header.le(info.crc)
            header.le(UInt32(packedSize)); header.le(UInt32(info.bytes)); header.le(UInt16(name.count)); header.le(UInt16(0))
            header.append(name); try writer.write(contentsOf: header)
            let reader = try FileHandle(forReadingFrom: stored ? entry.url : packed)
            defer { try? reader.close() }
            while let data = try reader.read(upToCount: 256 * 1024), !data.isEmpty {
                try check(); try writer.write(contentsOf: data)
            }
            directory.le(UInt32(0x02014b50)); directory.le(UInt16(20)); directory.le(UInt16(20)); directory.le(UInt16(0x800)); directory.le(method)
            directory.le(UInt16(0)); directory.le(UInt16(0x21)); directory.le(info.crc)
            directory.le(UInt32(packedSize)); directory.le(UInt32(info.bytes)); directory.le(UInt16(name.count))
            directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0)); directory.le(UInt16(0))
            directory.le(UInt32(0)); directory.le(UInt32(offset)); directory.append(name)
        }
        let start = try writer.offset()
        guard start <= UInt64(UInt32.max), directory.count <= 8 * 1024 * 1024 else {
            throw ConversionError.invalidInput("Archive directory is too large")
        }
        try writer.write(contentsOf: directory)
        var end = Data(); end.le(UInt32(0x06054b50)); end.le(UInt16(0)); end.le(UInt16(0))
        end.le(UInt16(entries.count)); end.le(UInt16(entries.count)); end.le(UInt32(directory.count)); end.le(UInt32(start)); end.le(UInt16(0))
        try writer.write(contentsOf: end)
    }

    static func read(_ name: String, from url: URL, limit: Int = 16 * 1024 * 1024) throws -> Data {
        let reader = try FileHandle(forReadingFrom: url)
        defer { try? reader.close() }
        let size = try reader.seekToEnd()
        let tailSize = min(size, 65_557)
        try reader.seek(toOffset: size - tailSize)
        let tail = try reader.readToEnd() ?? Data()
        guard tail.count >= 22,
              let end = stride(from: tail.count - 22, through: 0, by: -1).first(where: { tail.u32($0) == 0x06054b50 && $0 + 22 + Int(tail.u16($0 + 20)) == tail.count }),
              tail.u16(end + 4) == 0, tail.u16(end + 6) == 0,
              tail.u16(end + 8) == tail.u16(end + 10) else { throw invalidArchive() }
        let directorySize = Int(tail.u32(end + 12)), directoryOffset = UInt64(tail.u32(end + 16))
        guard directorySize <= 8 * 1024 * 1024, directoryOffset + UInt64(directorySize) <= size else { throw invalidArchive() }
        try reader.seek(toOffset: directoryOffset)
        let directory = try reader.read(upToCount: directorySize) ?? Data()
        var position = 0
        while position + 46 <= directory.count {
            guard directory.u32(position) == 0x02014b50 else { throw invalidArchive() }
            let nameLength = Int(directory.u16(position + 28)), extra = Int(directory.u16(position + 30)), comment = Int(directory.u16(position + 32))
            let next = position + 46 + nameLength + extra + comment
            guard next <= directory.count else { throw invalidArchive() }
            let filename = String(data: directory.subdata(in: position + 46 ..< position + 46 + nameLength), encoding: .utf8)
            if filename == name {
                let method = directory.u16(position + 10), flags = directory.u16(position + 8)
                let packed = Int(directory.u32(position + 20)), expanded = Int(directory.u32(position + 24))
                let offset = UInt64(directory.u32(position + 42))
                guard flags & 1 == 0, method == 0 || method == 8, expanded <= limit, packed <= limit + 1024 * 1024,
                      offset + 30 <= size else { throw invalidArchive() }
                try reader.seek(toOffset: offset)
                let local = try reader.read(upToCount: 30) ?? Data()
                guard local.count == 30, local.u32(0) == 0x04034b50 else { throw invalidArchive() }
                let payloadOffset = offset + 30 + UInt64(local.u16(26)) + UInt64(local.u16(28))
                guard payloadOffset + UInt64(packed) <= size else { throw invalidArchive() }
                try reader.seek(toOffset: payloadOffset)
                let bytes = try reader.read(upToCount: packed) ?? Data()
                guard bytes.count == packed else { throw invalidArchive() }
                let result = method == 0 ? bytes : try inflate(bytes, limit: limit)
                let crc = result.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
                guard result.count == expanded, UInt32(crc) == directory.u32(position + 16) else { throw invalidArchive() }
                return result
            }
            position = next
        }
        throw ConversionError.invalidInput("Missing \(name) in document")
    }

    @discardableResult static func deflateFile(_ input: URL, to output: URL, windowBits: Int32 = MAX_WBITS + 16,
                                               check: () throws -> Void = {}) throws -> (crc: UInt32, bytes: UInt64, compressed: UInt64) {
        let reader = try FileHandle(forReadingFrom: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let writer = try FileHandle(forWritingTo: output)
        defer { try? reader.close(); try? writer.close() }
        var stream = z_stream()
        guard deflateInit2_(&stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, windowBits, 8, Z_DEFAULT_STRATEGY,
                            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalidArchive() }
        defer { deflateEnd(&stream) }
        var crc: uLong = 0, count: UInt64 = 0
        var buffer = [UInt8](repeating: 0, count: 256 * 1024)
        var ended = false
        while !ended {
            try check()
            let data = try reader.read(upToCount: 256 * 1024) ?? Data()
            let flush = data.isEmpty ? Z_FINISH : Z_NO_FLUSH
            count += UInt64(data.count)
            try data.withUnsafeBytes { inputBytes in
                if !data.isEmpty { crc = crc32(crc, inputBytes.bindMemory(to: Bytef.self).baseAddress, uInt(data.count)) }
                stream.next_in = UnsafeMutablePointer(mutating: inputBytes.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(data.count)
                repeat {
                    try check()
                    let status = buffer.withUnsafeMutableBytes { bytes -> Int32 in
                        stream.next_out = bytes.bindMemory(to: Bytef.self).baseAddress
                        stream.avail_out = uInt(bytes.count)
                        return deflate(&stream, flush)
                    }
                    guard status == Z_OK || status == Z_STREAM_END else { throw invalidArchive() }
                    try writer.write(contentsOf: Data(buffer.prefix(buffer.count - Int(stream.avail_out))))
                    ended = status == Z_STREAM_END
                } while stream.avail_in > 0 || stream.avail_out == 0 || flush == Z_FINISH && !ended
            }
        }
        return (UInt32(crc), count, try writer.offset())
    }

    private static func inflate(_ data: Data, limit: Int) throws -> Data {
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw invalidArchive() }
        defer { inflateEnd(&stream) }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 64 * 1024)
        try data.withUnsafeBytes { bytes in
            stream.next_in = UnsafeMutablePointer(mutating: bytes.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(bytes.count)
            var status: Int32 = Z_OK
            repeat {
                try Task.checkCancellation()
                status = buffer.withUnsafeMutableBytes { output in
                    stream.next_out = output.bindMemory(to: Bytef.self).baseAddress; stream.avail_out = uInt(output.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                guard status == Z_OK || status == Z_STREAM_END else { throw invalidArchive() }
                let used = buffer.count - Int(stream.avail_out)
                guard result.count + used <= limit else { throw invalidArchive() }
                result.append(contentsOf: buffer.prefix(used))
            } while status != Z_STREAM_END
            guard stream.avail_in == 0 else { throw invalidArchive() }
        }
        return result
    }

    private static func safeName(_ name: String) -> Bool {
        !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.split(separator: "/").contains("..")
    }
    private static func invalidArchive() -> ConversionError { .invalidInput("Unreadable, encrypted or oversized document archive") }
}

private extension Data {
    mutating func le<T: FixedWidthInteger>(_ value: T) { var value = value.littleEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } }
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(u16(offset)) | UInt32(u16(offset + 2)) << 16 }
}

final class ArchiveConverter: Converter {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func check() throws { try Task.checkCancellation(); lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw ConversionError.cancelled } }
    func convert(input: MediaFile, config: ConversionConfig, progress: @escaping @Sendable (Double) -> Void,
                 encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?) async throws -> ConversionResult {
        let output = TempStorage.url(for: config.outputFormat)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: output) } }
        progress(0.05)
        encodingStats?(FFmpegEncodingDisplayStats(activity: "Compressing…"))
        if config.outputFormat == .zip {
            try FileArchive.zip([.init(name: input.originalFilename, url: input.url)], to: output, check: check)
        } else if config.outputFormat == .gzip {
            try FileArchive.deflateFile(input.url, to: output, check: check)
        } else { throw ConversionError.unsupportedConversion }
        try check()
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        success = true; progress(1)
        return ConversionResult(url: output, outputFormat: config.outputFormat, sizeOnDisk: size)
    }
}
