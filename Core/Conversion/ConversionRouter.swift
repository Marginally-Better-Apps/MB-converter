import Foundation

enum ConversionRouter {
    static func converter(for input: MediaFile, config: ConversionConfig) throws -> Converter {
        guard FormatMatrix.allowedOutputs(for: input.category).contains(config.outputFormat) else {
            throw ConversionError.unsupportedConversion
        }

        if config.outputFormat.category == .archive { return ArchiveConverter() }
        if input.category == .data { return DataConverter() }
        if input.category == .document || config.outputFormat.category == .document { return DocumentConverter() }

        switch (input.category, config.outputFormat.category) {
        case (.video, .video):
            return VideoConverter()
        case (.video, .audio), (.audio, .audio):
            return AudioConverter()
        case (.image, .image), (.video, .image):
            return ImageConverter()
        case (.animatedImage, .video), (.animatedImage, .image):
            return AnimatedImageConverter()
        default:
            throw ConversionError.unsupportedConversion
        }
    }
}
