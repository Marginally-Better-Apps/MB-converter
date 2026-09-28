#!/usr/bin/env python3
"""Exercise production Swift audio editing against the custom macOS FFmpeg bridge.

Build with: python3 Scripts/BuildFFmpeg.py --platform macos --offline
Requires ffmpeg/ffprobe for independent decoding and inspection. No simulator.
"""
from array import array
import json
import math
from pathlib import Path
import shutil
import subprocess
import tempfile
import wave

ROOT = Path(__file__).resolve().parents[1]
FRAMEWORKS = ROOT / "build/ffmpeg/macos-arm64"


def run(*args, capture=False):
    return subprocess.run(list(map(str, args)), check=True, cwd=ROOT,
                          stdout=subprocess.PIPE if capture else None).stdout


def main():
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    assert ffmpeg and ffprobe, "ffmpeg and ffprobe are required"
    with tempfile.TemporaryDirectory(prefix="mb-audio-edit-") as temporary:
        work = Path(temporary)
        formatter = (ROOT / "DesignSystem/Components/MetadataCard.swift").read_text()
        (work / "MetadataFormatter.swift").write_text(
            "import Foundation\nimport CoreGraphics\n" + formatter[formatter.index("struct MetadataRow:"):])
        paths = [
            "Core/Models/MediaModels.swift", "Core/Models/VideoColorInfo.swift",
            "Core/Conversion/ConversionCore.swift", "Core/Conversion/AudioExportParameters.swift",
            "Core/Conversion/AudioEditRenderer.swift", "Core/Conversion/AudioConverter.swift",
            "Core/Conversion/FFmpegCommandRunner.swift", "Core/Conversion/FFmpegEncodingStats.swift",
            "Core/Conversion/FFmpegMetadataOptions.swift", "Core/Inspection/MediaInspector.swift",
            "Core/Inspection/FFmpegMediaProbe.swift", "Core/Inspection/FFprobeVideoMetadata.swift",
            "Core/Inspection/MediaTagDiscovery.swift", "Core/Compatibility/CodecCapability.swift",
            "Core/Compatibility/FFmpegRuntimeInfo.swift", "Core/Compatibility/FormatMatrix.swift",
            "Features/OutputConfig/OutputConfigViewModel.swift", "Tests/AudioEditingTests.swift",
        ]
        run("xcrun", "swiftc", "-swift-version", "5", "-O", "-module-cache-path", work / "modules",
            "-F", FRAMEWORKS, "-framework", "MBFFmpegBridge", "-Xlinker", "-rpath", "-Xlinker", FRAMEWORKS,
            *[ROOT / p for p in paths], work / "MetadataFormatter.swift", "-o", work / "tests")
        rate = 48000
        samples = array("h")
        for index in range(rate * 3):
            samples.extend((round(24000 * math.sin(2 * math.pi * 440 * index / rate)),
                            round(8000 * math.sin(2 * math.pi * 880 * index / rate))))
        with wave.open(str(work / "stereo.wav"), "wb") as output:
            output.setparams((2, 2, rate, 0, "NONE", "not compressed"))
            output.writeframes(samples.tobytes())
        run(ffmpeg, "-v", "error", "-i", work / "stereo.wav", "-c:a", "libopus", work / "source.opus")
        run(ffmpeg, "-v", "error", "-i", work / "stereo.wav", "-c:a", "libmp3lame", "-b:a", "320k",
            work / "source.mp3")
        run(ffmpeg, "-v", "error", "-f", "lavfi", "-i", "color=size=16x16:rate=1:duration=3",
            "-i", work / "stereo.wav", "-c:v", "libx264", "-c:a", "aac", "-shortest", work / "source.mp4")
        run(work / "tests", work)

        def pcm(name):
            raw = run(ffmpeg, "-v", "error", "-i", work / name, "-f", "s16le", "-", capture=True)
            result = array("h")
            result.frombytes(raw)
            return result

        def probe(name):
            return json.loads(run(ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json",
                                  work / name, capture=True))

        assert pcm("trim.wav") == samples[5904 * 2:64560 * 2], "Trim must retain exactly the selected PCM samples"
        tagged = probe("tagged.flac")
        assert tagged["streams"][0]["codec_name"] == "flac"
        assert tagged["format"]["tags"]["Encoded by"] == "LAME in FL Studio 20"
        assert tagged["format"]["tags"]["BPM (beats per minute)"] == "120"
        assert abs(float(tagged["format"]["duration"]) - 3) < 0.06
        assert pcm("left.wav") == samples[::2], "Left channel selection changed samples"
        assert pcm("right.wav") == samples[1::2], "Right channel selection changed samples"
        assert pcm("mono-right.wav") == samples[::2], "Right-only mono input must not become silence"
        assert max(abs(x) for x in pcm("silent.wav")) == 0, "Mute did not silence export"
        assert max(abs(a - b / 2) for a, b in zip(pcm("quiet.wav"), samples)) <= 1, "Volume gain is wrong"
        boosted = pcm("boost.wav")
        assert len(boosted) == len(samples), "Limiter changed duration"
        assert max(abs(x) for x in boosted) <= 32114, "Boost did not preserve limiter headroom"
        assert max(boosted) > 30000, "Boost failed to increase volume"
        for name, expected in [("fast.wav", 1.5), ("slow.wav", 6), ("combined.wav", 2 / 1.5),
                               ("opus-trim.wav", 1.222), ("short.wav", 0.05), ("extracted.wav", 2 / 1.5)]:
            actual = float(probe(name)["format"]["duration"])
            assert abs(actual - expected) < 0.055, (name, actual, expected)
        for name in ["fast.wav", "slow.wav"]:
            left = pcm(name)[::2]
            middle = left[rate // 4:-rate // 4]
            crossings = sum(a <= 0 < b for a, b in zip(middle, middle[1:]))
            hz = crossings / (len(middle) / rate)
            assert abs(hz - 440) < 3, ("Speed changed pitch", name, hz)
        assert pcm("preview.wav") == pcm("combined.wav"), "Preview differs from exported edits"
        assert probe("mono.wav")["streams"][0]["channels"] == 1
        stereo = pcm("stereo-from-mono.wav")
        assert probe("stereo-from-mono.wav")["streams"][0]["channels"] == 2
        assert stereo[::2] == stereo[1::2], "Mono-to-stereo speakers differ"
        for extension in ["mp3", "m4a", "aac", "flac", "ogg", "opus"]:
            name = "muted." + extension
            assert probe(name)["streams"][0]["channels"] == 1, (name, "Channel choice overwritten")
            assert max(abs(x) for x in pcm(name)) <= 1, (name, "Effects skipped by export route")
        print("PASS: exact trim/channel samples, gain, mute, limiter, pitch, durations, all codecs, and preview equality")


if __name__ == "__main__":
    main()
