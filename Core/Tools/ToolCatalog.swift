import Foundation

/// Every tool in the app, grouped and searchable.
enum ToolCatalog {
    static let all: [ToolDefinition] = {
        let tools = pdfTools + documentConversions.filter { $0.category == .pdf }
            + [universalConverter] + documentConversions.filter { $0.category == .documents } + [utilityTools.first { $0.id == "util.write" }!]
            + spreadsheetConversions + spreadsheetTools
            + imageTools + documentConversions.filter { $0.category == .images }
            + videoTools + audioTools
            + utilityTools.filter { $0.id != "util.write" }
        return tools
    }()

    private static let index: [ToolID: ToolDefinition] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func tool(_ id: ToolID) -> ToolDefinition? { index[id] }

    static func tools(in category: ToolCategory) -> [ToolDefinition] {
        all.filter { $0.category == category }
    }

    /// Tools for a plain-English query, best first: "turn my photo into a pdf" leads with Images to PDF.
    static func search(_ query: String) -> [ToolDefinition] {
        let search = ToolSearchQuery(query)
        guard !search.isEmpty else { return all }
        return all.enumerated()
            .compactMap { index, tool in search.score(tool).map { (tool: tool, score: $0, index: index) } }
            // Catalog order breaks ties, so equally good matches keep their usual grouping.
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
            .map(\.tool)
    }

    static let featuredOrder: [ToolID] = [
        "convert.pdf.docx", "pdf.compress", "pdf.merge", "pdf.fromimages", "image.removebg", "pdf.sign",
        "convert.docx.pdf", "video.compress", "image.convert", "pdf.edit", "video.gif", "image.ocr"
    ]

    static var featured: [ToolDefinition] {
        featuredOrder.compactMap(tool)
    }

    /// What people most often want next for a kind of file, even from another category:
    /// a photo usually becomes a PDF.
    static let leadingTools: [FileFamily: [ToolID]] = [
        .image: ["pdf.fromimages"]
    ]

    /// Tools that can take this file as (one of) their inputs, best matches first: the leading tools for
    /// its kind, then popular tools, then the file's own category, in catalog order.
    static func tools(accepting format: FileFormat) -> [ToolDefinition] {
        let category = categoryHint(for: format)
        let leading = leadingTools[format.family] ?? []
        func rank(_ tool: ToolDefinition, _ index: Int) -> (Int, Int, Int, Int) {
            (leading.firstIndex(of: tool.id) ?? leading.count, tool.isFeatured ? 0 : 1, tool.category == category ? 0 : 1, index)
        }
        return all.enumerated()
            .filter { $0.element.input.accepts(format) && $0.element.id != "util.zip" }
            .sorted { rank($0.element, $0.offset) < rank($1.element, $1.offset) }
            .map(\.element)
    }

    static func categoryHint(for format: FileFormat) -> ToolCategory {
        switch format.family {
        case .pdf: .pdf
        case .document, .presentation: .documents
        case .spreadsheet: .spreadsheets
        case .image: .images
        case .video: .video
        case .audio: .audio
        case .archive, .other: .utilities
        }
    }

    /// Direct "Convert to …" shortcut for a file, if a named preset exists.
    static func conversionTool(from source: FileFormat, to target: FileFormat) -> ToolDefinition? {
        (documentConversions + spreadsheetConversions).first { tool in
            tool.input.accepts(source) && tool.id.rawValue.hasSuffix(".\(target.rawValue)")
        }
    }
}

/// A tool search typed the way people talk ("turn my photo into a pdf", "shrink video").
/// Filler words are dropped, common synonyms count as matches, and "X to Y" / "Y from X" is read as
/// a direction: tools that start from X and end with Y rank first.
struct ToolSearchQuery {
    /// One word of the query and the words that count as finding it.
    struct Term {
        /// The word and its singular ("pdfs" → "pdf").
        let forms: [String]
        let synonyms: [String]

        init(_ word: String) {
            let singular = ToolSearchQuery.singular(word)
            let forms = singular == word ? [word] : [word, singular]
            let group = ToolSearchQuery.synonymGroups.first { $0.contains(word) || $0.contains(singular) } ?? []
            self.forms = forms
            synonyms = group.filter { !forms.contains($0) }
        }

        func occurs(in text: String) -> Bool {
            (forms + synonyms).contains { text.contains($0) }
        }

        /// How well this word is found in a tool: a title word beats a keyword, which beats the
        /// summary; a synonym counts for a bit over half of the word itself.
        func score(in fields: Fields) -> Double {
            func best(_ words: [String]) -> Double {
                if forms.contains(where: { fields.has($0, in: words) }) { return 1 }
                if synonyms.contains(where: { fields.has($0, in: words) }) { return 0.6 }
                return 0
            }
            let score = max(best(fields.titleWords) * 10, best(fields.keywordWords) * 8,
                            best(fields.summaryWords) * 6, best(fields.categoryWords) * 3)
            return score > 0 ? score : (occurs(in: fields.haystack) ? 1 : 0)
        }
    }

    /// A tool's searchable text, normalized the same way as the query.
    struct Fields {
        let title: String
        let keywords: [String]
        let haystack: String
        let titleWords: [String]
        let keywordWords: [String]
        let summaryWords: [String]
        let categoryWords: [String]
        /// What the tool starts from and what it makes, read from "X to Y" titles, keywords and summaries.
        let directions: [(from: String, to: String)]

        init(_ tool: ToolDefinition) {
            title = ToolSearchQuery.normalize(tool.title)
            keywords = tool.keywords.map(ToolSearchQuery.normalize)
            let summary = ToolSearchQuery.normalize(tool.summary)
            let category = ToolSearchQuery.normalize(tool.category.title)
            haystack = ([title, summary, category] + keywords).joined(separator: " ")
            titleWords = ToolSearchQuery.words(title)
            keywordWords = keywords.flatMap(ToolSearchQuery.words)
            summaryWords = ToolSearchQuery.words(summary)
            categoryWords = ToolSearchQuery.words(category)
            var directions = ([title] + keywords + [summary]).compactMap(ToolSearchQuery.direction)
            if let titled = ToolSearchQuery.direction(title) {
                // "Images to PDF" also starts from whatever its file picker asks for.
                directions.append((ToolSearchQuery.normalize(tool.input.noun), titled.to))
            }
            self.directions = directions
        }

        func has(_ prefix: String, in words: [String]) -> Bool {
            words.contains { $0.hasPrefix(prefix) }
        }
    }

    static let stopwords: Set<String> = [
        "a", "an", "the", "my", "to", "into", "from", "for", "of", "and", "me", "i", "want", "how", "can", "please",
        "this", "that", "these", "some", "do"
    ]
    /// "Make", "turn"… say what to do in general; they help ranking but aren't required to match.
    static let verbs: Set<String> = ["make", "turn", "create", "convert", "change"]
    static let synonymGroups: [[String]] = [
        ["picture", "photo", "image", "pic", "jpg", "jpeg", "png"],
        ["make", "turn", "create", "convert"],
        ["smaller", "compress", "shrink", "reduce"],
        ["combine", "merge", "join"],
        ["sign", "signature"],
        ["pdf", "pdfs"]
    ]

    let phrase: String
    /// Every one must be found in the tool.
    let terms: [Term]
    /// Count toward ranking only.
    let optionalTerms: [Term]
    /// "X" and "Y" of "X to Y" / "Y from X".
    let source: [Term]
    let target: [Term]

    init(_ query: String) {
        phrase = Self.normalize(query)
        let words = Self.words(phrase)
        func meaningful(_ words: [String]) -> [String] {
            words.filter { !Self.stopwords.contains($0) && !Self.verbs.contains($0) }
        }
        let content = meaningful(words)
        let verbs = words.filter(Self.verbs.contains)
        // A query of only verbs or filler ("convert", "to") still has to find something.
        let required = !content.isEmpty ? content : (!verbs.isEmpty ? verbs : words)
        terms = required.map(Term.init)
        optionalTerms = content.isEmpty ? [] : verbs.map(Term.init)

        var sourceWords: [String] = []
        var targetWords: [String] = []
        if let to = words.lastIndex(where: { $0 == "to" || $0 == "into" }) {
            var before = Array(words[..<to])
            if let from = before.lastIndex(of: "from") { before = Array(before[(from + 1)...]) }
            sourceWords = before
            targetWords = Array(words[(to + 1)...])
        } else if let from = words.lastIndex(of: "from") {
            targetWords = Array(words[..<from])
            sourceWords = Array(words[(from + 1)...])
        }
        source = meaningful(sourceWords).map(Term.init)
        target = meaningful(targetWords).map(Term.init)
    }

    var isEmpty: Bool { terms.isEmpty }

    func matches(_ tool: ToolDefinition) -> Bool {
        guard !isEmpty else { return true }
        let haystack = Fields(tool).haystack
        return terms.allSatisfy { $0.occurs(in: haystack) }
    }

    /// Higher is better; nil when the tool doesn't match.
    func score(_ tool: ToolDefinition) -> Double? {
        let fields = Fields(tool)
        guard terms.allSatisfy({ $0.occurs(in: fields.haystack) }) else { return nil }
        var score = terms.map { $0.score(in: fields) }.reduce(0, +)
        score += optionalTerms.map { $0.score(in: fields) / 2 }.reduce(0, +)

        // The whole query as a title or keyword: "remove password" is exactly what Unlock PDF does,
        // which beats a title that merely starts with the same words.
        if fields.title == phrase { score += 70 }
        else if fields.keywords.contains(phrase) { score += 60 }
        else if fields.title.hasPrefix(phrase) { score += 40 }
        else if fields.keywords.contains(where: { $0.contains(phrase) }) { score += 25 }
        else if fields.title.contains(phrase) { score += 20 }

        if !source.isEmpty || !target.isEmpty {
            func all(_ terms: [Term], in text: String) -> Bool { terms.allSatisfy { $0.occurs(in: text) } }
            let forward = fields.directions.contains { all(source, in: $0.from) && all(target, in: $0.to) }
            let backward = !source.isEmpty && !target.isEmpty
                && fields.directions.contains { all(source, in: $0.to) && all(target, in: $0.from) }
            if forward { score += source.isEmpty || target.isEmpty ? 40 : 100 }
            else if backward { score -= 50 }
        }
        return score + (tool.isFeatured ? 1 : 0)
    }

    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return words(String(folded.map { $0.isLetter || $0.isNumber ? $0 : " " })).joined(separator: " ")
    }

    static func words(_ text: String) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    static func singular(_ word: String) -> String {
        word.count > 3 && word.hasSuffix("s") && !word.hasSuffix("ss") ? String(word.dropLast()) : word
    }

    /// "photos and scans into a pdf" → ("photos and scans", "a pdf").
    static func direction(_ text: String) -> (from: String, to: String)? {
        for separator in [" into ", " to "] {
            if let range = text.range(of: separator) {
                let from = String(text[..<range.lowerBound])
                let to = String(text[range.upperBound...])
                if !from.isEmpty && !to.isEmpty { return (from, to) }
            }
        }
        return nil
    }
}
