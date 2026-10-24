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

    static func search(_ query: String) -> [ToolDefinition] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        let lower = trimmed.lowercased()
        return all.filter { $0.matches(trimmed) }.sorted { a, b in
            // Title prefix matches first, then title contains, then keyword matches.
            func rank(_ tool: ToolDefinition) -> Int {
                let title = tool.title.lowercased()
                if title.hasPrefix(lower) { return 0 }
                if title.contains(lower) { return 1 }
                if tool.keywords.contains(where: { $0.lowercased() == lower }) { return 1 }
                return 2
            }
            return rank(a) < rank(b)
        }
    }

    static let featuredOrder: [ToolID] = [
        "convert.pdf.docx", "pdf.compress", "pdf.merge", "pdf.fromimages", "image.removebg", "pdf.sign",
        "convert.docx.pdf", "video.compress", "image.convert", "pdf.edit", "video.gif", "image.ocr"
    ]

    static var featured: [ToolDefinition] {
        featuredOrder.compactMap(tool)
    }

    /// Tools that can take this file as (one of) their inputs, best matches first.
    static func tools(accepting format: FileFormat) -> [ToolDefinition] {
        all.filter { $0.input.accepts(format) && $0.id != "util.zip" }.sorted { a, b in
            (a.category.rawValue == categoryHint(for: format).rawValue ? 0 : 1, a.isFeatured ? 0 : 1) < (b.category.rawValue == categoryHint(for: format).rawValue ? 0 : 1, b.isFeatured ? 0 : 1)
        }
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
