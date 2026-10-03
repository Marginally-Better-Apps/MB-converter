import Foundation

final class DataConverter: Converter {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    private func check() throws { try Task.checkCancellation(); lock.lock(); let stopped = cancelled; lock.unlock(); if stopped { throw ConversionError.cancelled } }

    func convert(input: MediaFile, config: ConversionConfig, progress: @escaping @Sendable (Double) -> Void,
                 encodingStats: (@Sendable (FFmpegEncodingDisplayStats) -> Void)?) async throws -> ConversionResult {
        try check()
        guard input.sizeOnDisk <= 16 * 1024 * 1024 else { throw ConversionError.invalidInput("Data files are limited to 16 MB") }
        let bytes = try Data(contentsOf: input.url)
        var rows: [[String]]
        if input.containerFormat == "json" {
            guard let objects = try JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] else {
                throw ConversionError.invalidInput("Use a JSON array of objects")
            }
            let headers = Set(objects.flatMap { $0.keys }).sorted()
            guard !headers.isEmpty else { throw ConversionError.invalidInput("No columns found") }
            guard objects.count <= 100_000, headers.count <= 512, objects.count * headers.count <= 500_000 else {
                throw ConversionError.invalidInput("Too many rows or columns")
            }
            rows = [headers] + (try objects.map { object in
                try headers.map { key in
                    guard let value = object[key], !(value is NSNull) else { return "" }
                    if let string = value as? String { return string }
                    if let number = value as? NSNumber { return CFGetTypeID(number) == CFBooleanGetTypeID() ? (number.boolValue ? "true" : "false") : number.stringValue }
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
                    return String(decoding: data, as: UTF8.self)
                }
            })
        } else {
            guard let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) else { throw ConversionError.invalidInput("Use UTF-8 or UTF-16 data") }
            rows = try Self.parse(text, delimiter: input.containerFormat == "tsv" ? "\t" : ",")
        }
        try check(); progress(0.45)
        let output = TempStorage.url(for: config.outputFormat)
        var success = false; defer { if !success { try? FileManager.default.removeItem(at: output) } }
        switch config.outputFormat {
        case .json:
            guard let headers = rows.first, !headers.isEmpty, Set(headers).count == headers.count, !headers.contains("") else {
                throw ConversionError.invalidInput("JSON export requires unique, nonempty column names")
            }
            // Long column names repeat in every JSON object; bound expansion
            // before Foundation allocates dictionaries or the serialized buffer.
            let limit = 64 * 1024 * 1024
            let repeated = headers.reduce(0) { $0 + Self.jsonStringBytes($1) + 16 }
            var estimated = 4 + (repeated + 16) * (rows.count - 1)
            guard estimated <= limit else { throw ConversionError.invalidInput("JSON output would exceed 64 MB; split this data file") }
            for row in rows.dropFirst() {
                guard row.count == headers.count else { throw ConversionError.invalidInput("Rows have different column counts") }
                for value in row {
                    estimated += Self.jsonStringBytes(value)
                    guard estimated <= limit else { throw ConversionError.invalidInput("JSON output would exceed 64 MB; split this data file") }
                }
                try check()
            }
            let objects = try rows.dropFirst().map { row -> [String: String] in
                guard row.count == headers.count else { throw ConversionError.invalidInput("Rows have different column counts") }
                return Dictionary(uniqueKeysWithValues: zip(headers, row))
            }
            try JSONSerialization.data(withJSONObject: objects, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        case .csv, .tsv, .txt:
            let delimiter: Character = config.outputFormat == .csv ? "," : "\t"
            let text = rows.map { row in row.map { Self.quote($0, delimiter: delimiter) }.joined(separator: String(delimiter)) }.joined(separator: "\r\n") + "\r\n"
            try Data(text.utf8).write(to: output, options: .atomic)
        case .pdf:
            let text = rows.map { $0.joined(separator: "    ") }.joined(separator: "\n")
            try DocumentConverter().writeText(NSAttributedString(string: text), format: .pdf, to: output)
        default: throw ConversionError.unsupportedConversion
        }
        try check(); success = true; progress(1)
        let size = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ConversionResult(url: output, outputFormat: config.outputFormat, sizeOnDisk: size)
    }

    static func parse(_ text: String, delimiter: Character) throws -> [[String]] {
        let text = text.hasPrefix("\u{feff}") ? String(text.dropFirst()) : text
        let bytes = Array(text.utf8), separator = String(delimiter).utf8.first!
        var rows: [[String]] = [], row: [String] = [], field: [UInt8] = []
        var quoted = false, afterQuote = false, endedRow = false, cells = 0
        func finishField() throws {
            row.append(String(decoding: field, as: UTF8.self)); field.removeAll(keepingCapacity: true)
            cells += 1
            guard row.count <= 512, cells <= 500_000 else { throw ConversionError.invalidInput("Too many data columns") }
        }
        var index = 0
        while index < bytes.count {
            if index % 4096 == 0 { try Task.checkCancellation() }
            let c = bytes[index]
            if quoted {
                if c == 34 {
                    if index + 1 < bytes.count && bytes[index + 1] == 34 { field.append(34); index += 1 }
                    else { quoted = false; afterQuote = true }
                } else { field.append(c) }
            } else if c == separator {
                try finishField(); afterQuote = false; endedRow = false
            } else if c == 10 || c == 13 {
                try finishField(); rows.append(row); row = []; afterQuote = false; endedRow = true
                guard rows.count <= 100_000 else { throw ConversionError.invalidInput("Too many data rows") }
                if c == 13, index + 1 < bytes.count, bytes[index + 1] == 10 { index += 1 }
            } else if c == 34 && field.isEmpty && !afterQuote { quoted = true; endedRow = false }
            else {
                guard !afterQuote else { throw ConversionError.invalidInput("Unexpected character after quoted field") }
                field.append(c); endedRow = false
            }
            guard field.count <= 4 * 1024 * 1024 else { throw ConversionError.invalidInput("Data cell is too large") }
            index += 1
        }
        guard !quoted else { throw ConversionError.invalidInput("Unclosed quoted field") }
        if !endedRow && (!field.isEmpty || !row.isEmpty || afterQuote) { try finishField(); rows.append(row) }
        guard !rows.isEmpty else { throw ConversionError.invalidInput("Empty data file") }
        return rows
    }
    private static func jsonStringBytes(_ string: String) -> Int {
        string.unicodeScalars.reduce(2) { count, scalar in
            let value = scalar.value
            if value < 32 || value == 0x2028 || value == 0x2029 { return count + 6 }
            if value == 34 || value == 92 || value == 47 { return count + 2 }
            return count + (value <= 0x7f ? 1 : value <= 0x7ff ? 2 : value <= 0xffff ? 3 : 4)
        }
    }
    private static func quote(_ value: String, delimiter: Character) -> String {
        if value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
