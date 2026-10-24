import Foundation
import UIKit
import ZIPFoundation

extension ToolCatalog {
    static let utilityTools: [ToolDefinition] = [
        ToolDefinition(
            id: "util.qr", title: "QR Code Generator", summary: "Links, Wi-Fi and text as a crisp QR code",
            symbol: "qrcode", category: .utilities, input: .none,
            options: [
                .choice("kind", "Type", [ToolChoice("text", "Text or link"), ToolChoice("wifi", "Wi-Fi")], segmented: true),
                .text("text", "Content", placeholder: "https://example.com", multiline: true, keyboard: .url, visible: { $0.string("kind") != "wifi" }),
                .text("ssid", "Network name", placeholder: "Home Wi-Fi", visible: { $0.string("kind") == "wifi" }),
                .text("wifiPassword", "Password", placeholder: "Leave empty for open networks", secure: true, visible: { $0.string("kind") == "wifi" }),
                .choice("size", "Size", [ToolChoice("512", "512"), ToolChoice("1024", "1024"), ToolChoice("2048", "2048")], default: "1024", segmented: true, section: "Style"),
                .choice("correction", "Error correction", ImageToolkit.QRCorrection.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: ImageToolkit.QRCorrection.medium.rawValue, section: "Style"),
                .color("foreground", "Color", default: 0x0B1622, section: "Style"),
                .color("background", "Background", default: 0xFFFFFF, section: "Style")
            ],
            keywords: ["qr", "barcode", "link", "wifi"], isFeatured: true, actionTitle: "Generate"
        ) { context in
            let content: String
            if context.options.string("kind") == "wifi" {
                guard let ssid = context.options.string("ssid").nilIfBlank else { throw DocumentError.invalidOption("Enter the network name.") }
                func escape(_ value: String) -> String {
                    value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,").replacingOccurrences(of: ":", with: "\\:")
                }
                let password = context.options.string("wifiPassword")
                content = password.isEmpty ? "WIFI:T:nopass;S:\(escape(ssid));;" : "WIFI:T:WPA;S:\(escape(ssid));P:\(escape(password));;"
            } else {
                guard let text = context.options.string("text").nilIfBlank else { throw DocumentError.invalidOption("Enter text or a link.") }
                content = text
            }
            let image = try ImageToolkit.qrCode(
                content, size: context.options.int("size"),
                correction: context.options.choice("correction", as: ImageToolkit.QRCorrection.self, default: .medium),
                foregroundHex: context.options.hex("foreground"), backgroundHex: context.options.hex("background")
            )
            return ToolOutput(files: [try ToolHelpers.write(try ImageToolkit.encode(image, as: .png), "QR Code", "png", context)])
        },

        ToolDefinition(
            id: "util.zip", title: "Create ZIP", summary: "Bundle any files into one archive",
            symbol: "doc.zipper", category: .utilities, input: .many(Set(FileFormat.allCases), noun: "files", max: 200),
            options: [.text("name", "Archive name", placeholder: "Archive", default: "Archive")],
            keywords: ["compress", "archive", "bundle", "zip files"], actionTitle: "Create ZIP"
        ) { context in
            let url = try ToolStorage.zip(context.inputs.map(\.url), named: context.options.string("name").nilIfBlank ?? "Archive", in: context.outputDirectory)
            let before = context.inputs.map(\.byteCount).reduce(0, +)
            let after = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return ToolOutput(files: [url], summary: "\(context.inputs.count) files · \(ToolHelpers.savings(before: before, after: after))")
        },

        ToolDefinition(
            id: "util.unzip", title: "Open ZIP", summary: "Extract files from a ZIP archive",
            symbol: "archivebox", category: .utilities, input: .one([.zip], noun: "ZIP archive"),
            keywords: ["unzip", "extract", "decompress", "archive"], actionTitle: "Extract"
        ) { context in
            let input = try context.first
            let archive = try Archive(url: input.url, accessMode: .read)
            var urls: [URL] = []
            for entry in archive where entry.type == .file {
                let name = (entry.path as NSString).lastPathComponent
                // Skip macOS resource forks and hidden files.
                guard !name.hasPrefix("."), !entry.path.hasPrefix("__MACOSX") else { continue }
                guard urls.count < 500 else { break }
                let url = context.outputURL((name as NSString).deletingPathExtension, (name as NSString).pathExtension)
                _ = try archive.extract(entry, to: url, skipCRC32: false)
                urls.append(url)
            }
            guard !urls.isEmpty else { throw DocumentError.empty("The archive is empty.") }
            return ToolOutput(files: urls, summary: "\(urls.count) file\(urls.count == 1 ? "" : "s")")
        },

        ToolDefinition(
            id: "util.webpdf", title: "Web Page to PDF", summary: "Save any URL as a clean PDF",
            symbol: "globe", category: .utilities, input: .none,
            options: [
                .text("url", "Web address", placeholder: "https://", keyboard: .url),
                .choice("pageSize", "Page size", PageSize.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: PageSize.regionalDefault.rawValue),
                .choice("margins", "Margins", PageMargins.allCases.map { ToolChoice($0.rawValue, $0.label) }, default: PageMargins.narrow.rawValue, segmented: true)
            ],
            keywords: ["url to pdf", "website", "save page", "html to pdf"], actionTitle: "Save PDF"
        ) { context in
            let url = try webURL(context.options.string("url"))
            var options = DocumentExportOptions()
            options.pageSize = PageSize(rawValue: context.options.string("pageSize")) ?? .a4
            options.margins = PageMargins(rawValue: context.options.string("margins")) ?? .narrow
            let data = try await WebPDFRenderer.renderRemote(url, setup: .init(options: options, title: url.host, author: nil))
            return ToolOutput(files: [try ToolHelpers.write(data, url.host ?? "Web Page", "pdf", context)])
        },

        ToolDefinition(
            id: "util.webimage", title: "Web Page to Image", summary: "Full-page screenshot of a URL",
            symbol: "camera.viewfinder", category: .utilities, input: .none,
            options: [
                .text("url", "Web address", placeholder: "https://", keyboard: .url),
                .choice("width", "Viewport", [ToolChoice("390", "Phone"), ToolChoice("820", "Tablet"), ToolChoice("1280", "Desktop")], default: "1280", segmented: true),
                .choice("saveAs", "Save as", [ToolChoice("png", "PNG"), ToolChoice("jpeg", "JPEG")], segmented: true)
            ],
            keywords: ["url to png", "url to jpg", "screenshot", "website", "capture"], actionTitle: "Capture"
        ) { context in
            let url = try webURL(context.options.string("url"))
            let image = try await WebPDFRenderer.snapshotFile(url, width: CGFloat(context.options.double("width")), remote: true)
            guard let cgImage = image.cgImage else { throw DocumentError.writeFailed("The page couldn't be captured.") }
            let format = ImageToolkit.OutputFormat(rawValue: context.options.string("saveAs")) ?? .png
            return ToolOutput(files: [try ToolHelpers.write(try ImageToolkit.encode(cgImage, as: format, quality: 0.9), url.host ?? "Web Page", format.fileExtension, context)])
        },

        ToolDefinition(
            id: "util.write", title: "Create Document", summary: "Type or paste text, export as PDF, Word and more",
            symbol: "square.and.pencil", category: .documents, input: .none,
            options: [
                .text("body", "Text", placeholder: "Start typing. Markdown works: # Heading, **bold**, - lists", multiline: true, section: "Content"),
                .choice("target", "Save as", [FileFormat.pdf, .docx, .odt, .rtf, .epub, .html, .markdown, .txt].map { ToolChoice($0.rawValue, $0.displayName) }, section: "Output")
            ] + layoutOptions(fixedTarget: nil).filter { $0.key != "layout" },
            keywords: ["create pdf", "text to pdf", "write", "new document", "markdown"], actionTitle: "Create"
        ) { context in
            guard let body = context.options.string("body").nilIfBlank else { throw DocumentError.invalidOption("Write something first.") }
            let document = MarkdownReader.read(markdown: body)
            let target = FileFormat(rawValue: context.options.string("target")) ?? .pdf
            let settings = conversionSettings(context.options)
            let name = settings.document.title ?? document.resolvedTitle ?? "Document"
            let url = context.outputURL(String(name.prefix(60)), target.fileExtension)
            try await DocumentConverter.write(document, as: target, options: settings.document, to: url)
            return ToolOutput(files: [url])
        }
    ]

    static func webURL(_ text: String) throws -> URL {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw DocumentError.invalidOption("Enter a web address.") }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw DocumentError.invalidOption("That doesn't look like a web address.")
        }
        return url
    }
}
