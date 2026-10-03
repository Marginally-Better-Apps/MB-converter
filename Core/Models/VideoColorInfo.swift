import Foundation

/// Optional ffprobe-compatible color information. Missing fields remain unknown.
struct VideoColorInfo: Codable, Hashable, Sendable {
    var pixelFormat: String?
    var bitDepth: Int?
    var primaries: String?
    var transfer: String?
    var matrix: String?
    var range: String?
    var dolbyVisionProfile: Int?
    var dolbyVisionCompatibilityID: Int?

    var isHDR: Bool {
        transfer == "smpte2084" || transfer == "arib-std-b67"
            || dolbyVisionProfile != nil && dolbyVisionCompatibilityID != 2
    }

    private enum CodingKeys: String, CodingKey {
        case pixelFormat = "pix_fmt", bitDepth = "bit_depth"
        case primaries = "color_primaries", transfer = "color_transfer"
        case matrix = "color_space", range = "color_range"
        case dolbyVisionProfile = "dovi_profile"
        case dolbyVisionCompatibilityID = "dovi_compatibility_id"
    }
}
