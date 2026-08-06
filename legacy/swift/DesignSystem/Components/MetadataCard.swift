import SwiftUI

struct MetadataCard: View {
    let title: String
    let rows: [MetadataRow]
    /// Single-column label/value pairs for narrow panels beside a preview.
    var compactList: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.text)

            if compactList {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.label)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                            Text(row.value)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)], spacing: 12) {
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.label)
                                .font(.caption)
                                .foregroundStyle(Theme.textMuted)
                            Text(row.value)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Theme.text)
                                .lineLimit(2)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Theme.accent, lineWidth: 1)
        )
    }

    init(title: String = "Metadata", media: MediaFile) {
        self.title = title
        self.rows = MetadataFormatter.rows(for: media)
        self.compactList = false
    }

    init(title: String, summaryFor media: MediaFile) {
        self.title = title
        self.rows = MetadataFormatter.summaryRows(for: media)
        self.compactList = true
    }

    init(title: String = "Output", result: ConversionResult) {
        self.title = title
        self.rows = MetadataFormatter.rows(for: result)
        self.compactList = false
    }
}

struct MetadataRow: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let value: String
}

enum MetadataFormatter {
    /// Core facts most users care about: name, kind, size, resolution, length—without codecs or bitrate.
    static func summaryRows(for media: MediaFile) -> [MetadataRow] {
        var rows: [MetadataRow] = [
            .init(
                label: "File type",
                value: fileTypeDisplay(
                    base: media.containerFormat.uppercased(),
                    category: media.category,
                    videoCodec: media.videoCodec
                )
            ),
            .init(label: "File size", value: bytes(media.sizeOnDisk))
        ]
        if let dimensions = media.dimensions {
            rows.append(.init(label: "Resolution", value: dimensionsText(dimensions)))
        }
        if let duration = media.duration {
            rows.append(.init(label: "Length", value: durationText(duration)))
        }
        if let bitrate = media.bitrate, media.category == .audio {
            rows.append(.init(label: "Bitrate", value: bitrateText(bitrate)))
        }
        if let ab = media.audioBitrate,
           media.category == .video,
           media.audioCodec != nil {
            rows.append(.init(label: "Audio bitrate", value: bitrateText(ab)))
        }
        return rows
    }

    static func rows(for media: MediaFile) -> [MetadataRow] {
        var rows: [MetadataRow] = [
            .init(label: "Filename", value: media.originalFilename),
            .init(label: "Format", value: formatDisplay(container: media.containerFormat, videoCodec: media.videoCodec, audioCodec: media.audioCodec)),
            .init(label: "Size", value: bytes(media.sizeOnDisk))
        ]

        if let dimensions = media.dimensions {
            rows.append(.init(label: "Dimensions", value: dimensionsText(dimensions)))
        }
        if let duration = media.duration {
            rows.append(.init(label: "Duration", value: durationText(duration)))
        }
        if let fps = media.fps, media.category == .video || media.category == .animatedImage {
            rows.append(.init(label: "FPS", value: String(format: "%.0f", fps)))
        }
        if let bitrate = media.bitrate, media.category == .video || media.category == .audio {
            let label = media.category == .video ? "Average bitrate" : "Bitrate"
            rows.append(.init(label: label, value: bitrateText(bitrate)))
        }
        if let ab = media.audioBitrate, media.category == .video, media.audioCodec != nil {
            rows.append(.init(label: "Audio bitrate", value: bitrateText(ab)))
        }

        return rows
    }

    static func rows(for result: ConversionResult) -> [MetadataRow] {
        var rows: [MetadataRow] = [
            .init(label: "Format", value: result.outputFormat.displayName),
            .init(label: "Size", value: bytes(result.sizeOnDisk))
        ]

        if let dimensions = result.dimensions {
            rows.append(.init(label: "Dimensions", value: dimensionsText(dimensions)))
        }
        if let duration = result.duration {
            rows.append(.init(label: "Duration", value: durationText(duration)))
        }
        if let fps = result.fps {
            rows.append(.init(label: "FPS", value: String(format: "%.0f", fps)))
        }
        if let bitrate = result.bitrate {
            let label = result.outputFormat.category == .video ? "Average bitrate" : "Bitrate"
            rows.append(.init(label: label, value: bitrateText(bitrate)))
        }
        if let ab = result.audioBitrate, result.outputFormat.category == .video {
            rows.append(.init(label: "Audio bitrate", value: bitrateText(ab)))
        }

        return rows
    }

    static func summaryRows(for result: ConversionResult) -> [MetadataRow] {
        var rows: [MetadataRow] = [
            .init(
                label: "File type",
                value: fileTypeDisplay(
                    base: result.outputFormat.fileExtension.uppercased(),
                    category: result.outputFormat.category,
                    videoCodec: result.videoCodec
                )
            ),
            .init(label: "File size", value: bytes(result.sizeOnDisk))
        ]

        if let dimensions = result.dimensions {
            rows.append(.init(label: "Resolution", value: dimensionsText(dimensions)))
        }
        if let duration = result.duration {
            rows.append(.init(label: "Length", value: durationText(duration)))
        }
        if let bitrate = result.bitrate, result.outputFormat.category == .video || result.outputFormat.category == .audio {
            let label = result.outputFormat.category == .video ? "Average bitrate" : "Bitrate"
            rows.append(.init(label: label, value: bitrateText(bitrate)))
        }
        if let ab = result.audioBitrate, result.outputFormat.category == .video {
            rows.append(.init(label: "Audio bitrate", value: bitrateText(ab)))
        }

        return rows
    }

    static func bytes(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = value < 1_000_000 ? [.useKB] : [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: value)
    }

    static func durationText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let remaining = total % 60
        return minutes > 0 ? "\(minutes)m \(remaining)s" : "0:\(String(format: "%02d", remaining))"
    }

    static func bitrateText(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return String(format: "%.0f kbps", Double(bitsPerSecond) / 1_000)
    }

    static func dimensionsText(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) x \(Int(size.height.rounded()))"
    }

    private static func formatDisplay(container: String, videoCodec: String?, audioCodec: String?) -> String {
        var parts = [formatNameDisplay(container)]
        if let videoCodec, !videoCodec.isEmpty {
            parts.append(codecDisplay(videoCodec))
        }
        if let audioCodec, !audioCodec.isEmpty {
            parts.append(codecDisplay(audioCodec))
        }
        return parts.joined(separator: " / ")
    }

    private static func codecDisplay(_ codec: String) -> String {
        switch codec.lowercased() {
        case "avc1": "H.264"
        case "hvc1", "hev1": "HEVC"
        case "mp4a": "AAC"
        default: codec.uppercased()
        }
    }

    private static func fileTypeDisplay(base: String, category: MediaCategory, videoCodec: String?) -> String {
        let displayBase = formatNameDisplay(base)
        guard category == .video,
              let videoCodec,
              !videoCodec.isEmpty else {
            return displayBase
        }
        return "\(displayBase) [\(codecDisplay(videoCodec))]"
    }

    private static func formatNameDisplay(_ value: String) -> String {
        switch value.lowercased() {
        case "jpg", "jpeg":
            "JPEG"
        case "heic":
            "HEIC"
        case "heif":
            "HEIF"
        case "png":
            "PNG"
        case "gif":
            "GIF"
        case "webp":
            "WebP"
        case "tif", "tiff":
            "TIFF"
        default:
            value.uppercased()
        }
    }
}
