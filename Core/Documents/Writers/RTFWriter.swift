import Foundation
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Hand-written RTF 1.9 generator. Readable by Word, Pages, TextEdit and LibreOffice.
enum RTFWriter {
    static func render(_ document: RichDocument, options: DocumentExportOptions = .default) -> String {
        let halfPoints = Int((options.fontSize * 2).rounded())
        let page = options.pageRect
        let margin = Int(options.marginPoints * 20)
        let lineSpacing = Int((240 * options.lineSpacing).rounded())
        let bodyFont = options.fontFamily == .mono ? 1 : (options.fontFamily == .sans ? 2 : 0)
        var context = Context(halfPoints: halfPoints, lineSpacing: lineSpacing, bodyFont: bodyFont, textWidthTwips: Int((page.width - options.marginPoints * 2) * 20), includeImages: options.includeImages)

        var rtf = "{\\rtf1\\ansi\\ansicpg1252\\deff0\\uc1\n"
        rtf += "{\\fonttbl{\\f0\\froman\\fcharset0 Times New Roman;}{\\f1\\fmodern\\fcharset0 Courier New;}{\\f2\\fswiss\\fcharset0 Helvetica;}}\n"
        rtf += "{\\colortbl;\\red11\\green95\\blue165;\\red184\\green194\\blue204;\\red64\\green64\\blue64;}\n"
        var info = ""
        if let title = options.title ?? document.metadata.title { info += "{\\title \(escape(title))}" }
        if let author = options.author ?? document.metadata.author { info += "{\\author \(escape(author))}" }
        if let subject = document.metadata.subject { info += "{\\subject \(escape(subject))}" }
        if !document.metadata.keywords.isEmpty { info += "{\\keywords \(escape(document.metadata.keywords.joined(separator: ", ")))}" }
        if !info.isEmpty { rtf += "{\\info\(info)}\n" }
        rtf += "\\paperw\(Int(page.width * 20))\\paperh\(Int(page.height * 20))\\margl\(margin)\\margr\(margin)\\margt\(margin)\\margb\(margin)"
        if options.orientation == .landscape { rtf += "\\landscape" }
        rtf += "\\widowctrl\n"
        if options.pageNumbers {
            rtf += "{\\footer\\pard\\qc\\f\(bodyFont)\\fs\(max(16, halfPoints - 4)) {\\field{\\*\\fldinst PAGE}{\\fldrslt 1}}\\par}\n"
        }
        for block in document.blocks {
            rtf += context.block(block, listLevel: 0)
        }
        rtf += "}"
        return rtf
    }

    static func data(_ document: RichDocument, options: DocumentExportOptions = .default) -> Data {
        Data(render(document, options: options).utf8)
    }

    private struct Context {
        let halfPoints: Int
        let lineSpacing: Int
        let bodyFont: Int
        let textWidthTwips: Int
        let includeImages: Bool

        var basePara: String {
            "\\pard\\plain\\f\(bodyFont)\\fs\(halfPoints)\\sa160\\sl\(lineSpacing)\\slmult1"
        }

        func block(_ block: Block, listLevel: Int) -> String {
            switch block {
            case .heading(let level, let runs):
                let scales = [2.0, 1.6, 1.3, 1.12, 1.0, 1.0]
                let size = Int((Double(halfPoints) * scales[min(max(level, 1), 6) - 1]).rounded())
                return "\\pard\\plain\\s\(level)\\outlinelevel\(level - 1)\\keepn\\f\(bodyFont)\\fs\(size)\\b\\sb240\\sa120 \(inline(runs))\\par\n"
            case .paragraph(let runs, let alignment):
                let align = switch alignment {
                case .center: "\\qc"
                case .right: "\\qr"
                case .justified: "\\qj"
                default: ""
                }
                return "\(basePara)\(align) \(inline(runs))\\par\n"
            case .list(let ordered, let items):
                var rtf = ""
                for (index, item) in items.enumerated() {
                    let marker = ordered ? "\(index + 1)." : (listLevel % 2 == 0 ? "\\bullet" : "\\u9702?")
                    let indent = 720 * (listLevel + 1)
                    var first = true
                    for child in item {
                        switch child {
                        case .list:
                            rtf += self.block(child, listLevel: listLevel + 1)
                        case .paragraph(let runs, _) where first:
                            rtf += "\\pard\\plain\\f\(bodyFont)\\fs\(halfPoints)\\sa60\\fi-360\\li\(indent)\\tx\(indent) \(marker)\\tab \(inline(runs))\\par\n"
                        case .paragraph(let runs, _):
                            rtf += "\\pard\\plain\\f\(bodyFont)\\fs\(halfPoints)\\sa60\\li\(indent) \(inline(runs))\\par\n"
                        default:
                            rtf += self.block(child, listLevel: listLevel + 1)
                        }
                        first = false
                    }
                    if item.isEmpty {
                        rtf += "\\pard\\plain\\f\(bodyFont)\\fs\(halfPoints)\\fi-360\\li\(indent) \(marker)\\tab\\par\n"
                    }
                }
                return rtf
            case .table(let table):
                let columns = max(table.columnCount, 1)
                let width = max(textWidthTwips, 1440) / columns
                var rtf = ""
                for (rowIndex, row) in table.rows.enumerated() {
                    let header = table.hasHeaderRow && rowIndex == 0
                    rtf += "\\trowd\\trgaph108\\trleft0" + (header ? "\\trhdr" : "")
                    for column in 0 ..< columns {
                        rtf += "\\clbrdrt\\brdrs\\brdrw10\\brdrcf2\\clbrdrl\\brdrs\\brdrw10\\brdrcf2\\clbrdrb\\brdrs\\brdrw10\\brdrcf2\\clbrdrr\\brdrs\\brdrw10\\brdrcf2\\cellx\(width * (column + 1))"
                    }
                    rtf += "\n"
                    for column in 0 ..< columns {
                        let cell = column < row.count ? row[column] : []
                        let text = cell.map { child -> String in
                            if case .paragraph(let runs, _) = child { return inline(runs) }
                            return escape(child.plainText)
                        }.joined(separator: "\\line ")
                        rtf += "\\pard\\plain\\intbl\\f\(bodyFont)\\fs\(halfPoints)" + (header ? "\\b" : "") + " \(text)\\cell\n"
                    }
                    rtf += "\\row\n"
                }
                return rtf + "\\pard\\plain\\par\n"
            case .image(let image):
                guard includeImages, let pict = picture(image) else { return "" }
                return "\\pard\\plain\\qc \(pict)\\par\n"
            case .imageRow(let row):
                guard includeImages, !row.isEmpty else { return "" }
                let sizes = ImageRowLayout.sizes(for: row, available: CGFloat(textWidthTwips) / 20 - 4, gap: 8)
                let picts = zip(row, sizes).compactMap { picture($0, size: $1) }
                return picts.isEmpty ? "" : "\\pard\\plain\\qc " + picts.joined(separator: "  ") + "\\par\n"
            case .quote(let blocks):
                return blocks.map { child -> String in
                    if case .paragraph(let runs, _) = child {
                        return "\\pard\\plain\\f\(bodyFont)\\fs\(halfPoints)\\li720\\ri720\\sa160\\i\\cf3 \(inline(runs))\\par\n"
                    }
                    return self.block(child, listLevel: listLevel)
                }.joined()
            case .code(let code):
                let lines = code.components(separatedBy: "\n").map { escape($0) }.joined(separator: "\\line ")
                return "\\pard\\plain\\f1\\fs\(max(16, halfPoints - 2))\\sa160 \(lines)\\par\n"
            case .rule:
                return "\\pard\\plain\\brdrb\\brdrs\\brdrw10\\brdrcf2\\brsp20\\sa160\\par\n"
            case .pageBreak:
                return "\\pard\\plain\\page\n"
            }
        }

        func inline(_ runs: [Run]) -> String {
            runs.coalesced().map { run -> String in
                var controls = ""
                let style = run.style
                if style.bold { controls += "\\b" }
                if style.italic { controls += "\\i" }
                if style.underline || style.link != nil { controls += "\\ul" }
                if style.strikethrough { controls += "\\strike" }
                if style.superscript { controls += "\\super" }
                if style.subscript { controls += "\\sub" }
                if style.code { controls += "\\f1" }
                if style.link != nil { controls += "\\cf1" }
                let text = escape(run.text)
                let group = controls.isEmpty ? text : "{\(controls) \(text)}"
                if let link = style.link {
                    let target = link.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "%22")
                    return "{\\field{\\*\\fldinst{HYPERLINK \"\(escape(target))\"}}{\\fldrslt \(group)}}"
                }
                return group
            }.joined()
        }

        func picture(_ image: ImageBlock, size fixedSize: CGSize? = nil) -> String? {
            var data = image.data
            var kind = "\\pngblip"
            switch image.mimeType {
            case "image/png": kind = "\\pngblip"
            case "image/jpeg": kind = "\\jpegblip"
            default:
                guard let png = UIImage(data: image.data)?.pngData() else { return nil }
                data = png
            }
            let size = fixedSize ?? image.size ?? EmbeddedImageSizing.pointSize(of: data) ?? CGSize(width: 300, height: 200)
            let maxWidth = CGFloat(textWidthTwips) / 20
            let scale = size.width > maxWidth ? maxWidth / size.width : 1
            let goalWidth = Int(size.width * scale * 20)
            let goalHeight = Int(size.height * scale * 20)
            var hex = ""
            hex.reserveCapacity(data.count * 2 + data.count / 64)
            let digits = Array("0123456789abcdef")
            for (index, byte) in data.enumerated() {
                hex.append(digits[Int(byte >> 4)])
                hex.append(digits[Int(byte & 0x0F)])
                if index % 64 == 63 { hex.append("\n") }
            }
            return "{\\pict\(kind)\\picwgoal\(goalWidth)\\pichgoal\(goalHeight)\n\(hex)}"
        }
    }

    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "{": result += "\\{"
            case "}": result += "\\}"
            case "\n": result += "\\line "
            case "\t": result += "\\tab "
            case "\u{00A0}": result += "\\~"
            default:
                if scalar.value < 0x20 { continue }
                if scalar.value < 0x80 {
                    result.unicodeScalars.append(scalar)
                } else {
                    // \uN with signed 16-bit values; astral characters become UTF-16 surrogate pairs.
                    for unit in String(scalar).utf16 {
                        result += "\\u\(Int16(bitPattern: unit))?"
                    }
                }
            }
        }
        return result
    }

    /// Reverses `escape` for simple `\info` fields.
    static func unescape(_ text: String) -> String {
        var result = ""
        var chars = Array(text)[...]
        var pendingHigh: UInt16?
        while let ch = chars.first {
            chars = chars.dropFirst()
            guard ch == "\\" else { result.append(ch); continue }
            guard let next = chars.first else { break }
            if next == "u", chars.dropFirst().first.map({ $0 == "-" || $0.isNumber }) == true {
                chars = chars.dropFirst()
                var digits = ""
                while let d = chars.first, d == "-" || d.isNumber { digits.append(d); chars = chars.dropFirst() }
                if chars.first == "?" { chars = chars.dropFirst() }
                let unit = UInt16(bitPattern: Int16(digits) ?? 63)
                if (0xD800 ... 0xDBFF).contains(unit) {
                    pendingHigh = unit
                } else if let high = pendingHigh {
                    result += String(utf16CodeUnits: [high, unit], count: 2)
                    pendingHigh = nil
                } else {
                    result += String(utf16CodeUnits: [unit], count: 1)
                }
            } else if next == "'" {
                let hex = String(chars.dropFirst().prefix(2))
                chars = chars.dropFirst(3)
                if let byte = UInt8(hex, radix: 16) {
                    result += String(data: Data([byte]), encoding: .windowsCP1252) ?? ""
                }
            } else {
                result.append(next)
                chars = chars.dropFirst()
            }
        }
        return result
    }
}
