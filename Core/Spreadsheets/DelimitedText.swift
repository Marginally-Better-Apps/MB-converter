import Foundation

/// RFC 4180 CSV/TSV parsing and writing with delimiter sniffing.
enum DelimitedText {
    static func read(url: URL, delimiter: Character? = nil) throws -> Workbook {
        let text = TextDecoding.decode(try Data(contentsOf: url))
        let resolved = delimiter ?? (url.pathExtension.lowercased() == "tsv" ? "\t" : detectDelimiter(text))
        let rows = parse(text, delimiter: resolved).map { $0.map(CellValue.inferred) }
        let name = url.deletingPathExtension().lastPathComponent
        return Workbook(sheets: [Sheet(name: name.isEmpty ? "Sheet1" : name, rows: rows)])
    }

    static func detectDelimiter(_ text: String) -> Character {
        let sample = text.prefix(8_192)
        let candidates: [Character] = [",", ";", "\t", "|"]
        var best: (Character, Double) = (",", -1)
        let lines = sample.split(separator: "\n", omittingEmptySubsequences: true).prefix(20)
        guard !lines.isEmpty else { return "," }
        for candidate in candidates {
            let counts = lines.map { line in countOutsideQuotes(line, candidate) }
            guard let first = counts.first, first > 0 else { continue }
            // Prefer delimiters that appear consistently on every line.
            let consistent = counts.filter { $0 == first }.count
            let score = Double(consistent) * 10 + Double(first)
            if score > best.1 { best = (candidate, score) }
        }
        return best.0
    }

    private static func countOutsideQuotes(_ line: Substring, _ delimiter: Character) -> Int {
        var count = 0
        var quoted = false
        for ch in line {
            if ch == "\"" { quoted.toggle() } else if ch == delimiter, !quoted { count += 1 }
        }
        return count
    }

    static func parse(_ text: String, delimiter: Character = ",") -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var fieldStarted = false
        var iterator = text.makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let ch = nextChar() {
            if quoted {
                if ch == "\"" {
                    if let next = nextChar() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            quoted = false
                            pending = next
                        }
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(ch)
                }
                continue
            }
            switch ch {
            case "\"" where !fieldStarted || field.isEmpty:
                quoted = true
                fieldStarted = true
            case delimiter:
                row.append(field)
                field = ""
                fieldStarted = false
            case "\r\n", "\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
                fieldStarted = false
            default:
                field.append(ch)
                fieldStarted = true
            }
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        // Strip a UTF-8 BOM that survived decoding.
        if let first = rows.first?.first, first.hasPrefix("\u{FEFF}") {
            rows[0][0] = String(first.dropFirst())
        }
        return rows
    }

    static func render(_ sheet: Sheet, delimiter: Character = ",", lineEnding: String = "\r\n") -> String {
        sheet.normalizedRows.map { row in
            row.map { escape($0.text, delimiter: delimiter) }.joined(separator: String(delimiter))
        }.joined(separator: lineEnding) + (sheet.normalizedRows.isEmpty ? "" : lineEnding)
    }

    static func escape(_ value: String, delimiter: Character) -> String {
        let needsQuotes = value.contains(delimiter) || value.contains("\"") || value.contains("\n") || value.contains("\r")
            || value.hasPrefix(" ") || value.hasSuffix(" ")
        guard needsQuotes else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Splits one sheet into chunks of `rowsPerFile` data rows, repeating the header row.
    static func split(_ sheet: Sheet, rowsPerFile: Int, repeatHeader: Bool) -> [Sheet] {
        let rows = sheet.normalizedRows
        guard rowsPerFile > 0, !rows.isEmpty else { return [sheet] }
        let header = repeatHeader ? rows.first : nil
        let body = repeatHeader ? Array(rows.dropFirst()) : rows
        guard !body.isEmpty else { return [sheet] }
        return stride(from: 0, to: body.count, by: rowsPerFile).enumerated().map { index, start in
            let chunk = Array(body[start ..< min(start + rowsPerFile, body.count)])
            return Sheet(name: "\(sheet.name)-\(index + 1)", rows: (header.map { [$0] } ?? []) + chunk)
        }
    }
}
