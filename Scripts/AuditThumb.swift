// AuditThumb <file> <out.png>: a preview of any tool output, for audit contact sheets.
// Images and PDFs render directly, video shows a frame, rich documents render through AppKit,
// audio shows its waveform, and anything else becomes a card with the start of its text.
import AppKit
import AVFoundation
import PDFKit

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
let side: CGFloat = 600

func save(_ image: NSImage) {
    guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: output)
}

func card(_ text: String, title: String) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill()
    (title as NSString).draw(at: NSPoint(x: 14, y: side - 34), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 18), .foregroundColor: NSColor.systemBlue])
    (String(text.prefix(1_500)) as NSString).draw(in: NSRect(x: 14, y: 10, width: side - 28, height: side - 54),
        withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular), .foregroundColor: NSColor.black])
    image.unlockFocus()
    return image
}

func render(_ attributed: NSAttributedString) -> NSImage {
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: side, height: side).fill()
    attributed.draw(with: NSRect(x: 16, y: 16, width: side - 32, height: side - 32), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    image.unlockFocus()
    return image
}

let ext = input.pathExtension.lowercased()
switch ext {
case "png", "jpg", "jpeg", "webp", "heic", "tiff", "tif", "gif", "bmp", "ico", "avif", "jxl", "jp2", "psd", "tga", "qoi":
    if let image = NSImage(contentsOf: input), image.isValid { save(image) } else { save(card("Not readable by ImageIO", title: ext.uppercased())) }
case "pdf", "ai":
    guard let document = PDFDocument(url: input), let page = document.page(at: 0) else { save(card("PDF didn't open", title: "PDF")); break }
    let image = page.thumbnail(of: NSSize(width: side, height: side), for: .cropBox)
    let framed = NSImage(size: image.size)
    framed.lockFocus(); NSColor.white.setFill(); NSRect(origin: .zero, size: image.size).fill(); image.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    ("\(document.pageCount)p" as NSString).draw(at: NSPoint(x: 4, y: 4), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.systemRed])
    framed.unlockFocus()
    save(framed)
case "mp4", "mov", "m4v", "mkv", "webm", "avi":
    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: input))
    generator.appliesPreferredTrackTransform = true
    generator.maximumSize = CGSize(width: side, height: side)
    let semaphore = DispatchSemaphore(value: 0)
    var frame: CGImage?
    generator.generateCGImageAsynchronously(for: CMTime(seconds: 0.5, preferredTimescale: 600)) { image, _, _ in frame = image; semaphore.signal() }
    semaphore.wait()
    if let frame { save(NSImage(cgImage: frame, size: .zero)) } else { save(card("No frame (AVFoundation can't decode \(ext))", title: ext.uppercased())) }
case "docx", "odt", "rtf", "html", "htm", "doc":
    if let text = try? NSAttributedString(url: input, options: [:], documentAttributes: nil) { save(render(text)) }
    else { save(card("Didn't open", title: ext.uppercased())) }
case "mp3", "m4a", "wav", "aac", "flac", "ogg", "opus", "caf":
    let asset = AVURLAsset(url: input)
    let semaphore = DispatchSemaphore(value: 0)
    var info = ""
    Task {
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
        let tracks = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0
        info = String(format: "duration %.2f s\naudio tracks %d\nbytes %d", duration, tracks, (try? input.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        semaphore.signal()
    }
    semaphore.wait()
    save(card(info, title: ext.uppercased()))
case "zip", "xlsx", "pptx", "epub", "ods":
    let list = Process()
    list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    list.arguments = ["-l", input.path]
    let pipe = Pipe(); list.standardOutput = pipe
    try? list.run(); list.waitUntilExit()
    save(card(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), title: ext.uppercased()))
default:
    let data = (try? Data(contentsOf: input)) ?? Data()
    save(card(String(decoding: data.prefix(4_000), as: UTF8.self), title: ext.uppercased()))
}
