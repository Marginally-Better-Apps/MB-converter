# WebP encoding validation

Validated September 21, 2026 on Apple Silicon macOS 26.6.2 with Xcode 27.0.
No simulator was launched. Physical iPhone timings and memory pressure have not
been measured.

## Implementation

The local `Native/WebP` package vendors libwebp 1.6.0 at the previously resolved
revision, with per-file provenance hashes and upstream license/patent notices.
Debug and Release both compile the codec with effective `-O2` and
`WEBP_USE_THREAD`. The app's Swift Debug settings remain unchanged. Verification
of the actual device-build response files and object symbols confirms the
optimization flag, ARM64 NEON encoder, and pthread worker implementation.
`WebP-NOTICE.txt` is present in both built app bundles.

The converter draws sRGB pixels directly into `WebPPicture`'s ARGB buffer,
respecting `argb_stride`, and no longer allocates/imports a second BGRA raster.
Core Graphics premultiplied colors are converted in place to straight alpha
only when pixels are transparent. The photo preset, dithering, quality slider,
selected resolution, progress, cancellation, and single encode are retained.
Method **3** remains the production default.

## Method 2 decision

The qualification run covers seven deterministic synthetic fixtures (small
photo-like texture, gradient, text, noise, transparency, and 12MP/48MP HEIC
textures), three quality values (60, 82, 95), three variants and three repetitions:
189 fresh conversion processes. The original variant uses the frozen old pixel
path and its former Release codec flags (`-Os`, without threading). Optimized
variants use the production source and codec flags, changing only `method`.

Method 2 fails the agreed balanced-output gates:

| Metric versus optimized method 3 | Result | Limit |
| --- | ---: | ---: |
| Median file growth | 5.81% | ≤10% |
| Maximum file growth | 110.13% | ≤20% |
| Mean opaque RGB PSNR decrease | 0.532 dB | ≤0.5 dB |
| Maximum opaque RGB PSNR decrease | 2.408 dB | ≤1 dB |
| Maximum alpha-channel error | 0 | 0 |

The worst file growth occurs on noise at quality 95. The worst PSNR decrease is
on text at quality 82, where the output is also 39.5% larger. Method 2 was faster,
but these deterministic size/quality failures reject it regardless of timing.
Production method 3 produces byte-identical files to the original for all
18 opaque fixture/quality pairs. Transparent RGB values intentionally change to
correct the former premultiplied-color darkening; alpha values remain exact.

## Timing and memory

The table below uses a separate three-repetition run at quality 82 after all
builds and regression tests finished. Values are medians of fresh processes.
Fixture generation is a separate process. Timings include decode, pixel
preparation, encoding and file writing; peak RSS is sampled immediately after
conversion, before output validation allocates additional image buffers.

| Input | Implementation | Preparation | Encode | Total | Peak RSS | Output bytes |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 4032x3024 | Original | 0.129 s | 0.765 s | 0.897 s | 301 MiB | 3,147,976 |
| 4032x3024 | Optimized method 3 | 0.128 s | 0.703 s | 0.833 s | 255 MiB | 3,147,976 |
| 8064x6048 | Original | 0.252 s | 9.090 s | 9.347 s | 961 MiB | 12,116,456 |
| 8064x6048 | Optimized method 3 | 0.245 s | 8.525 s | 8.774 s | 775 MiB | 12,116,456 |

These fixtures are synthetic textured HEIC images, not camera photographs.
Timing depends on image content, machine load, and thermal state. The initial
qualification pass overlapped other validation work for some cases; only the
separate measurements above are used for the performance comparison. No
physical-device performance claim is made.

## Checks

- Release Swift image regression suite: passed.
- Debug Swift image regression suite including a 48MP HEIC: passed.
- Exact alpha preservation and correct transparent RGB at qualities 60/82/95: passed.
- Odd sizes, tiny outputs, crop, rotation, requested/decoded dimensions: passed.
- Preparation/encode cancellation, invalid dimensions and partial-output cleanup: passed.
- Existing PNG dimensions/metadata/estimates and JPEG/HEIC size-target regressions: passed.
- Generic iOS Debug and Release builds, unsigned: passed.
- Vendored source hashes, effective codec build flags, NEON/pthread symbols, bundled notices: passed.
- Visual inspection of text, gradients, and transparent pixels over a checkerboard: passed for method 3; corrected alpha colors match the source.
- `git diff --check`: passed.

## Reproduction

```sh
python3 Scripts/TestImageConversion.py
python3 Scripts/TestImageConversion.py --large --debug
python3 Scripts/BenchmarkWebP.py
python3 Scripts/VerifyWebP.py --derived-data build/WebPValidation
```

`BenchmarkWebP.py` also accepts repeated `--photo /path/to/photo.heic` arguments
to extend the corpus with real local photographs. It writes stage timings, total
time, output size, peak RSS, RGB PSNR, alpha error, and the deterministic method
decision to JSON under `build/webp-benchmark`. `fixtures.json` records inputs;
`measurements.json` records the qualification run; `isolated-q82.json` records
the separate performance comparison. Both measurement sets and the decision are
also checked in as `docs/validation/webp-encoding-measurements.json`. The reviewed contact sheet is
`build/webp-benchmark/visual-comparison.png`.
