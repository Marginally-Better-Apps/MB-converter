import Foundation
import PDFKit
import UIKit
@testable import Converter

final class BundleToken {}

enum TestSupport {
    static func fixture(_ name: String) throws -> URL {
        guard let url = Bundle(for: BundleToken.self).url(forResource: name, withExtension: nil) else {
            throw DocumentError.unreadable("Missing fixture \(name)")
        }
        return url
    }

    static func tempURL(_ ext: String) -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tests", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
    }

    static func makePDF(pages: Int, size: CGSize = CGSize(width: 612, height: 792), body: String? = nil, picture: Bool = false) -> PDFDocument {
        SelfTestFixtures.makePDF(pages: pages, size: size, body: body, picture: picture)
    }

    static func transparentPicture() -> UIImage { SelfTestFixtures.transparentPicture() }

    static func pageTitles(_ document: PDFDocument) -> [String] {
        (0 ..< document.pageCount).map { index in
            document.page(at: index)?.string?.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
        }
    }

    static func makeImage(width: Int, height: Int, color: UIColor = .systemBlue, square: UIColor? = .white) -> CGImage {
        SelfTestFixtures.makeImage(width: width, height: height, color: color, square: square)
    }

    static func writeImage(_ image: CGImage, format: ImageToolkit.OutputFormat = .png) throws -> URL {
        let url = tempURL(format.fileExtension)
        try ImageToolkit.encode(image, as: format).write(to: url)
        return url
    }

    static func textImage(_ text: String, size: CGSize = CGSize(width: 1200, height: 300)) -> CGImage {
        SelfTestFixtures.textImage(text, size: size)
    }

    static var sampleDocument: RichDocument { SelfTestFixtures.sampleDocument }
}
