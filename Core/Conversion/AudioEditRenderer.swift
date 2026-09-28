import Foundation

enum AudioEditRenderer {
    static func arguments(sourceURL: URL, sourceDuration: Double, edits: AudioEditSettings) async throws -> String {
        try AudioExportParameters.validate(edits, sourceDuration: sourceDuration)
        var channelCount = 2
        var sampleRate = 44_100
        if edits.channels == .right || (!edits.preservePitch && edits.speed != 1) {
            let probe = await Task.detached(priority: .userInitiated) {
                FFmpegMediaProbe.probe(at: sourceURL)
            }.value
            try Task.checkCancellation()
            let audioStream = probe?.streams.first(where: { $0.codecType == "audio" })
            if edits.channels == .right {
                guard let channels = audioStream?.channels else {
                    throw ConversionError.invalidInput("The source audio channels could not be read.")
                }
                channelCount = channels
            }
            if !edits.preservePitch && edits.speed != 1 {
                guard let sourceRate = audioStream?.sampleRate, sourceRate > 0 else {
                    throw ConversionError.invalidInput("The source audio sample rate could not be read.")
                }
                sampleRate = sourceRate
            }
        }
        let filter = AudioExportParameters.filter(edits, sourceDuration: sourceDuration,
                                                 sourceChannels: channelCount, sourceSampleRate: sampleRate)
        let channels = edits.channels.outputChannelCount.map { " -ac \($0)" } ?? ""
        return " -ss \(AudioExportParameters.number(edits.trimStart)) -af \(FFmpegCommandRunner.quoted(filter))\(channels)"
    }

    /// A playable PCM preview supports the same inputs and effects as export,
    /// including formats AVPlayer cannot decode directly.
    static func preview(sourceURL: URL, sourceDuration: Double, edits: AudioEditSettings,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let output = TempStorage.url(for: .wav)
        do {
            let options = try await arguments(sourceURL: sourceURL, sourceDuration: sourceDuration, edits: edits)
            try Task.checkCancellation()
            let command = "-y -i \(FFmpegCommandRunner.quoted(sourceURL.path)) -vn -map 0:a:0 -c:a pcm_s16le\(options) -map_metadata -1 -map_chapters -1 \(FFmpegCommandRunner.quoted(output.path))"
            try await FFmpegCommandRunner().run(command, duration: edits.outputDuration(sourceDuration: sourceDuration),
                                               progress: progress)
            try Task.checkCancellation()
            TempStorage.allowAccessWhileLocked(at: output)
            return output
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }
}
