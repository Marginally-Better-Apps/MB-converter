import Foundation

/// Parses human page selections like "1-3, 5, 8-" (1-based, inclusive) into zero-based indices.
enum PageRangeParser {
    enum ParseError: LocalizedError, Equatable {
        case empty
        case invalid(String)
        case outOfBounds(Int, pageCount: Int)

        var errorDescription: String? {
            switch self {
            case .empty: "Enter at least one page, like 1-3, 5."
            case .invalid(let token): "“\(token)” isn't a valid page or range."
            case .outOfBounds(let page, let count): "Page \(page) doesn't exist — this PDF has \(count) page\(count == 1 ? "" : "s")."
            }
        }
    }

    /// Returns ranges in the order written (duplicates preserved, so "3,1" reorders).
    static func parseGroups(_ text: String, pageCount: Int) throws -> [[Int]] {
        let tokens = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { throw ParseError.empty }
        return try tokens.map { token in
            let normalized = token.replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-").replacingOccurrences(of: " ", with: "")
            if normalized.lowercased() == "all" { return Array(0 ..< pageCount) }
            if normalized.lowercased() == "last" {
                guard pageCount > 0 else { throw ParseError.outOfBounds(1, pageCount: pageCount) }
                return [pageCount - 1]
            }
            let parts = normalized.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
            switch parts.count {
            case 1:
                guard let page = Int(parts[0]) else { throw ParseError.invalid(token) }
                try check(page, pageCount)
                return [page - 1]
            case 2:
                let start = parts[0].isEmpty ? 1 : Int(parts[0])
                let end = parts[1].isEmpty ? pageCount : (parts[1].lowercased() == "last" ? pageCount : Int(parts[1]))
                guard let start, let end else { throw ParseError.invalid(token) }
                try check(start, pageCount)
                try check(end, pageCount)
                return start <= end ? Array((start - 1) ... (end - 1)) : Array(((end - 1) ... (start - 1)).reversed())
            default:
                throw ParseError.invalid(token)
            }
        }
    }

    static func parse(_ text: String, pageCount: Int) throws -> [Int] {
        try parseGroups(text, pageCount: pageCount).flatMap { $0 }
    }

    /// Unique, sorted indices — for "apply to these pages" style options.
    static func parseSet(_ text: String, pageCount: Int) throws -> Set<Int> {
        Set(try parse(text, pageCount: pageCount))
    }

    private static func check(_ page: Int, _ count: Int) throws {
        guard page >= 1, page <= count else { throw ParseError.outOfBounds(page, pageCount: count) }
    }

    /// Compact description of indices, e.g. [0,1,2,4] → "1–3, 5".
    static func describe(_ indices: [Int]) -> String {
        let sorted = Array(Set(indices)).sorted()
        guard var start = sorted.first else { return "" }
        var previous = start
        var parts: [String] = []
        for index in sorted.dropFirst() {
            if index == previous + 1 { previous = index; continue }
            parts.append(start == previous ? "\(start + 1)" : "\(start + 1)–\(previous + 1)")
            start = index
            previous = index
        }
        parts.append(start == previous ? "\(start + 1)" : "\(start + 1)–\(previous + 1)")
        return parts.joined(separator: ", ")
    }
}
