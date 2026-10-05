#!/usr/bin/env python3
"""Compare frozen original, optimized method 3 and optimized method 2.

Every measurement is a fresh process. Fixture generation and result validation
are excluded from timings and peak RSS. Outputs and JSON stay in build/.
Optional --photo paths add real local photos to the synthetic default corpus.
No simulator is used. Run outside a restrictive sandbox for Swift/ImageIO.
"""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
from TestImageConversion import ROOT, build_driver


def checked_output(command):
    return json.loads(subprocess.check_output(list(map(str, command)), text=True))


def evaluate(rows):
    grouped = {}
    for row in rows:
        key = (row["fixture"], row["quality"])
        grouped.setdefault(key, {}).setdefault(row["variant"], []).append(row)
    speed, growth, psnr_drops = [], [], []
    for cases in grouped.values():
        old, new = cases["method3"], cases["method2"]
        median = lambda items, key: statistics.median(x[key] for x in items)
        speed.append(1 - median(new, "encode_seconds") / median(old, "encode_seconds"))
        growth.append(median(new, "output_bytes") / median(old, "output_bytes") - 1)
        if old[0]["opaque"]:
            psnr_drops.append(median(old, "rgb_psnr_db") - median(new, "rgb_psnr_db"))
    checks = {
        "median_encoding_speedup_at_least_20_percent": statistics.median(speed) >= .20,
        "median_file_growth_at_most_10_percent": statistics.median(growth) <= .10,
        "maximum_file_growth_at_most_20_percent": max(growth) <= .20,
        "mean_psnr_drop_at_most_0_5_db": statistics.mean(psnr_drops) <= .5,
        "maximum_psnr_drop_at_most_1_db": max(psnr_drops) <= 1,
        "lossless_alpha": all(x["alpha_max_error"] == 0 for x in rows),
    }
    return {"selected_method": 2 if all(checks.values()) else 3, "checks": checks,
            "median_encoding_speedup": statistics.median(speed), "median_file_growth": statistics.median(growth),
            "maximum_file_growth": max(growth), "mean_psnr_drop_db": statistics.mean(psnr_drops),
            "maximum_psnr_drop_db": max(psnr_drops)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--photo", type=Path, action="append", default=[])
    parser.add_argument("--output", type=Path, default=ROOT / "build/webp-benchmark")
    args = parser.parse_args()
    if args.repetitions < 1:
        parser.error("--repetitions must be positive")
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source = (ROOT / "Core/Conversion/ImageConverter.swift").read_text()
    start, end = source.index("    // MARK: - WebP encoding"), source.index("    // MARK: - Decode")
    original = (ROOT / "Tests/Fixtures/WebPOriginalEncoder.swift.inc").read_text()
    executables = {}
    for variant in ["original", "method3", "method2"]:
        print(f"Building {variant}…", flush=True)
        work = output / variant
        work.mkdir(exist_ok=True)
        converter = work / "ImageConverter.swift"
        if variant == "original":
            converter.write_text(source[:start] + original + source[end:])
        else:
            method_line = next(line for line in source.splitlines() if "config.method =" in line)
            converter.write_text(source.replace(method_line, "        config.method = " + variant[-1], 1))
        executables[variant] = build_driver(work, converter=converter,
            driver=ROOT / "Tests/WebPBenchmark.swift", original_codec=variant == "original")
    fixtures = checked_output([executables["method3"], "generate", output / "fixtures"])
    for index, path in enumerate(args.photo):
        fixtures.append({"name": f"local-photo-{index}", "path": str(path.resolve()), "synthetic": False})
    (output / "fixtures.json").write_text(json.dumps(fixtures, indent=2) + "\n")
    rows = []
    for fixture in fixtures:
        for quality in [.6, .82, .95]:
            for repetition in range(args.repetitions):
                # Rotate ordering to reduce systematic warm-cache/thermal bias.
                variants = list(executables)
                variants = variants[repetition % 3:] + variants[:repetition % 3]
                for variant in variants:
                    destination = output / variant / f'{fixture["name"]}-q{int(quality*100)}.webp'
                    row = checked_output([executables[variant], "convert", fixture["path"], quality, destination])
                    row.update(fixture=fixture["name"], quality=quality, repetition=repetition, variant=variant)
                    rows.append(row)
                    print(f'{fixture["name"]} q{quality} {variant}: {row["total_seconds"]:.3f}s, '
                          f'{row["output_bytes"]} bytes, RSS {row["peak_rss_bytes"]/1048576:.0f} MiB', flush=True)
                    (output / "measurements.json").write_text(json.dumps(rows, indent=2) + "\n")
    result = evaluate(rows)
    (output / "decision.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
