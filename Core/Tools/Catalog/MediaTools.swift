import Foundation
import UIKit

extension ToolCatalog {
    static let videoInputs: Set<FileFormat> = [.mp4, .mov, .m4v, .mkv, .webm, .avi]
    static let audioInputs: Set<FileFormat> = [.mp3, .m4a, .wav, .aac, .flac, .ogg, .opus]

    /// Runs `operation` for every input, writing one output per input.
    @MainActor
    static func runMedia(
        _ context: ToolContext,
        suffix: String,
        ext: @escaping (ToolInputFile, MediaToolkit.Probe) -> String,
        operation: @escaping (ToolInputFile, MediaToolkit.Probe, URL, @escaping @Sendable (Double) -> Void) async throws -> Void
    ) async throws -> ToolOutput {
        var urls: [URL] = []
        for (index, input) in context.inputs.enumerated() {
            let probe = try await MediaToolkit.probe(input.url)
            let url = context.outputURL("\(input.baseName)-\(suffix)", ext(input, probe))
            let count = Double(context.inputs.count)
            let progress = context.progress
            try await operation(input, probe, url) { fraction in
                progress.report((Double(index) + fraction) / count)
            }
            try MediaToolkit.verifyOutput(url)
            urls.append(url)
        }
        let before = context.inputs.map(\.byteCount).reduce(0, +)
        let after = urls.compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int64 }.reduce(0, +)
        return ToolOutput(files: urls, summary: "\(before.formattedBytes) → \(after.formattedBytes)")
    }

    static func videoExtension(for input: ToolInputFile) -> String {
        input.url.pathExtension.lowercased() == "mov" ? "mov" : "mp4"
    }

    /// Video → GIF/animated WebP with FFmpeg's palette encoder; falls back to AVFoundation frames for GIF.
    @MainActor
    static func runAnimation(_ context: ToolContext, format: MediaToolkit.AnimationFormat) async throws -> ToolOutput {
        let input = try context.first
        let probe = try await MediaToolkit.probe(input.url)
        var range = context.editor.range ?? (0, min(probe.duration, 6))
        if range.end - range.start > 30 { range.end = range.start + 30 }
        let duration = max(0.1, range.end - range.start)
        let fps = context.options.int("fps")
        let width = context.options.int("width")
        let url = context.outputURL(input.baseName, format.fileExtension)
        let progress = context.progress
        do {
            try await MediaToolkit.makeAnimation(input.url, start: range.start, duration: duration, fps: fps, width: width,
                                                 format: format, quality: context.options["quality"] == nil ? 75 : context.options.int("quality"),
                                                 output: url) { progress.report($0) }
        } catch where format == .gif && !(error is CancellationError) {
            let data = try await MediaToolkit.makeGIF(input.url, start: range.start, duration: duration, fps: fps, width: width)
            try data.write(to: url)
        }
        return ToolOutput(files: [url], summary: ToolOutputFile(url: url).byteCount.formattedBytes)
    }

    static func mediaConverter(_ id: ToolID, _ title: String, summary: String, symbol: String, category: ToolCategory, inputs: Set<FileFormat>, keywords: [String], featured: Bool = false) -> ToolDefinition {
        ToolDefinition(
            id: id, title: title, summary: summary, symbol: symbol, category: category,
            input: .one(inputs, noun: category == .audio ? "audio file" : (category == .images ? "image" : "video")),
            keywords: keywords, isFeatured: featured, opensMediaConverter: true, actionTitle: "Continue"
        ) { _ in
            throw DocumentError.invalidOption("This tool opens the converter screen.")
        }
    }

    static let videoTools: [ToolDefinition] = [
        mediaConverter("video.compress", "Compress Video", summary: "Hit a target size for messages and email", symbol: "arrow.down.right.and.arrow.up.left", category: .video, inputs: videoInputs, keywords: ["reduce", "shrink", "smaller", "discord", "whatsapp", "8mb", "25mb"], featured: true),
        mediaConverter("video.convert", "Convert Video", summary: "MP4, MOV and HEVC from almost anything", symbol: "arrow.triangle.2.circlepath", category: .video, inputs: videoInputs, keywords: ["mov to mp4", "mkv to mp4", "webm to mp4", "avi to mp4", "mp4 to mov", "hevc", "h264"]),
        mediaConverter("video.extractaudio", "Extract Audio", summary: "Save a video's soundtrack as M4A, WAV or AAC", symbol: "waveform.badge.plus", category: .video, inputs: videoInputs, keywords: ["mp4 to mp3", "video to audio", "mov to mp3", "mp4 to wav", "soundtrack"]),

        ToolDefinition(
            id: "video.trim", title: "Trim Video", summary: "Cut the start and end of a clip",
            symbol: "timeline.selection", category: .video, input: .one(videoInputs, noun: "video"),
            options: [ToolOption.toggle("precise", "Exact cut (slower)", default: true, footnote: "Off is instant and lossless but may start up to a few seconds early.").advanced()],
            editor: .mediaRange, keywords: ["cut", "clip", "shorten", "crop length"], isFeatured: true, actionTitle: "Trim"
        ) { context in
            let precise = context.options.bool("precise")
            return try await runMedia(context, suffix: "trimmed", ext: { input, _ in videoExtension(for: input) }) { input, probe, url, progress in
                let range = context.editor.range ?? (0, probe.duration)
                guard range.end - range.start > 0.05 else { throw DocumentError.invalidOption("Choose a longer range.") }
                try await MediaToolkit.trim(input.url, start: range.start, end: range.end, precise: precise, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "video.gif", title: "Video to GIF", summary: "Turn a moment into a shareable GIF",
            symbol: "sparkles.rectangle.stack", category: .video, input: .one(videoInputs, noun: "video"),
            options: [
                .choice("fps", "Frame rate", [ToolChoice("8", "8 fps"), ToolChoice("12", "12 fps"), ToolChoice("15", "15 fps"), ToolChoice("24", "24 fps")], default: "12", segmented: true),
                .choice("width", "Width", [ToolChoice("320", "320"), ToolChoice("480", "480"), ToolChoice("640", "640"), ToolChoice("800", "800")], default: "480", segmented: true)
            ],
            editor: .mediaRange, keywords: ["mp4 to gif", "mov to gif", "animated", "convert to gif"], isFeatured: true, actionTitle: "Make GIF"
        ) { context in
            try await runAnimation(context, format: .gif)
        },

        ToolDefinition(
            id: "video.webp", title: "Video to WebP", summary: "Animated WebP: smaller than GIF, full color",
            symbol: "photo.stack", category: .video, input: .one(videoInputs, noun: "video"),
            options: [
                .choice("fps", "Frame rate", [ToolChoice("10", "10 fps"), ToolChoice("15", "15 fps"), ToolChoice("24", "24 fps")], default: "15", segmented: true),
                .choice("width", "Width", [ToolChoice("320", "320"), ToolChoice("480", "480"), ToolChoice("640", "640"), ToolChoice("800", "800")], default: "480", segmented: true),
                .slider("quality", "Quality", range: 30 ... 100, default: 75, format: { "\(Int($0))%" })
            ],
            editor: .mediaRange, keywords: ["mp4 to webp", "animated webp", "video to webp", "sticker"], actionTitle: "Make WebP"
        ) { context in
            try await runAnimation(context, format: .webp)
        },

        ToolDefinition(
            id: "video.mute", title: "Mute Video", summary: "Remove the audio track instantly",
            symbol: "speaker.slash", category: .video, input: .many(videoInputs, noun: "videos"),
            keywords: ["remove audio", "silent", "no sound"], actionTitle: "Mute"
        ) { context in
            try await runMedia(context, suffix: "muted", ext: { input, _ in videoExtension(for: input) }) { input, _, url, progress in
                try await MediaToolkit.mute(input.url, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "video.rotate", title: "Rotate & Flip Video", summary: "Fix sideways or mirrored footage",
            symbol: "rotate.right", category: .video, input: .one(videoInputs, noun: "video"),
            options: [.choice("orientation", "Change", MediaToolkit.Orientation.allCases.map { ToolChoice($0.rawValue, $0.label) })],
            keywords: ["turn", "sideways", "mirror", "flip"], actionTitle: "Apply"
        ) { context in
            let orientation = context.options.choice("orientation", as: MediaToolkit.Orientation.self, default: .clockwise)
            return try await runMedia(context, suffix: "rotated", ext: { input, _ in videoExtension(for: input) }) { input, _, url, progress in
                try await MediaToolkit.reorient(input.url, orientation, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "video.speed", title: "Change Speed", summary: "Slow motion or time-lapse, pitch preserved",
            symbol: "gauge.with.dots.needle.67percent", category: .video, input: .one(videoInputs.union(audioInputs), noun: "video or audio"),
            options: [.choice("factor", "Speed", [ToolChoice("0.25", "0.25×"), ToolChoice("0.5", "0.5×"), ToolChoice("0.75", "0.75×"), ToolChoice("1.25", "1.25×"), ToolChoice("1.5", "1.5×"), ToolChoice("2", "2×"), ToolChoice("4", "4×")], default: "2")],
            keywords: ["slow motion", "fast forward", "timelapse", "speed up", "slow down"], actionTitle: "Apply"
        ) { context in
            let factor = context.options.double("factor")
            return try await runMedia(context, suffix: "\(context.options.string("factor"))x", ext: { input, probe in probe.hasVideo ? videoExtension(for: input) : "m4a" }) { input, _, url, progress in
                try await MediaToolkit.speed(input.url, factor: factor, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "video.loop", title: "Loop Video", summary: "Repeat a clip several times",
            symbol: "repeat", category: .video, input: .one(videoInputs, noun: "video"),
            options: [.stepper("times", "Play", range: 2 ... 20, default: 3, suffix: " times")],
            keywords: ["repeat", "boomerang"], actionTitle: "Loop"
        ) { context in
            let times = context.options.int("times")
            return try await runMedia(context, suffix: "loop", ext: { input, _ in videoExtension(for: input) }) { input, _, url, progress in
                try await MediaToolkit.loop(input.url, times: times, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "video.merge", title: "Merge Videos", summary: "Join clips into one video",
            symbol: "film.stack", category: .video, input: .many(videoInputs, noun: "videos", min: 2, max: 20),
            keywords: ["join", "combine", "concatenate", "stitch"], actionTitle: "Merge"
        ) { context in
            let url = context.outputURL("Merged", "mp4")
            let progress = context.progress
            try await MediaToolkit.concatenateVideos(context.inputs.map(\.url), output: url) { progress.report($0) }
            try MediaToolkit.verifyOutput(url)
            let duration = try await MediaToolkit.probe(url).duration
            return ToolOutput(files: [url], summary: "\(context.inputs.count) clips · \(MetadataFormatter.durationText(duration))")
        },

        ToolDefinition(
            id: "video.addaudio", title: "Add Music to Video", summary: "Replace a video's soundtrack",
            symbol: "music.note.tv", category: .video, input: .many(videoInputs.union(audioInputs), noun: "a video and a song", min: 2, max: 2),
            options: [.toggle("loop", "Loop audio to fill the video", default: true)],
            keywords: ["soundtrack", "background music", "replace audio", "dub"], actionTitle: "Combine"
        ) { context in
            guard let video = context.inputs.first(where: { $0.format.family == .video }),
                  let audio = context.inputs.first(where: { $0.format.family == .audio }) else {
                throw DocumentError.invalidOption("Add one video and one audio file.")
            }
            let url = context.outputURL("\(video.baseName)-with-audio", "mp4")
            let progress = context.progress
            try await MediaToolkit.replaceAudio(video: video.url, audio: audio.url, loopAudio: context.options.bool("loop"), output: url) { progress.report($0) }
            try MediaToolkit.verifyOutput(url)
            return ToolOutput(files: [url])
        },

        ToolDefinition(
            id: "video.frames", title: "Video to Images", summary: "Grab frames at a regular interval",
            symbol: "photo.on.rectangle.angled", category: .video, input: .one(videoInputs, noun: "video"),
            options: [
                .choice("every", "One frame every", [ToolChoice("0.5", "½ s"), ToolChoice("1", "1 s"), ToolChoice("2", "2 s"), ToolChoice("5", "5 s"), ToolChoice("10", "10 s")], default: "1", segmented: true),
                .choice("saveAs", "Save as", [ToolChoice("jpeg", "JPEG"), ToolChoice("png", "PNG"), ToolChoice("heic", "HEIC")], segmented: true)
            ],
            keywords: ["screenshots", "stills", "thumbnails", "extract frames"], actionTitle: "Extract"
        ) { context in
            let input = try context.first
            let probe = try await MediaToolkit.probe(input.url)
            let frames = try await MediaToolkit.extractFrames(input.url, everySeconds: context.options.double("every"), duration: probe.duration)
            let format = ImageToolkit.OutputFormat(rawValue: context.options.string("saveAs")) ?? .jpeg
            let urls = try frames.enumerated().map { index, frame in
                try ToolHelpers.write(try ImageToolkit.encode(frame, as: format, quality: 0.9), "\(input.baseName)-\(String(format: "%03d", index + 1))", format.fileExtension, context)
            }
            return ToolOutput(files: urls, summary: "\(urls.count) frames")
        }
    ]

    static let audioTools: [ToolDefinition] = [
        mediaConverter("audio.convert", "Convert Audio", summary: "M4A, WAV, AAC and more, with bitrate control", symbol: "arrow.triangle.2.circlepath", category: .audio, inputs: audioInputs, keywords: ["mp3 to m4a", "wav to m4a", "flac", "ogg", "opus", "m4a to wav"], featured: false),

        ToolDefinition(
            id: "audio.trim", title: "Trim Audio", summary: "Cut songs, voice memos and podcasts",
            symbol: "timeline.selection", category: .audio, input: .one(audioInputs, noun: "audio file"),
            editor: .mediaRange, keywords: ["cut", "ringtone", "clip", "shorten"], isFeatured: false, actionTitle: "Trim"
        ) { context in
            try await runMedia(context, suffix: "trimmed", ext: { _, _ in "m4a" }) { input, probe, url, progress in
                let range = context.editor.range ?? (0, probe.duration)
                try await MediaToolkit.trim(input.url, start: range.start, end: range.end, precise: true, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "audio.adjust", title: "Volume & Fades", summary: "Boost, normalize and fade in or out",
            symbol: "speaker.wave.3", category: .audio, input: .many(audioInputs, noun: "audio files"),
            options: [
                .slider("volume", "Volume", range: -20 ... 20, step: 0.5, default: 0, format: { String(format: "%+.1f dB", $0) }),
                .toggle("normalize", "Even out volume", footnote: "Makes quiet and loud parts play at a similar level."),
                .slider("fadeIn", "Fade in", range: 0 ... 10, step: 0.5, default: 0, section: "Fades", format: { String(format: "%.1f s", $0) }),
                .slider("fadeOut", "Fade out", range: 0 ... 10, step: 0.5, default: 0, section: "Fades", format: { String(format: "%.1f s", $0) })
            ],
            keywords: ["louder", "quieter", "boost", "normalize", "fade in", "fade out", "gain"], actionTitle: "Apply",
            validate: { values, _, _ in
                let edit = MediaToolkit.AudioEdit(volumeDB: values.double("volume"), fadeIn: values.double("fadeIn"), fadeOut: values.double("fadeOut"), normalize: values.bool("normalize"))
                return edit.isIdentity ? "Change the volume or add a fade" : nil
            }
        ) { context in
            let edit = MediaToolkit.AudioEdit(volumeDB: context.options.double("volume"), fadeIn: context.options.double("fadeIn"), fadeOut: context.options.double("fadeOut"), normalize: context.options.bool("normalize"))
            guard !edit.isIdentity else { throw DocumentError.invalidOption("Change the volume, add a fade or turn on normalize.") }
            return try await runMedia(context, suffix: "adjusted", ext: { _, _ in "m4a" }) { input, _, url, progress in
                try await MediaToolkit.editAudio(input.url, edit: edit, output: url, progress: progress)
            }
        },

        ToolDefinition(
            id: "audio.merge", title: "Join Audio", summary: "Combine tracks back to back",
            symbol: "music.note.list", category: .audio, input: .many(audioInputs, noun: "audio files", min: 2, max: 30),
            keywords: ["merge", "combine", "concatenate", "mix"], actionTitle: "Join"
        ) { context in
            let url = context.outputURL("Joined", "m4a")
            let progress = context.progress
            try await MediaToolkit.concatenateAudio(context.inputs.map(\.url), output: url) { progress.report($0) }
            try MediaToolkit.verifyOutput(url)
            let duration = try await MediaToolkit.probe(url).duration
            return ToolOutput(files: [url], summary: MetadataFormatter.durationText(duration))
        }
    ]
}
