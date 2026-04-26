import Foundation
import ImageIO
import CoreGraphics

#if canImport(ffmpegkit)
import ffmpegkit
#endif

/// Discovered tags for the metadata editor (container or still-image EXIF family).
struct DiscoveredMetadataTag: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let value: String
    /// Raw key name as written to FFmpeg or ImageIO (`ARTIST`, `Model`, `DateTime`, …).
    let tagKey: String
    let kind: Kind
    /// From ffprobe `StreamInformation.getType()` (`"video"`, `"audio"`, …); only for stream-tagged fields.
    var ffprobeStreamType: String? = nil
    /// Synthetic low-level rows default to removed so they do not write empty structural tags.
    var defaultIsRemoved = false

    enum Kind: Hashable, Sendable {
        case ffprobeFormat
        case ffprobeStream(index: Int)
        case image(ImageMetadataEntry)
    }
}

enum MediaTagDiscovery {
    static func discover(for media: MediaFile) async -> [DiscoveredMetadataTag] {
        switch media.category {
        case .image:
            return await Task.detached(priority: .userInitiated) {
                discoverImageTags(at: media.url)
            }.value
        case .video, .audio, .animatedImage:
            #if canImport(ffmpegkit)
            return await Task.detached(priority: .userInitiated) {
                discoverFfprobeTags(at: media.url)
            }.value
            #else
            return []
            #endif
        }
    }

    // MARK: - Image (ImageIO)

    private static func discoverImageTags(at url: URL) -> [DiscoveredMetadataTag] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return []
        }
        var tags: [DiscoveredMetadataTag] = []
        func addSection(
            _ scope: ImageMetadataScope,
            _ prefix: String,
            _ dict: [String: Any]?
        ) {
            guard let dict else { return }
            for (key, value) in dict {
                guard let string = metadataString(value) else { continue }
                let k = String(describing: key)
                if shouldSkipImageKey(scope: scope, key: k) { continue }
                let id = "img:\(scope.rawValue):\(k)"
                let label = "\(prefix) · \(k)"
                let entry = ImageMetadataEntry(
                    scope: scope,
                    dictionaryKey: k,
                    value: string,
                    imagePropertyKey: "\(scope.rawValue)|\(k)"
                )
                tags.append(
                    DiscoveredMetadataTag(
                        id: id,
                        label: label,
                        value: string,
                        tagKey: k,
                        kind: .image(entry)
                    )
                )
            }
        }

        let tiff = props[kCGImagePropertyTIFFDictionary] as? [String: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [String: Any]

        addSection(.tiff, "TIFF", tiff)
        addSection(.exif, "EXIF", exif)
        addSection(.gps, "GPS", props[kCGImagePropertyGPSDictionary] as? [String: Any])
        addSection(.iptc, "IPTC", props[kCGImagePropertyIPTCDictionary] as? [String: Any])
        if let png = props[kCGImagePropertyPNGDictionary] as? [String: Any] {
            addSection(.png, "PNG", png)
        }
        addSection(.xmp, "XMP", props["{XMP}" as CFString] as? [String: Any])
        addSyntheticAdvancedRows(
            to: &tags,
            props: props,
            tiff: tiff,
            exif: exif
        )

        tags.sort { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }
        return dedupeConflictingLocationTags(tags)
    }

    private static func addSyntheticAdvancedRows(
        to tags: inout [DiscoveredMetadataTag],
        props: [CFString: Any],
        tiff: [String: Any]?,
        exif: [String: Any]?
    ) {
        let existingIDs = Set(tags.compactMap { tag -> String? in
            if case .image(let entry) = tag.kind {
                return entry.imagePropertyKey.lowercased()
            }
            return nil
        })

        func add(
            scope: ImageMetadataScope,
            prefix: String,
            key: String,
            value: Any?,
            fallbackValue: String = ""
        ) {
            let imagePropertyKey = "\(scope.rawValue)|\(key)"
            guard !existingIDs.contains(imagePropertyKey.lowercased()) else { return }
            let string = value.flatMap(metadataString) ?? fallbackValue
            let entry = ImageMetadataEntry(
                scope: scope,
                dictionaryKey: key,
                value: string,
                imagePropertyKey: imagePropertyKey
            )
            tags.append(
                DiscoveredMetadataTag(
                    id: "img:advanced:\(imagePropertyKey)",
                    label: "\(prefix) · \(key)",
                    value: string,
                    tagKey: key,
                    kind: .image(entry),
                    defaultIsRemoved: string.isEmpty
                )
            )
        }

        add(scope: .exif, prefix: "EXIF", key: "ExifByteOrder", value: props["ExifByteOrder" as CFString])
        add(scope: .tiff, prefix: "TIFF", key: "XResolution", value: tiff?["XResolution"])
        add(scope: .tiff, prefix: "TIFF", key: "YResolution", value: tiff?["YResolution"])
        add(scope: .tiff, prefix: "TIFF", key: "ResolutionUnit", value: tiff?["ResolutionUnit"])
        add(scope: .tiff, prefix: "TIFF", key: "YCbCrPositioning", value: tiff?["YCbCrPositioning"])
        add(scope: .exif, prefix: "EXIF", key: "ExifVersion", value: exif?["ExifVersion"])
        add(scope: .exif, prefix: "EXIF", key: "ComponentsConfiguration", value: exif?["ComponentsConfiguration"])
        add(scope: .exif, prefix: "EXIF", key: "FlashpixVersion", value: exif?["FlashpixVersion"])
        add(scope: .exif, prefix: "EXIF", key: "ColorSpace", value: exif?["ColorSpace"])
        add(scope: .exif, prefix: "EXIF", key: "PixelXDimension", value: exif?["PixelXDimension"])
        add(scope: .exif, prefix: "EXIF", key: "PixelYDimension", value: exif?["PixelYDimension"])
        add(scope: .exif, prefix: "EXIF", key: "SceneCaptureType", value: exif?["SceneCaptureType"])
        add(scope: .tiff, prefix: "TIFF", key: "Compression", value: tiff?["Compression"])
        add(scope: .exif, prefix: "EXIF", key: "ThumbnailOffset", value: exif?["ThumbnailOffset"])
        add(scope: .exif, prefix: "EXIF", key: "ThumbnailLength", value: exif?["ThumbnailLength"])
        add(scope: .exif, prefix: "EXIF", key: "ThumbnailImage", value: nil, fallbackValue: thumbnailValue(from: props))
        add(scope: .xmp, prefix: "XMP", key: "XMPToolkit", value: props["XMPToolkit" as CFString])
    }

    private static func shouldSkipImageKey(scope: ImageMetadataScope, key: String) -> Bool {
        let k = key.lowercased()
        if k == "{pointsize}" || k == "{width}" || k == "{height}" { return true }
        if scope == .iptc, k == "objectdata" { return true }
        return false
    }

    private static func metadataString(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s.isEmpty ? nil : s
        case let n as NSNumber:
            return n.stringValue
        case let data as Data:
            return "Binary data \(data.count) bytes"
        case let i as Int:
            return String(i)
        case let d as Double:
            return String(d)
        default:
            return String(describing: value)
        }
    }

    private static func thumbnailValue(from props: [CFString: Any]) -> String {
        guard let thumbnail = props["{Thumbnail}" as CFString] as? [String: Any],
              !thumbnail.isEmpty else {
            return ""
        }
        return "Embedded thumbnail"
    }

    // MARK: - FFprobe (FFmpegKit)

    #if canImport(ffmpegkit)
    private static func discoverFfprobeTags(at url: URL) -> [DiscoveredMetadataTag] {
        let session = FFprobeKit.getMediaInformation(url.path, withTimeout: 15_000)
        guard let info = session?.getMediaInformation() else { return [] }

        var tags: [DiscoveredMetadataTag] = []

        if let formatTags = tagDictionary(from: info.getTags()) {
            for (key, value) in formatTags.sorted(by: { $0.key < $1.key }) {
                if shouldSkipFfprobeKey(key) { continue }
                let id = "fmt:\(key)"
                tags.append(
                    DiscoveredMetadataTag(
                        id: id,
                        label: key,
                        value: value,
                        tagKey: key,
                        kind: .ffprobeFormat
                    )
                )
            }
        }

        let streams = info.getStreams() ?? []
        for item in streams {
            guard let stream = item as? StreamInformation else { continue }
            let index: Int
            if let n = stream.getIndex() {
                index = n.intValue
            } else {
                index = 0
            }
            let typeLabel = (stream.getType() ?? "?").uppercased()
            let mediaType = stream.getType()?.lowercased()
            guard let streamTags = tagDictionary(from: stream.getTags()) else { continue }
            for (key, value) in streamTags.sorted(by: { $0.key < $1.key }) {
                if shouldSkipFfprobeKey(key) { continue }
                let id = "stm:\(index):\(key)"
                let label = "\(typeLabel) stream \(index) · \(key)"
                tags.append(
                    DiscoveredMetadataTag(
                        id: id,
                        label: label,
                        value: value,
                        tagKey: key,
                        kind: .ffprobeStream(index: index),
                        ffprobeStreamType: mediaType
                    )
                )
            }
        }

        return tags
    }

    private static func shouldSkipFfprobeKey(_ key: String) -> Bool {
        let k = key.uppercased()
        // Duration / timecode noise we already show elsewhere; encoder line is often huge.
        if k == "DURATION" || k.hasPrefix("DURATION-") { return true }
        if k == "ENCODER" { return true }
        if k == "VENDOR_ID" { return true }
        return false
    }

    /// QuickTime files can expose both a generic `location` tag and an ISO6709 tag.
    /// The generic tag is often transformed/low-precision and can disagree with ISO6709.
    /// Prefer ISO6709 and drop the ambiguous generic aliases.
    private static func dedupeConflictingLocationTags(_ tags: [DiscoveredMetadataTag]) -> [DiscoveredMetadataTag] {
        let keys = Set(tags.map { normalizedLocationKey($0.tagKey) })
        let hasISO6709 = keys.contains("com.apple.quicktime.location.iso6709") || keys.contains("iso6709")
        guard hasISO6709 else { return tags }

        let genericAliases: Set<String> = [
            "location",
            "com.apple.quicktime.location"
        ]
        return tags.filter { !genericAliases.contains(normalizedLocationKey($0.tagKey)) }
    }

    private static func normalizedLocationKey(_ key: String) -> String {
        key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func tagDictionary(from raw: Any?) -> [String: String]? {
        guard let raw else { return nil }
        if let d = raw as? [String: String] {
            return d
        }
        if let d = raw as? [String: Any] {
            var out: [String: String] = [:]
            for (k, v) in d {
                if let s = metadataString(v) { out[k] = s }
            }
            return out
        }
        if let d = raw as? NSDictionary {
            var out: [String: String] = [:]
            for case let (k, v) as (String, Any) in d {
                if let s = metadataString(v) { out[k] = s }
            }
            return out
        }
        return nil
    }
    #endif
}
