#!/usr/bin/env python3
"""Test the clipboard waveform sampler on macOS without a simulator.

--benchmark adds a one-hour sparse PCM file and, when ffmpeg is installed,
short/long compressed fixtures. Each benchmark runs in a fresh process so its
peak RSS can be compared. Native format availability is reported, not assumed.
Compressed decoding needs access to macOS audio codec services; a restrictive
sandbox may report unsupported formats even when the host can decode them.
"""
import argparse
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def sparse_wave(path):
    rate = 48_000
    frames = rate * 3_600
    payload = frames * 2
    header = struct.pack("<4sI4s4sIHHIIHH4sI", b"RIFF", 36 + payload, b"WAVE", b"fmt ",
                         16, 1, 1, rate, rate * 2, 2, 16, b"data", payload)
    # Write only the sampled windows. The rest is silent sparse storage; the
    # logical file remains a valid hour of uncompressed audio (346 MB).
    with path.open("wb") as stream:
        stream.write(header)
        stream.truncate(len(header) + payload)
        for bar in range(24):
            center = int((bar + 0.5) * frames / 24)
            stream.seek(len(header) + (center - 2_048) * 2)
            stream.write(struct.pack("<h", 12_000) * 4_096)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--benchmark", action="store_true")
    parser.add_argument("--long-seconds", type=int, default=1_800,
                        help="duration of long compressed fixtures (default: 1800)")
    args = parser.parse_args()
    if args.long_seconds <= 5:
        parser.error("--long-seconds must be greater than 5")
    with tempfile.TemporaryDirectory(prefix="mb-waveform-tests-") as directory:
        work = Path(directory)
        executable = work / "waveform-tests"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "5", "-O",
            "-module-cache-path", str(work / "module-cache"),
            "Core/Inspection/AudioWaveformThumbnail.swift", "Tests/AudioWaveformTests.swift",
            "-o", str(executable)
        ], cwd=ROOT, check=True)
        subprocess.run([str(executable)], check=True, timeout=30)
        if not args.benchmark:
            return

        sparse = work / "sparse-3600s.wav"
        sparse_wave(sparse)
        subprocess.run([str(executable), str(sparse)], check=True, timeout=30)
        ffmpeg = shutil.which("ffmpeg")
        if ffmpeg is None:
            print("ffmpeg is unavailable; skipping optional compressed-format benchmarks.")
            return
        codecs = [("mp3", "libmp3lame"), ("m4a", "aac"), ("flac", "flac"),
                  ("aac", "aac"), ("ogg", "libvorbis"), ("opus", "libopus")]
        for extension, codec in codecs:
            for seconds in [5, args.long_seconds]:
                fixture = work / f"tone-{seconds}s.{extension}"
                subprocess.run([
                    ffmpeg, "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                    f"sine=frequency=440:sample_rate=48000:duration={seconds}",
                    "-c:a", codec, "-threads", "1", str(fixture)
                ], check=True, timeout=300)
                subprocess.run([str(executable), str(fixture)], check=True, timeout=30)


if __name__ == "__main__":
    main()
