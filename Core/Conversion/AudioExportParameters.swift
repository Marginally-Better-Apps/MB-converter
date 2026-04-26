import Foundation

/// Tuning and routing for **audio output** conversions (not embedded video audio).
enum AudioExportParameters {
    /// Practical AAC cap used by app controls and encode planning.
    static let maxAACKbps: Int = 320
}
