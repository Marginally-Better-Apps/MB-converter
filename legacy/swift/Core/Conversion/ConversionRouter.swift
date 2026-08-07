import Foundation

enum ConversionRouter {
    static func converter(for input: MediaFile, config: ConversionConfig) throws -> Converter {
        guard FormatMatrix.allowedOutputs(for: input.category).contains(config.outputFormat) else {
            throw ConversionError.unsupportedConversion
        }

        switch (input.category, config.outputFormat.category) {
        case (.video, .video):
            return VideoConverter()
        case (.video, .audio), (.audio, .audio):
            return AudioConverter()
        case (.image, .image):
            return ImageConverter()
        case (.animatedImage, .video), (.animatedImage, .image):
            return AnimatedImageConverter()
        default:
            throw ConversionError.unsupportedConversion
        }
    }
}
