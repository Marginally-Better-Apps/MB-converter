import Foundation

/// Inserts adapter options for copying / clearing / re-applying output metadata.
enum FFmpegMetadataOptions {

    /// Appends after input arguments, before output path.
    static func outputFlags(_ policy: MetadataExportPolicy) -> String {
        if policy.stripAll {
            return stripPrefix(policy: policy) + " -map_metadata -1 -map_chapters -1"
        }
        var parts = stripPrefix(policy: policy)
        parts += " -map_metadata -1 -map_chapters -1"
        for (key, value) in policy.retainedFormatTags.sorted(by: { $0.key < $1.key }) {
            // Tag names can contain spaces and quotes too; quote the entire
            // assignment so the command runner passes it as one argument.
            parts += " -metadata \(ffmpegQuoted("\(key)=\(value)"))"
        }
        for (streamIndex, dict) in policy.retainedStreamTags.sorted(by: { $0.key < $1.key }) {
            for (key, value) in dict.sorted(by: { $0.key < $1.key }) {
                // The policy stores input indices. The native adapter resolves
                // these after selecting output streams (audio 1 can become 0).
                parts += " -metadata_input:s:\(streamIndex) \(ffmpegQuoted("\(key)=\(value)"))"
            }
        }
        return parts
    }

    private static func stripPrefix(policy: MetadataExportPolicy) -> String {
        var parts = ""
        for idx in policy.sourceStreamIndicesForTagStrip.sorted() {
            parts += " -map_metadata_input:s:\(idx) -1"
        }
        return parts
    }

    private static func ffmpegQuoted(_ value: String) -> String {
        FFmpegCommandRunner.quoted(value)
    }
}
