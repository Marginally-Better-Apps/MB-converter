import Foundation
import Testing
import UIKit
@testable import Converter

struct ImageToolTests {
    let image = TestSupport.makeImage(width: 400, height: 200)

    @Test func rotatesAndFlips() throws {
        let rotated = try #require(ImageToolkit.rotate(image, quarterTurns: 1))
        #expect(rotated.width == 200 && rotated.height == 400)
        #expect(ImageToolkit.rotate(image, quarterTurns: 4)?.width == 400)
        let angled = try #require(ImageToolkit.rotate(image, degrees: 45))
        #expect(angled.width > 400)
        #expect(ImageToolkit.flip(image, horizontal: true)?.width == 400)
    }

    @Test func resizesByMode() {
        #expect(ImageToolkit.targetSize(for: image, mode: .percent(50)) == CGSize(width: 200, height: 100))
        #expect(ImageToolkit.targetSize(for: image, mode: .maxDimension(100)) == CGSize(width: 100, height: 50))
        #expect(ImageToolkit.targetSize(for: image, mode: .maxDimension(1000)) == CGSize(width: 400, height: 200))
        #expect(ImageToolkit.targetSize(for: image, mode: .width(100)) == CGSize(width: 100, height: 50))
        #expect(ImageToolkit.resize(image, mode: .exact(width: 33, height: 77))?.height == 77)
    }

    @Test func cropsNormalized() throws {
        let cropped = try #require(ImageToolkit.crop(image, normalized: CGRect(x: 0.25, y: 0, width: 0.5, height: 0.5)))
        #expect(cropped.width == 200 && cropped.height == 100)
        let square = ImageToolkit.centeredCrop(aspect: 1, imageSize: CGSize(width: 400, height: 200))
        #expect(abs(square.width - 0.5) < 0.001 && square.height == 1)
    }

    @Test func encodesEveryFormat() throws {
        for format in ImageToolkit.OutputFormat.available where format != .eps {
            let data = try ImageToolkit.encode(image, as: format, quality: 0.8)
            let decoded = try ImageToolkit.load(data: data)
            // ICO entries are capped at 256 px.
            #expect(decoded.width == (format == .ico ? 256 : 400), "\(format) round trip failed")
        }
    }

    @Test func borderAndRoundCornersAddAlpha() throws {
        let bordered = try #require(ImageToolkit.addBorder(image, width: 10, colorHex: 0xFF0000))
        #expect(bordered.width == 420 && bordered.height == 220)
        let circle = try #require(ImageToolkit.roundCorners(image, percent: 100, makeSquare: true))
        #expect(circle.width == 200 && circle.height == 200)
        #expect(ImageToolkit.hasAlpha(circle))
        #expect(alpha(of: circle, x: 1, y: 1) == 0)
        #expect(alpha(of: circle, x: 100, y: 100) == 255)
    }

    @Test func filtersPreserveSize() {
        for result in [ImageToolkit.grayscale(image), ImageToolkit.blur(image, radius: 4), ImageToolkit.pixelate(image, blockSize: 10), ImageToolkit.sharpen(image), ImageToolkit.invert(image), ImageToolkit.sepia(image), ImageToolkit.adjust(image, brightness: 0.1, contrast: 1.2, saturation: 0.5)] {
            #expect(result?.width == 400 && result?.height == 200)
        }
        #expect(ImageToolkit.upscale(image, factor: 2)?.width == 800)
    }

    @Test func splitsAndCombines() throws {
        let tiles = ImageToolkit.split(TestSupport.makeImage(width: 301, height: 200), rows: 2, columns: 3)
        #expect(tiles.count == 6)
        #expect(tiles.map(\.width).reduce(0, +) == 301 * 2)
        let horizontal = try #require(ImageToolkit.combine([image, image], layout: .horizontal, spacing: 10))
        #expect(horizontal.width == 810 && horizontal.height == 200)
        let vertical = try #require(ImageToolkit.combine([image, TestSupport.makeImage(width: 200, height: 200)], layout: .vertical))
        #expect(vertical.width == 400 && vertical.height == 600)
        let grid = try #require(ImageToolkit.combine([image, image, image], layout: .grid))
        #expect(grid.width == grid.height)
    }

    @Test func makesAnimatedGIF() throws {
        let data = try ImageToolkit.animatedGIF([image, ImageToolkit.invert(image)!, image], frameDelay: 0.2)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        #expect(CGImageSourceGetCount(source) == 3)
    }

    @Test func qrCodesRoundTrip() throws {
        let code = try ImageToolkit.qrCode("https://marginally-better.app", size: 600)
        #expect(code.width >= 500)
        #expect(ImageToolkit.decodeQRCodes(in: code) == ["https://marginally-better.app"])
    }

    @Test func recognizesText() throws {
        let lines = try TextRecognizer.recognize(TestSupport.textImage("Hello Converter"), languages: ["en-US"])
        #expect(TextRecognizer.text(from: lines).contains("Hello Converter"))
    }

    @Test func captionsAndWatermarks() throws {
        let captioned = try #require(ImageToolkit.addText(image, ImageToolkit.Caption(text: "TOP TEXT", placement: .top)))
        #expect(captioned.width == 400)
        let logo = TestSupport.makeImage(width: 50, height: 50, color: .red, square: nil)
        #expect(ImageToolkit.overlay(image, logo: logo, relativeWidth: 0.2, opacity: 0.5, placement: .bottomRight)?.height == 200)
    }

    @Test func obscuresRegions() throws {
        let result = try #require(ImageToolkit.obscure(image, regions: [CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)], style: .box))
        #expect(result.width == 400)
    }

    @Test func backgroundRemovalWhenSupported() throws {
        do {
            let output = try ImageToolkit.replaceBackground(TestSupport.makeImage(width: 300, height: 300, color: .white, square: .systemRed), with: .transparent)
            #expect(output.width == 300)
        } catch is ImageToolkit.VisionError {
            // Subject lifting needs the Neural Engine; simulators may not support it.
        }
    }

    private func alpha(of image: CGImage, x: Int, y: Int) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -y, width: image.width, height: image.height))
        return pixel[3]
    }
}
