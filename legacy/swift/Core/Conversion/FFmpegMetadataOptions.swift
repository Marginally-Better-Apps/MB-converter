import Foundation

/// Inserts FFmpeg flags for copying / clearing / re-applying metadata on the **output** file.
enum FFmpegMetadataOptions {

    /// Appends after input arguments, before output path.
    static func outputFlags(_ policy: MetadataExportPolicy) -> String {
        if policy.stripAll {
            return stripPrefix(policy: policy) + " -map_metadata -1 -map_chapters -1"
        }
        var parts = stripPrefix(policy: policy)
        parts += " -map_metadata -1 -map_chapters -1"
        for (key, value) in policy.retainedFormatTags.sorted(by: { $0.key < $1.key }) {
            parts += " -metadata \(key)=\(ffmpegQuoted(value))"
        }
        for (streamIndex, dict) in policy.retainedStreamTags.sorted(by: { $0.key < $1.key }) {
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                parts += " -metadata:s:\(streamIndex):\(key)=\(ffmpegQuoted(value))"
            }
        }
        return parts
    }

    private static func stripPrefix(policy: MetadataExportPolicy) -> String {
        var parts = ""
        for idx in policy.sourceStreamIndicesForTagStrip.sorted() {
            parts += " -map_metadata:s:\(idx) -1"
        }
        return parts
    }

    private static func ffmpegQuoted(_ value: String) -> String {
        FFmpegCommandRunner.quoted(value)
    }
}
