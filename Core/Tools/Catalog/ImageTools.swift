import CoreGraphics
import Foundation
import UIKit

extension ToolCatalog {
    static let imageInputs = Set(FileFormat.stillImages)

    static func formatOption(defaultValue: String = "original", transparentOnly: Bool = false) -> ToolOption {
        var choices = [ToolChoice("original", "Same as original")]
        // Every format this runtime can write (ImageIO, libwebp or ImageMagick), common ones first.
        let formats = ImageToolkit.OutputFormat.available.filter { !transparentOnly || $0.supportsTransparency }
        choices += formats.map { ToolChoice($0.rawValue, $0.label) }
        return ToolOption.choice("saveAs", "Save as", choices, default: defaultValue, section: "Output").advanced()
    }

    static let qualityOption = ToolOption.slider("quality", "Quality", range: 30 ... 100, default: 90, section: "Output", format: { "\(Int($0))%" }, visible: { values in
        ["original", "jpeg", "heic", "webp", "avif", "jxl", "jp2"].contains(values.string("saveAs"))
    }).advanced()

    /// Applies `transform` to every input image and writes results in the chosen format.
    @MainActor
    static func processImages(
        _ context: ToolContext,
        suffix: String,
        needsAlpha: Bool = false,
        transform: @escaping @Sendable (CGImage) throws -> CGImage
    ) async throws -> ToolOutput {
        guard !context.inputs.isEmpty else { throw DocumentError.invalidOption("Add an image.") }
        var urls: [URL] = []
        var before: Int64 = 0
        for (index, input) in context.inputs.enumerated() {
            let saveAs = context.options.string("saveAs")
            var format = ImageToolkit.OutputFormat(rawValue: saveAs) ?? ImageToolkit.OutputFormat(fileFormat: input.format) ?? .jpeg
            if format == .gif { format = .png } // Single frames only; animation lives in the GIF tools.
            if needsAlpha, !format.supportsTransparency { format = .png }
            let quality = context.options["quality"] == nil ? 0.9 : context.options.double("quality") / 100
            let url = input.url
            let data = try await background {
                let image = try ImageToolkit.load(url)
                return try ImageToolkit.encode(try transform(image), as: format, quality: quality)
            }
            urls.append(try ToolHelpers.write(data, suffix.isEmpty ? input.baseName : "\(input.baseName)-\(suffix)", format.fileExtension, context))
            before += input.byteCount
            context.progress.report(Double(index + 1) / Double(context.inputs.count))
        }
        let after = urls.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }.reduce(0, +)
        return ToolOutput(files: urls, summary: ToolHelpers.savings(before: before, after: after))
    }

    static func require(_ image: CGImage?, _ what: String) throws -> CGImage {
        guard let image else { throw DocumentError.writeFailed("Couldn't \(what) the image.") }
        return image
    }

    static let imageTools: [ToolDefinition] = [
        ToolDefinition(
            id: "image.convert", title: "Convert Images", summary: "JPG, PNG, HEIC, WebP, AVIF, JPEG XL, PSD, ICO and more",
            symbol: "arrow.triangle.2.circlepath", category: .images, input: .many(imageInputs, noun: "images"),
            options: [formatOption(defaultValue: "jpeg"), qualityOption, .toggle("strip", "Remove location and camera data", default: false, section: "Output")],
            keywords: ["heic to jpg", "png to jpg", "jpg to png", "webp to png", "webp to jpg", "png to webp", "jpg to webp", "tiff to jpg", "jpg to tiff", "heic to png", "bmp",
                       "psd to png", "psd to jpg", "png to ico", "ico", "favicon", "tga", "avif", "jpeg xl", "jxl", "jpeg 2000", "jp2", "qoi", "pcx", "dds", "png to eps", "eps", "ppm", "xpm", "hdr"], isFeatured: true, actionTitle: "Convert"
        ) { context in
            try await processImages(context, suffix: "") { $0 }
        },

        ToolDefinition(
            id: "image.compress", title: "Compress Images", summary: "Smaller photos with adjustable quality",
            symbol: "arrow.down.right.and.arrow.up.left", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .slider("quality", "Quality", range: 20 ... 95, default: 70, format: { "\(Int($0))%" }),
                .choice("maxSide", "Max size", [ToolChoice("0", "Original"), ToolChoice("3840", "4K"), ToolChoice("2048", "2048 px"), ToolChoice("1280", "1280 px")], default: "2048", segmented: true),
                .choice("saveAs", "Save as", [ToolChoice("jpeg", "JPEG"), ToolChoice("heic", "HEIC"), ToolChoice("webp", "WebP")], segmented: true)
            ],
            keywords: ["reduce", "shrink", "optimize", "smaller", "kb"], isFeatured: true, actionTitle: "Compress"
        ) { context in
            let maxSide = context.options.int("maxSide")
            return try await processImages(context, suffix: "compressed") { image in
                maxSide > 0 ? (ImageToolkit.resize(image, mode: .maxDimension(maxSide)) ?? image) : image
            }
        },

        ToolDefinition(
            id: "image.resize", title: "Resize Images", summary: "By percentage, longest side or exact pixels",
            symbol: "arrow.up.left.and.arrow.down.right", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("mode", "Resize by", [ToolChoice("percent", "Percent"), ToolChoice("max", "Longest side"), ToolChoice("exact", "Exact size")], segmented: true),
                .slider("percent", "Scale", range: 5 ... 200, default: 50, format: { "\(Int($0))%" }, visible: { $0.string("mode") == "percent" }),
                .stepper("max", "Longest side", range: 16 ... 12_000, default: 1_080, suffix: " px", visible: { $0.string("mode") == "max" }),
                .stepper("width", "Width", range: 1 ... 12_000, default: 1_080, suffix: " px", visible: { $0.string("mode") == "exact" }),
                .stepper("height", "Height", range: 1 ... 12_000, default: 1_080, suffix: " px", visible: { $0.string("mode") == "exact" }),
                .toggle("keepProportions", "Keep proportions", default: true, footnote: "Fits the photo inside this size without stretching it.", visible: { $0.string("mode") == "exact" }),
                formatOption(), qualityOption
            ],
            keywords: ["dimensions", "scale", "pixels", "smaller", "bigger"], actionTitle: "Resize"
        ) { context in
            let mode: ImageToolkit.ResizeMode = switch context.options.string("mode") {
            case "max": .maxDimension(context.options.int("max"))
            case "exact" where context.options.bool("keepProportions"): .fit(width: context.options.int("width"), height: context.options.int("height"))
            case "exact": .exact(width: context.options.int("width"), height: context.options.int("height"))
            default: .percent(context.options.double("percent"))
            }
            return try await processImages(context, suffix: "resized") { try require(ImageToolkit.resize($0, mode: mode), "resize") }
        },

        ToolDefinition(
            id: "image.crop", title: "Crop Image", summary: "Free-form or fixed aspect ratios",
            symbol: "crop", category: .images, input: .one(imageInputs, noun: "image"),
            options: [formatOption(), qualityOption], editor: .imageCrop,
            keywords: ["trim", "cut", "aspect ratio", "square", "instagram"], actionTitle: "Crop"
        ) { context in
            let rect = context.editor.cropRect ?? CGRect(x: 0, y: 0, width: 1, height: 1)
            return try await processImages(context, suffix: "cropped") { try require(ImageToolkit.crop($0, normalized: rect), "crop") }
        },

        ToolDefinition(
            id: "image.rotate", title: "Rotate & Flip", summary: "Turn, mirror or straighten photos",
            symbol: "rotate.right", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("turn", "Rotate", [ToolChoice("0", "None"), ToolChoice("1", "Right"), ToolChoice("2", "180°"), ToolChoice("3", "Left")], default: "1", segmented: true),
                .choice("flip", "Flip", [ToolChoice("none", "None"), ToolChoice("h", "Horizontal"), ToolChoice("v", "Vertical")], segmented: true),
                .slider("angle", "Straighten", range: -45 ... 45, step: 0.5, default: 0, format: { String(format: "%.1f°", $0) }),
                formatOption(), qualityOption
            ],
            keywords: ["turn", "mirror", "flip", "straighten", "orientation"], actionTitle: "Apply"
        ) { context in
            let turns = context.options.int("turn")
            let flip = context.options.string("flip")
            let angle = context.options.double("angle")
            return try await processImages(context, suffix: "rotated", needsAlpha: angle != 0) { image in
                var result = try require(ImageToolkit.rotate(image, quarterTurns: turns), "rotate")
                if flip != "none" { result = try require(ImageToolkit.flip(result, horizontal: flip == "h"), "flip") }
                if angle != 0 { result = try require(ImageToolkit.rotate(result, degrees: angle), "straighten") }
                return result
            }
        },

        ToolDefinition(
            id: "image.removebg", title: "Remove Background", summary: "Lift the subject, on device",
            symbol: "person.crop.rectangle", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("background", "Background", [ToolChoice("transparent", "Transparent"), ToolChoice("color", "Color"), ToolChoice("blur", "Blur")], segmented: true),
                .color("color", "Color", default: 0xFFFFFF, visible: { $0.string("background") == "color" }),
                .slider("blur", "Blur amount", range: 4 ... 60, default: 20, visible: { $0.string("background") == "blur" }),
                formatOption(defaultValue: "png", transparentOnly: false)
            ],
            keywords: ["cutout", "transparent", "subject", "remove bg", "change background", "blur background", "profile photo"], isFeatured: true, actionTitle: "Remove"
        ) { context in
            let style: ImageToolkit.BackgroundStyle = switch context.options.string("background") {
            case "color": .color(context.options.hex("color"))
            case "blur": .blur(radius: context.options.double("blur"))
            default: .transparent
            }
            let transparent = context.options.string("background") == "transparent"
            return try await processImages(context, suffix: "cutout", needsAlpha: transparent) { try ImageToolkit.replaceBackground($0, with: style) }
        },

        ToolDefinition(
            id: "image.blurfaces", title: "Blur Faces", summary: "Hide faces automatically for privacy",
            symbol: "face.dashed", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("style", "Style", ImageToolkit.FaceObscureStyle.allCases.map { ToolChoice($0.rawValue, $0.label) }, segmented: true),
                formatOption(), qualityOption
            ],
            keywords: ["anonymize", "privacy", "pixelate faces", "censor"], actionTitle: "Blur"
        ) { context in
            let style = context.options.choice("style", as: ImageToolkit.FaceObscureStyle.self, default: .blur)
            return try await processImages(context, suffix: "anonymized") { image in
                let faces = try ImageToolkit.faceRects(image)
                guard !faces.isEmpty else { throw DocumentError.empty("No faces were found.") }
                return try require(ImageToolkit.obscure(image, regions: faces, style: style), "blur")
            }
        },

        ToolDefinition(
            id: "image.ocr", title: "Image to Text", summary: "Copy text from photos and screenshots",
            symbol: "text.viewfinder", category: .images, input: .many(imageInputs, noun: "images"),
            options: [.choice("language", "Language", OCRLanguages.choices)],
            keywords: ["ocr", "extract text", "scan", "recognize", "live text"], isFeatured: true, actionTitle: "Recognize"
        ) { context in
            let languages = OCRLanguages.languages(for: context.options.string("language"))
            var texts: [String] = []
            for input in context.inputs {
                let url = input.url
                let text = try await background {
                    TextRecognizer.text(from: try TextRecognizer.recognize(try ImageToolkit.load(url, maxPixelSize: 4_096), languages: languages))
                }
                texts.append(context.inputs.count > 1 ? "— \(input.displayName) —\n\(text)" : text)
            }
            let combined = texts.joined(separator: "\n\n")
            guard combined.trimmingCharacters(in: .whitespacesAndNewlines).count > (context.inputs.count > 1 ? 10 * context.inputs.count : 0) else {
                throw DocumentError.empty("No text was found.")
            }
            let name = context.inputs.count == 1 ? try context.first.baseName : "Recognized text"
            return ToolOutput(files: [try ToolHelpers.write(Data(combined.utf8), name, "txt", context)], text: combined)
        },

        ToolDefinition(
            id: "image.text", title: "Add Text & Watermark", summary: "Type on photos: captions, labels and copyright marks",
            symbol: "textformat", category: .images, input: .many(imageInputs, noun: "images"),
            options: [formatOption(), qualityOption],
            editor: .textOverlay(.watermark),
            keywords: ["caption", "meme", "watermark", "copyright", "label", "write on image", "type on photo"], actionTitle: "Add Text",
            validate: { _, editor, _ in editor.texts(for: .watermark).allSatisfy(\.isEmpty) ? "Type your text on the photo" : nil }
        ) { context in
            let captions = context.editor.texts(for: .watermark).filter { !$0.isEmpty }.map(\.caption)
            guard !captions.isEmpty else { throw DocumentError.invalidOption("Type your text on the photo.") }
            return try await processImages(context, suffix: "text") { try require(ImageToolkit.addText($0, captions), "caption") }
        },

        ToolDefinition(
            id: "image.meme", title: "Meme Maker", summary: "Tap to type, drag text anywhere, add as many boxes as you like",
            symbol: "face.smiling", category: .images, input: .one(imageInputs, noun: "image"),
            editor: .textOverlay(.meme),
            keywords: ["funny", "caption", "impact", "top text", "bottom text"], actionTitle: "Make Meme",
            validate: { _, editor, _ in editor.texts(for: .meme).allSatisfy(\.isEmpty) ? "Tap a text box and type" : nil }
        ) { context in
            let captions = context.editor.texts(for: .meme).filter { !$0.isEmpty }.map(\.caption)
            guard !captions.isEmpty else { throw DocumentError.invalidOption("Tap a text box and type.") }
            return try await processImages(context, suffix: "meme") { try require(ImageToolkit.addText($0, captions), "caption") }
        },

        ToolDefinition(
            id: "image.border", title: "Add Border", summary: "Frame photos with color and rounded corners",
            symbol: "square.dashed", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .slider("width", "Width", range: 0 ... 25, step: 0.5, default: 4, format: { String(format: "%.1f%%", $0) }),
                .color("color", "Color", default: 0xFFFFFF),
                .slider("radius", "Corner radius", range: 0 ... 100, default: 0, format: { "\(Int($0))%" }),
                formatOption(defaultValue: "png")
            ],
            keywords: ["frame", "padding", "outline", "rounded"], actionTitle: "Apply"
        ) { context in
            let percent = context.options.double("width") / 100
            let color = context.options.hex("color")
            let radius = context.options.double("radius")
            return try await processImages(context, suffix: "border", needsAlpha: radius > 0) { image in
                let width = Int((Double(min(image.width, image.height)) * percent).rounded())
                return try require(ImageToolkit.addBorder(image, width: width, colorHex: color, cornerRadius: radius), "frame")
            }
        },

        ToolDefinition(
            id: "image.round", title: "Round Image", summary: "Rounded corners or a perfect circle",
            symbol: "circle", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("shape", "Shape", [ToolChoice("circle", "Circle"), ToolChoice("rounded", "Rounded")], segmented: true),
                .slider("radius", "Corner radius", range: 5 ... 100, default: 25, format: { "\(Int($0))%" }, visible: { $0.string("shape") == "rounded" }),
                formatOption(defaultValue: "png", transparentOnly: true)
            ],
            keywords: ["circle crop", "profile picture", "avatar", "rounded corners"], actionTitle: "Apply"
        ) { context in
            let circle = context.options.string("shape") == "circle"
            let radius = circle ? 100 : context.options.double("radius")
            return try await processImages(context, suffix: "rounded", needsAlpha: true) { try require(ImageToolkit.roundCorners($0, percent: radius, makeSquare: circle), "round") }
        },

        ToolDefinition(
            id: "image.adjust", title: "Filters & Adjust", summary: "Black & white, sepia, invert, brightness and more",
            symbol: "camera.filters", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("filter", "Filter", [ToolChoice("none", "None"), ToolChoice("mono", "Black & White"), ToolChoice("sepia", "Sepia"), ToolChoice("invert", "Invert")]),
                .slider("brightness", "Brightness", range: -50 ... 50, default: 0, section: "Adjust", format: { "\(Int($0))" }),
                .slider("contrast", "Contrast", range: 50 ... 150, default: 100, section: "Adjust", format: { "\(Int($0))%" }),
                .slider("saturation", "Saturation", range: 0 ... 200, default: 100, section: "Adjust", format: { "\(Int($0))%" }),
                formatOption(), qualityOption
            ],
            keywords: ["grayscale", "black and white", "greyscale", "sepia", "invert colors", "brightness", "contrast", "saturation"], actionTitle: "Apply"
        ) { context in
            let filter = context.options.string("filter")
            let brightness = context.options.double("brightness") / 100
            let contrast = context.options.double("contrast") / 100
            let saturation = context.options.double("saturation") / 100
            return try await processImages(context, suffix: "edited") { image in
                var result = image
                if brightness != 0 || contrast != 1 || saturation != 1 {
                    result = try require(ImageToolkit.adjust(result, brightness: brightness, contrast: contrast, saturation: saturation), "adjust")
                }
                switch filter {
                case "mono": result = try require(ImageToolkit.grayscale(result), "filter")
                case "sepia": result = try require(ImageToolkit.sepia(result), "filter")
                case "invert": result = try require(ImageToolkit.invert(result), "filter")
                default: break
                }
                return result
            }
        },

        ToolDefinition(
            id: "image.pixelate", title: "Pixelate & Blur", summary: "Soften or pixelate a whole image",
            symbol: "square.grid.3x3", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("effect", "Effect", [ToolChoice("pixelate", "Pixelate"), ToolChoice("blur", "Blur")], segmented: true),
                .slider("amount", "Amount", range: 1 ... 100, default: 20),
                formatOption(), qualityOption
            ],
            keywords: ["mosaic", "censor", "gaussian", "soften"], actionTitle: "Apply"
        ) { context in
            let effect = context.options.string("effect")
            let amount = context.options.double("amount")
            return try await processImages(context, suffix: effect) { image in
                let scale = Double(max(image.width, image.height)) / 1_000
                return try require(effect == "blur" ? ImageToolkit.blur(image, radius: amount * scale / 2) : ImageToolkit.pixelate(image, blockSize: amount * scale), "filter")
            }
        },

        ToolDefinition(
            id: "image.upscale", title: "Upscale & Sharpen", summary: "Enlarge up to 4× with crisp edges",
            symbol: "arrow.up.backward.and.arrow.down.forward", category: .images, input: .many(imageInputs, noun: "images"),
            options: [
                .choice("factor", "Scale", [ToolChoice("1", "1× (sharpen)"), ToolChoice("2", "2×"), ToolChoice("3", "3×"), ToolChoice("4", "4×")], default: "2", segmented: true),
                formatOption(), qualityOption
            ],
            keywords: ["enlarge", "increase resolution", "enhance", "unblur", "sharpen"], actionTitle: "Upscale"
        ) { context in
            let factor = context.options.double("factor")
            return try await processImages(context, suffix: factor > 1 ? "\(Int(factor))x" : "sharpened") { image in
                guard Double(image.width) * factor <= 12_000, Double(image.height) * factor <= 12_000 else {
                    throw DocumentError.invalidOption("That would exceed 12,000 pixels. Pick a smaller scale.")
                }
                return try require(factor > 1 ? ImageToolkit.upscale(image, factor: factor) : ImageToolkit.sharpen(image), "upscale")
            }
        },

        ToolDefinition(
            id: "image.split", title: "Split Image", summary: "Cut into a grid for carousels and tiles",
            symbol: "rectangle.split.3x3", category: .images, input: .one(imageInputs, noun: "image"),
            options: [
                .stepper("rows", "Rows", range: 1 ... 10, default: 1),
                .stepper("columns", "Columns", range: 1 ... 10, default: 3),
                formatOption(), qualityOption
            ],
            keywords: ["grid", "tiles", "carousel", "instagram", "slice"], actionTitle: "Split"
        ) { context in
            let input = try context.first
            let rows = context.options.int("rows")
            let columns = context.options.int("columns")
            var format = ImageToolkit.OutputFormat(rawValue: context.options.string("saveAs")) ?? ImageToolkit.OutputFormat(fileFormat: input.format) ?? .jpeg
            if format == .gif { format = .png } // Single frames only; animation lives in the GIF tools.
            let quality = context.options.double("quality") / 100
            let url = input.url
            let tiles = try await background {
                try ImageToolkit.split(try ImageToolkit.load(url), rows: rows, columns: columns).map { try ImageToolkit.encode($0, as: format, quality: quality) }
            }
            let urls = try tiles.enumerated().map { try ToolHelpers.write($0.element, "\(input.baseName)-\($0.offset + 1)", format.fileExtension, context) }
            return ToolOutput(files: urls, summary: "\(urls.count) tiles")
        },

        ToolDefinition(
            id: "image.combine", title: "Combine Images", summary: "Stitch side by side, stacked or as a grid collage",
            symbol: "rectangle.3.group", category: .images, input: .many(imageInputs, noun: "images", min: 2),
            options: [
                .choice("layout", "Layout", ImageToolkit.CombineLayout.allCases.map { ToolChoice($0.rawValue, $0.label) }, segmented: true),
                .slider("spacing", "Spacing", range: 0 ... 80, default: 0, format: { "\(Int($0)) px" }),
                .color("background", "Background", default: 0xFFFFFF),
                .choice("saveAs", "Save as", [ToolChoice("jpeg", "JPEG"), ToolChoice("png", "PNG"), ToolChoice("heic", "HEIC")], segmented: true)
            ],
            keywords: ["collage", "merge images", "stitch", "join photos", "side by side"], actionTitle: "Combine"
        ) { context in
            let layout = context.options.choice("layout", as: ImageToolkit.CombineLayout.self, default: .horizontal)
            let spacing = context.options.int("spacing")
            let backgroundHex = context.options.hex("background")
            let format = ImageToolkit.OutputFormat(rawValue: context.options.string("saveAs")) ?? .jpeg
            let urls = context.inputs.map(\.url)
            let data = try await background {
                let images = try urls.map { try ImageToolkit.load($0, maxPixelSize: 3_000) }
                guard let combined = ImageToolkit.combine(images, layout: layout, spacing: spacing, backgroundHex: backgroundHex) else {
                    throw DocumentError.writeFailed("Couldn't combine the images.")
                }
                return try ImageToolkit.encode(combined, as: format, quality: 0.9)
            }
            return ToolOutput(files: [try ToolHelpers.write(data, layout == .grid ? "Collage" : "Combined", format.fileExtension, context)])
        },

        ToolDefinition(
            id: "image.gif", title: "Images to GIF", summary: "Animate a sequence of photos",
            symbol: "photo.stack", category: .images, input: .many(imageInputs, noun: "images", min: 2),
            options: [
                .slider("delay", "Frame time", range: 0.05 ... 3, step: 0.05, default: 0.5, format: { String(format: "%.2f s", $0) }),
                .choice("size", "Size", [ToolChoice("480", "Small"), ToolChoice("800", "Medium"), ToolChoice("1280", "Large")], default: "800", segmented: true),
                .toggle("loop", "Loop forever", default: true)
            ],
            keywords: ["animated", "animation", "png to gif", "jpg to gif", "slideshow"], actionTitle: "Create GIF"
        ) { context in
            let delay = context.options.double("delay")
            let size = context.options.int("size")
            let loop = context.options.bool("loop") ? 0 : 1
            let urls = context.inputs.map(\.url)
            let data = try await background {
                try ImageToolkit.animatedGIF(try urls.map { try ImageToolkit.load($0, maxPixelSize: CGFloat(size)) }, frameDelay: delay, loopCount: loop, maxSide: size)
            }
            return ToolOutput(files: [try ToolHelpers.write(data, "Animation", "gif", context)])
        },

        ToolDefinition(
            id: "image.animated", title: "GIF ⇄ WebP", summary: "Convert animations between GIF and animated WebP",
            symbol: "sparkles.rectangle.stack", category: .images, input: .one([.gif, .webp], noun: "GIF or WebP"),
            options: [
                .choice("target", "Convert to", [ToolChoice("webp", "Animated WebP"), ToolChoice("gif", "GIF")], segmented: true),
                .choice("width", "Width", [ToolChoice("0", "Original"), ToolChoice("480", "480"), ToolChoice("320", "320")], segmented: true),
                .slider("quality", "Quality", range: 30 ... 100, default: 80, format: { "\(Int($0))%" }, visible: { $0.string("target") == "webp" })
            ],
            keywords: ["gif to webp", "webp to gif", "animated", "sticker", "smaller gif"], actionTitle: "Convert"
        ) { context in
            let input = try context.first
            let format = MediaToolkit.AnimationFormat(rawValue: context.options.string("target")) ?? .webp
            var width = context.options.int("width")
            if width == 0 {
                width = (try? Magick.identify(input.url).width) ?? CGImageSourceCreateWithURL(input.url as CFURL, nil)
                    .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }
                    .flatMap { $0[kCGImagePropertyPixelWidth] as? Int } ?? 480
            }
            let url = context.outputURL(input.baseName, format.fileExtension)
            let progress = context.progress
            try await MediaToolkit.makeAnimation(input.url, start: 0, duration: nil, fps: 25, width: width, format: format,
                                                 quality: context.options.int("quality"), output: url) { progress.report($0) }
            return ToolOutput(files: [url], summary: ToolHelpers.savings(before: input.byteCount, after: ToolOutputFile(url: url).byteCount))
        },

        ToolDefinition(
            id: "image.metadata", title: "Remove Photo Metadata", summary: "Strip location, camera and date info",
            symbol: "location.slash", category: .images, input: .many(imageInputs, noun: "images"),
            options: [formatOption(), qualityOption],
            keywords: ["exif", "gps", "privacy", "location", "view metadata"], actionTitle: "Remove"
        ) { context in
            var report: [String] = []
            for input in context.inputs {
                let properties = ImageToolkit.properties(of: input.url)
                var found: [String] = []
                if properties[kCGImagePropertyGPSDictionary as String] != nil { found.append("location") }
                if let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any], !exif.isEmpty { found.append("camera details") }
                if properties[kCGImagePropertyTIFFDictionary as String] != nil { found.append("device info") }
                report.append("\(input.displayName): \(found.isEmpty ? "no private data found" : "removed " + found.joined(separator: ", "))")
            }
            var output = try await processImages(context, suffix: "clean") { $0 }
            output.summary = report.count == 1 ? report[0].components(separatedBy: ": ").last?.capitalizedFirst : "\(report.count) images cleaned"
            output.text = report.count > 1 ? report.joined(separator: "\n") : nil
            return output
        }
    ]
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
