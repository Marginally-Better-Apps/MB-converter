# PNG dimensions validation

Validated September 21, 2026 on macOS with Xcode 27.0, optimized Swift,
ImageIO and the resolved libwebp. No simulator was launched.

The former byte-target search has been removed. PNG now uses a dimensions
slider, one background full-resolution baseline measurement, and a pixel-count
ratio to estimate output size. Export performs one normal PNG encode. No RGB
quantization, SSIM scoring, candidate search or prepared-output cache remains.

## Checks

- Standalone image regression suite: passed (normal and 48MP fixtures).
- Auto target planner and format capability suites: passed.
- Unsigned Release build for generic iOS: passed.
- `git diff --check`: passed.

The suite covers photos, gradients, text, flat graphics, noise, transparency,
selected/reported/decoded dimensions, tiny outputs, crop and rotation, retained
metadata, GIF first-frame measurement, cancellation cleanup, stale-baseline
rejection and immediate estimates during slider changes. JPEG/HEIC byte targets
and WebP encoding/progress/cancellation also pass. UI interaction and physical
iPhone memory pressure have not been tested.

## Benchmarks

Deterministic noisy HEIC inputs, exporting at 50% width and height (25% pixels):

| Input | Baseline measurement | Single PNG export | Estimated size | Actual size | Process peak RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| 2048 × 1536 | 0.23 s | 0.06 s | 2,329,208 B | 2,318,593 B | 76 MiB |
| 8064 × 6048 | 2.93 s | 0.74 s | 36,101,641 B | 35,839,298 B | 686 MiB |

Timings include export file writing. Process peak RSS includes fixture creation
and earlier tests, and is sampled before the subsequent WebP benchmark. Only
baseline bytes and dimensions are retained by the UI; dimension changes perform
no image encoding. ImageIO baseline cancellation is checked between synchronous
operations. File-size estimates are approximate and have no hard byte limit.
