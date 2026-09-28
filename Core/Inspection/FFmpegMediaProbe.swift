import Foundation

#if canImport(MBFFmpegBridge)
import MBFFmpegBridge
#endif

/// Value-only metadata shared by the inspector and metadata editor.
/// The native probe is synchronous; callers must invoke it on a worker task.
enum FFmpegMediaProbe {
    struct Result: Decodable, Sendable {
        let format: Format?
        let streams: [Stream]

        private enum CodingKeys: String, CodingKey { case format, streams }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            format = try container.decodeIfPresent(Format.self, forKey: .format)
            streams = try container.decodeIfPresent([Stream].self, forKey: .streams) ?? []
        }
    }

    struct Format: Decodable, Sendable {
        let duration: Double?
        let bitRate: Int?
        let tags: [String: String]

        private enum CodingKeys: String, CodingKey {
            case duration, bitRate = "bit_rate", tags
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            duration = container.flexibleDouble(forKey: .duration)
            bitRate = container.flexibleInt(forKey: .bitRate)
            tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        }
    }

    struct Stream: Decodable, Sendable {
        let index: Int?
        let codecType: String?
        let codecName: String?
        let color: VideoColorInfo
        let width: Int?
        let height: Int?
        let averageFrameRate: String?
        let realFrameRate: String?
        let frameCount: Int?
        let duration: Double?
        let bitRate: Int?
        let channels: Int?
        let sampleRate: Int?
        let tags: [String: String]

        private enum CodingKeys: String, CodingKey {
            case index, codecType = "codec_type", codecName = "codec_name", width, height
            case averageFrameRate = "avg_frame_rate", realFrameRate = "r_frame_rate"
            case frameCount = "nb_frames", duration, bitRate = "bit_rate", tags, channels
            case sampleRate = "sample_rate"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            color = try VideoColorInfo(from: decoder)
            index = container.flexibleInt(forKey: .index)
            codecType = try container.decodeIfPresent(String.self, forKey: .codecType)
            codecName = try container.decodeIfPresent(String.self, forKey: .codecName)
            width = container.flexibleInt(forKey: .width)
            height = container.flexibleInt(forKey: .height)
            averageFrameRate = container.flexibleString(forKey: .averageFrameRate)
            realFrameRate = container.flexibleString(forKey: .realFrameRate)
            frameCount = container.flexibleInt(forKey: .frameCount)
            duration = container.flexibleDouble(forKey: .duration)
            bitRate = container.flexibleInt(forKey: .bitRate)
            channels = container.flexibleInt(forKey: .channels)
            sampleRate = container.flexibleInt(forKey: .sampleRate)
            tags = try container.decodeIfPresent([String: String].self, forKey: .tags) ?? [:]
        }
    }

    static func probe(at url: URL, timeoutMilliseconds: Int32 = 15_000) -> Result? {
        guard url.isFileURL else { return nil }
        #if canImport(MBFFmpegBridge)
        guard let json = url.path.withCString({ mbf_probe_json($0, max(1, timeoutMilliseconds)) }) else { return nil }
        defer { mbf_free_string(json) }
        let data = Data(bytes: json, count: strlen(json))
        return try? JSONDecoder().decode(Result.self, from: data)
        #else
        return nil
        #endif
    }
}

private extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decode(String.self, forKey: key) { return value }
        if let value = try? decode(Double.self, forKey: key), value.isFinite { return String(value) }
        return nil
    }

    func flexibleDouble(forKey key: Key) -> Double? {
        guard let string = flexibleString(forKey: key), let value = Double(string), value.isFinite else { return nil }
        return value
    }

    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decode(Int.self, forKey: key) { return value }
        if let value = try? decode(String.self, forKey: key) { return Int(value) }
        return nil
    }
}
