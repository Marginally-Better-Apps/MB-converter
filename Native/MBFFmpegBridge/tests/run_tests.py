#!/usr/bin/env python3
"""Build and test the custom macOS FFmpeg libraries; no simulator is launched.

Build the macos-arm64 target with scripts/BuildFFmpeg.py first. Requires a system
ffmpeg/ffprobe for independent fixture generation and output validation.
Set MBF_TEST_VIDEOTOOLBOX=1 to also exercise macOS's hardware codec services.
"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
PREFIX = ROOT / "build/ffmpeg/macos-arm64/prefix"


def run(*args, capture=False):
    return subprocess.run([str(arg) for arg in args], check=True, text=True,
                          stdout=subprocess.PIPE if capture else None).stdout


def main():
    ffmpeg, ffprobe = shutil.which("ffmpeg"), shutil.which("ffprobe")
    if not ffmpeg or not ffprobe:
        raise SystemExit("Install ffmpeg/ffprobe for independent test fixtures.")
    if not (PREFIX / "lib/libavcodec.a").exists():
        raise SystemExit("Build macos-arm64 FFmpeg libraries before running these tests.")
    with tempfile.TemporaryDirectory(prefix="mbffmpeg-tests-") as temporary:
        directory = Path(temporary)
        executable = directory / "bridge_tests"
        command = ["cc", "-std=c11", "-Wall", "-Wextra", "-Werror",
                   "-I", ROOT / "Native/MBFFmpegBridge/include", "-I", PREFIX / "include",
                   ROOT / "Native/MBFFmpegBridge/MBFFmpegBridge.c", Path(__file__).with_name("bridge_tests.c"),
                   "-L", PREFIX / "lib"]
        command += ["-l" + lib for lib in ["avfilter", "avformat", "avcodec", "swresample", "swscale", "avutil",
                                          "mp3lame", "vorbisenc", "vorbis", "ogg", "opus", "vpx", "dav1d", "zimg"]]
        for framework in ["AudioToolbox", "VideoToolbox", "CoreMedia", "CoreVideo", "CoreFoundation", "Security"]:
            command += ["-framework", framework]
        command += ["-lz", "-lbz2", "-liconv", "-lm", "-lc++", "-o", executable]
        run(*command)
        run(ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=160x96:rate=12",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100", "-t", "1.5",
            "-c:v", "libx264", "-c:a", "aac", directory / "input.mp4")
        run(ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
            "-t", "1.5", "-c:a", "pcm_s16le", directory / "source.wav")
        run(ffmpeg, "-v", "error", "-y", "-f", "lavfi", "-i",
            "aevalsrc=0.25*sin(2*PI*440*t)+0.000001*sin(2*PI*997*t):s=48000:d=0.2",
            "-c:a", "pcm_s24le", directory / "source24.wav")
        run(ffmpeg, "-v", "error", "-y", "-i", directory / "source24.wav", "-c:a", "alac", directory / "source24.m4a")
        run(ffmpeg, "-v", "error", "-y", "-i", directory / "source24.wav", "-c:a", "pcm_s32le", directory / "source32.wav")
        run(ffmpeg, "-v", "error", "-y", "-display_rotation:v:0", "90", "-i", directory / "input.mp4",
            "-c", "copy", directory / "rotated.mp4")
        run(ffmpeg, "-v", "error", "-y", "-i", directory / "input.mp4", "-an", "-frames:v", "2",
            "-c:v", "libaom-av1", "-cpu-used", "8", directory / "av1.mkv")
        input_digest = hashlib.sha256((directory / "input.mp4").read_bytes()).digest()
        run(executable, directory)
        assert input_digest == hashlib.sha256((directory / "input.mp4").read_bytes()).digest()

        def probe(filename):
            return json.loads(run(ffprobe, "-v", "error", "-show_streams", "-show_format", "-of", "json",
                                  directory / filename, capture=True))

        def pcm(filename):
            return subprocess.check_output([ffmpeg, "-v", "error", "-i", str(directory / filename),
                                            "-f", "s16le", "-ac", "1", "-ar", "44100", "-"])

        for extension, codec in [("mp3", "mp3"), ("opus", "opus"), ("ogg", "vorbis"), ("flac", "flac")]:
            info = probe("audio." + extension)
            assert info["streams"][0]["codec_name"] == codec
            tags = info["format"].get("tags", {}) | info["streams"][0].get("tags", {})
            assert tags["title"] == 'Quoted "title"\nCafé'
            assert abs(float(probe(extension + "-decoded.wav")["format"]["duration"]) - 1.5) < 0.06
        assert pcm("source.wav") == pcm("flac-decoded.wav"), "FLAC must roundtrip sample-exactly"
        raw24 = lambda name: subprocess.check_output([ffmpeg, "-v", "error", "-i", str(directory / name),
                                                      "-f", "s24le", "-"])
        assert raw24("source24.wav") == raw24("flac24-decoded.wav"), "24-bit ALAC/FLAC must roundtrip sample-exactly"
        copied = probe("copy.mp4")
        assert copied["format"]["tags"]["title"] == "Copy title"
        assert copied["streams"][1]["tags"]["language"] == "fra"
        extracted = probe("audio-extraction.m4a")
        assert len(extracted["streams"]) == 1
        assert extracted["streams"][0]["tags"]["language"] == "fra"
        assert extracted["streams"][0]["tags"]["handler_name"] == "Extracted audio"
        assert "title" not in extracted["streams"][0]["tags"]
        webm = probe("pass2.webm")
        assert [stream["codec_name"] for stream in webm["streams"]] == ["vp9", "opus"]
        assert (webm["streams"][0]["width"], webm["streams"][0]["height"]) == (64, 112)
        assert webm["streams"][0]["avg_frame_rate"] == "10/1"
        assert webm["streams"][1]["channels"] == 2
        assert (directory / "rotated.png").read_bytes() == (directory / "rotation-reference.png").read_bytes()
        rotation = probe("rotation-copy.mp4")["streams"][0]["side_data_list"][0]["rotation"]
        assert rotation == 90, "Remux must preserve the display matrix"
        assert probe("av1.png")["streams"][0]["width"] == 160
        assert probe("seek.png")["streams"][0]["codec_name"] == "png"
        assert (directory / "seek.png").read_bytes() == (directory / "seek-reference.png").read_bytes(), "Seeking must return the requested frame"
        assert probe("concurrent.mp3")["streams"][0]["codec_name"] == "mp3"
        if os.environ.get("MBF_TEST_VIDEOTOOLBOX"):
            assert probe("h264.mp4")["streams"][0]["codec_name"] == "h264"
            assert probe("hevc.mp4")["streams"][0]["codec_tag_string"] == "hvc1"
        print("PASS: independent ffprobe inspection and lossless sample/rotation comparisons")


if __name__ == "__main__":
    main()
