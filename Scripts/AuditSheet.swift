// AuditSheet <out.png> <images...>: labeled contact sheet on a checkerboard (shows transparency).
import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())
let output = arguments[0], files = Array(arguments.dropFirst())
let cell = Int(ProcessInfo.processInfo.environment["AUDIT_CELL"] ?? "") ?? 300, label = 34, columns = min(5, max(1, files.count)), rows = (files.count + columns - 1) / columns
let width = columns * cell, height = rows * (cell + label)
let image = NSImage(size: NSSize(width: width, height: height))
image.lockFocus()
NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
for (index, file) in files.enumerated() {
    let x = (index % columns) * cell, top = height - (index / columns) * (cell + label)
    let box = NSRect(x: x + 6, y: top - label - cell + 6, width: cell - 12, height: cell - 12)
    for row in 0 ..< 12 { for column in 0 ..< 12 where (row + column) % 2 == 0 {
        NSColor(white: 0.88, alpha: 1).setFill()
        NSRect(x: box.minX + CGFloat(column) * box.width / 12, y: box.minY + CGFloat(row) * box.height / 12, width: box.width / 12, height: box.height / 12).fill()
    } }
    if let picture = NSImage(contentsOfFile: file) {
        let scale = min(box.width / picture.size.width, box.height / picture.size.height)
        let size = NSSize(width: picture.size.width * scale, height: picture.size.height * scale)
        picture.draw(in: NSRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2, width: size.width, height: size.height))
    }
    let name = (file as NSString).lastPathComponent.replacingOccurrences(of: ".png", with: "")
    (name as NSString).draw(in: NSRect(x: x + 6, y: top - label + 4, width: cell - 12, height: label - 4),
                            withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.black])
}
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
