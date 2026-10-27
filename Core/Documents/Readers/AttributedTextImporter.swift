import Foundation
import UIKit

/// Maps `NSAttributedString` content (from RTF or PDFKit) onto `RichDocument` blocks.
enum AttributedTextImporter {
    static func document(from attributed: NSAttributedString) -> RichDocument {
        let baseSize = dominantFontSize(attributed)
        var flat: [FlatBlock] = []
        let string = attributed.string as NSString
        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)
            var contentRange = paragraphRange
            // Exclude the paragraph terminator.
            while contentRange.length > 0 {
                let last = string.character(at: NSMaxRange(contentRange) - 1)
                if last == 0x0A || last == 0x0D || last == 0x2029 { contentRange.length -= 1 } else { break }
            }
            let paragraph = attributed.attributedSubstring(from: contentRange)
            flat.append(contentsOf: blocks(for: paragraph, baseSize: baseSize))
        }
        return RichDocument(blocks: ListAssembler.assemble(flat))
    }

    static func dominantFontSize(_ attributed: NSAttributedString) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            guard let font = value as? UIFont else { return }
            weights[font.pointSize.rounded(), default: 0] += range.length
        }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    static func blocks(for paragraph: NSAttributedString, baseSize: CGFloat) -> [FlatBlock] {
        var result: [FlatBlock] = []
        var runs: [Run] = []
        var maxSize: CGFloat = 0
        var allBold = true
        var alignment: TextAlignment = .natural
        var indent: CGFloat = 0
        var textLists: [NSTextList] = []
        paragraph.enumerateAttributes(in: NSRange(location: 0, length: paragraph.length)) { attributes, range, _ in
            if let attachment = attributes[.attachment] as? NSTextAttachment {
                if let image = imageBlock(from: attachment) { result.append(.block(.image(image))) }
                return
            }
            let text = (paragraph.string as NSString).substring(with: range).replacingOccurrences(of: "\u{2028}", with: "\n")
            var style = RunStyle()
            if let font = attributes[.font] as? UIFont {
                let traits = font.fontDescriptor.symbolicTraits
                style.bold = traits.contains(.traitBold) || font.fontName.lowercased().contains("bold")
                style.italic = traits.contains(.traitItalic) || font.fontName.lowercased().contains("italic") || font.fontName.lowercased().contains("oblique")
                style.code = traits.contains(.traitMonoSpace) || font.fontName.lowercased().contains("courier") || font.fontName.lowercased().contains("mono")
                if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                    maxSize = max(maxSize, font.pointSize)
                }
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 { style.underline = true }
            if let strike = attributes[.strikethroughStyle] as? Int, strike != 0 { style.strikethrough = true }
            if let link = attributes[.link] {
                style.link = (link as? URL)?.absoluteString ?? (link as? String)
                style.underline = false
            }
            if let offset = attributes[.baselineOffset] as? CGFloat {
                if offset > 0.5 { style.superscript = true } else if offset < -0.5 { style.subscript = true }
            }
            if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
                alignment = switch paragraphStyle.alignment {
                case .center: .center
                case .right: .right
                case .justified: .justified
                default: .natural
                }
                indent = max(paragraphStyle.headIndent, paragraphStyle.firstLineHeadIndent)
                if !paragraphStyle.textLists.isEmpty { textLists = paragraphStyle.textLists }
            }
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !style.bold { allBold = false }
            runs.append(Run(text, style))
        }

        let cleaned = runs.coalesced()
        let plain = cleaned.plainText
        let trimmedPlain = plain.trimmingCharacters(in: .whitespaces)
        guard !trimmedPlain.isEmpty else { return result }

        if let list = textLists.last {
            let bulletFormats: Set<NSTextList.MarkerFormat> = [.disc, .circle, .square, .hyphen, .box, .check, .diamond]
            let content = cleaned.trimmed()
            let item: [Block] = content.isEmpty ? [] : [.paragraph(runs: content)]
            return [.listItem(level: textLists.count - 1, ordered: !bulletFormats.contains(list.markerFormat), content: item)] + result
        }

        if let marker = listMarker(in: plain) {
            let level = max(0, Int((indent / 36).rounded(.down)) - 1)
            let content = dropPrefix(cleaned, count: marker.length).trimmed()
            let item: [Block] = content.isEmpty ? [] : [.paragraph(runs: content)]
            return [.listItem(level: min(level, 6), ordered: marker.ordered, content: item)] + result
        }

        let ratio = maxSize / max(baseSize, 1)
        let isShort = trimmedPlain.count < 160 && !plain.contains("\n")
        if isShort, ratio >= 1.15 {
            let level = ratio >= 1.75 ? 1 : (ratio >= 1.4 ? 2 : 3)
            let headingRuns = cleaned.trimmed().map { run -> Run in
                var copy = run
                copy.style.bold = false
                return copy
            }
            return [.block(.heading(level: level, runs: headingRuns))] + result
        }
        if allBold, isShort, trimmedPlain.count < 80, !trimmedPlain.hasSuffix("."), !trimmedPlain.hasSuffix(","), cleaned.count == 1, ratio >= 1.0, ratio < 1.15, trimmedPlain.split(separator: " ").count <= 10 {
            // Bold, short, unpunctuated line at body size: a run-in heading.
            let headingRuns = cleaned.trimmed().map { run -> Run in
                var copy = run
                copy.style.bold = false
                return copy
            }
            return [.block(.heading(level: 4, runs: headingRuns))] + result
        }
        return [.block(.paragraph(runs: cleaned.trimmed(), alignment: alignment))] + result
    }

    struct ListMarker {
        let ordered: Bool
        /// Number of characters (marker + following whitespace) to drop.
        let length: Int
    }

    static func listMarker(in text: String) -> ListMarker? {
        let chars = Array(text)
        var i = 0
        while i < chars.count, chars[i] == "\t" || chars[i] == " " { i += 1 }
        guard i < chars.count else { return nil }
        let bullets: Set<Character> = ["•", "◦", "▪", "‣", "●", "○", "■", "□", "–", "-", "*", "\u{F0B7}", "·"]
        if bullets.contains(chars[i]), i + 1 < chars.count, chars[i + 1] == "\t" || chars[i + 1] == " " {
            var end = i + 1
            while end < chars.count, chars[end] == "\t" || chars[end] == " " { end += 1 }
            return ListMarker(ordered: false, length: end)
        }
        var j = i
        while j < chars.count, chars[j].isNumber { j += 1 }
        if j > i, j - i <= 3, j < chars.count, chars[j] == "." || chars[j] == ")",
           j + 1 < chars.count, chars[j + 1] == "\t" || (chars[j + 1] == " " && j + 2 < chars.count && chars[j + 2] != " ") {
            var end = j + 1
            while end < chars.count, chars[end] == "\t" || chars[end] == " " { end += 1 }
            return ListMarker(ordered: true, length: end)
        }
        return nil
    }

    private static func dropPrefix(_ runs: [Run], count: Int) -> [Run] {
        var remaining = count
        var result: [Run] = []
        for run in runs {
            if remaining <= 0 { result.append(run); continue }
            if run.text.count <= remaining {
                remaining -= run.text.count
            } else {
                var copy = run
                copy.text = String(run.text.dropFirst(remaining))
                remaining = 0
                result.append(copy)
            }
        }
        return result
    }

    private static func imageBlock(from attachment: NSTextAttachment) -> ImageBlock? {
        if let data = attachment.contents ?? attachment.fileWrapper?.regularFileContents {
            let mime = ImageBlock.sniffMimeType(data) ?? "image/png"
            return ImageBlock(data: data, mimeType: mime, size: attachment.bounds.size == .zero ? nil : attachment.bounds.size)
        }
        if let image = attachment.image, let png = image.pngData() {
            return ImageBlock(data: png, mimeType: "image/png", size: image.size)
        }
        return nil
    }
}
