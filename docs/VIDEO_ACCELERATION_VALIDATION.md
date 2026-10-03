# VideoToolbox and HDR validation

Validated on 2026-09-20 using the custom FFmpeg 9.0.1 runtime, zimg 3.0.6, an Apple Silicon host, and an iPhone 18 Pro (`iPhone19,2`) running iOS 27.0 (24A437). Device and arm64 simulator frameworks were rebuilt and verified; no simulator was launched.

## Automatic selection

Capability alone did not predict performance. Several fully accelerated paths used substantially less CPU but took longer than the software decoding/filtering reference. The native mobile policy therefore uses an explicit device/path allowlist, separate from hardware capability detection:

- On the validated model, 3840×2160 (or portrait-equivalent) H.264/8-bit BT.709 input to HEVC can use hardware decoding/filtering when there is no pixel transform or only a quarter-turn rotation.
- On that model, 4K HEVC/10-bit HLG input to HEVC can use hardware decoding/filtering when no pixel transform is needed.
- Resizing, HDR rotation, tone mapping, explicit frame-rate changes, other input formats/sizes, and unqualified devices use CPU decoding/filtering. VideoToolbox encoding and the same HDR/color policy remain available.
- `required` bypasses performance qualification to test a compatible fully accelerated path. It still rejects incompatible filters, color conversion, unsupported hardware and software encoding. `off` retains the software reference with the same encoder selection.

The allowlist lives in `mbf_qualified_mobile_video` in `Native/MBFFmpegBridge/MBFVideoPipeline.h`. Expand it only after correctness and the paired physical-device benchmark pass. Host tests exercise both accelerated paths and the mobile selection policy.

## Benchmarks

Each source contains 96 frames at 24 fps with a moving luma gradient and neutral chroma. Sources are H.264 SDR or HEVC Main10 HLG; outputs use HEVC at 4 Mbps, except tone mapping, which uses H.264. Each mode gets one warm-up and three measured runs, interleaved in alternating order. `off` still uses the selected VideoToolbox encoder, with software encoding fallback permitted. Hardware candidates require hardware encoding.

Initial qualification results (hardware/reference median ratios):

| Input and operation | Elapsed ratio | CPU-time ratio | Decision |
|---|---:|---:|---|
| 1080p SDR, half-size HEVC | 2.662 | 0.904 | CPU decode/filter |
| 1080p HLG, half-size HEVC | 1.731 | 0.327 | CPU decode/filter |
| 4K SDR, half-size HEVC | 2.316 | 0.219 | CPU decode/filter |
| 4K HLG, half-size HEVC | 1.480 | 0.118 | CPU decode/filter |
| 4K SDR, quarter-turn HEVC | 0.917 | 0.231 | Eligible |
| 4K SDR, quarter-turn + half-size HEVC | 2.391 | 0.221 | CPU decode/filter |
| 4K SDR, same-size HEVC | 0.962 | 0.282 | Eligible |
| 4K HLG, quarter-turn HEVC | 1.188 | 0.138 | CPU decode/filter |
| 4K HLG, quarter-turn + half-size HEVC | 1.593 | 0.131 | CPU decode/filter |
| 4K HLG, same-size HEVC | 1.040 | 0.105 | Eligible, close to elapsed limit |
| 1080p HLG, half-size SDR/H.264 | 1.164 | 0.859 | CPU decode/filter |
| 4K HLG, half-size SDR/H.264 | 1.148 | 0.882 | CPU decode/filter |

The initial scaling and tone-mapping XCTest benchmark assertions intentionally failed the ≤1.05 elapsed-ratio acceptance threshold; those failures drove the policy above. They were not treated as successful acceleration. The final suite tests that excluded paths select CPU processing and that automatically enabled paths still meet the performance threshold.

The final foreground suite passed all 28 tests, with no skips. Re-measured automatic/reference ratios were **0.920 elapsed / 0.228 CPU** for SDR rotation, **0.960 / 0.285** for SDR without transforms, and **1.015 / 0.095** for HLG without transforms. Each enabled path met the ≤5% elapsed-regression limit and showed a measurable CPU or speed benefit. All recorded thermal states in these runs were nominal.

[Raw benchmark samples](validation/video-acceleration-iphone19-2.json) include elapsed seconds, process CPU seconds, process peak RSS in bytes, thermal state before/after each run, and selected pipeline diagnostics. Peak RSS is cumulative process high-water memory, not per-conversion allocation. These short, synthetic clips establish a conservative selection baseline; they do not represent every camera scene, bitrate, temperature, or device. No general speedup claim is made for unmeasured devices.

## Correctness and failure coverage

The native suite covers 8/10-bit SDR, H.264/HEVC, HLG, PQ/HDR10, VideoToolbox scaling, all quarter-turn rotations/flips, display rotation, CPU crop fallback, frame-rate conversion, audio synchronization, repeated and concurrent jobs, cancellation, 32 MiB priming bounds, and injected initialization/mid-conversion failures. Cancellation, malformed input and output I/O failures do not retry. A hardware failure retries at most once, preserves color intent, removes the partial output, and never regresses displayed progress.

The independent software-reference comparisons measured 44.23 dB PSNR for PQ-to-SDR and 43.07 dB for HLG-to-SDR. Output inspection checks Main10, transfer/primaries/matrix/range, static HDR metadata retention, removal of HDR signaling after tone mapping, and ordinary SDR dithering without tone mapping. Dolby Vision-only color representations are rejected by policy tests.

The real Dolby fixture is [Dolby Laboratories' Profile 8.4 Sol Levante 1080p sample](https://github.com/DolbyLaboratories/dolby-vision-contents/blob/main/SolLevante_Netflix/BL_RPU_dvhe-08-84_1920x1080%4024fps_0_6313.mp4), SHA256 `d81d4c17958946796f30ca28a57776cee187a421649058767c8496cbc1e469bf`. This is an official Profile 8.4 sample, not a recording made by the paired iPhone. The suite trims a short stream-copy excerpt locally and tests HLG base-layer preservation, SDR conversion (41.61 dB PSNR), removal of stale Dolby signaling on re-encode, and preservation of Dolby configuration on valid stream copy. The original media and derivatives remain in ignored build storage and are not redistributed with the app/source bundle.

Reproduce native checks with:

```sh
python3 Native/MBFFmpegBridge/tests/run_tests.py
python3 Native/MBFFmpegBridge/tests/test_video_pipeline.py --hardware \
  --dolby-fixture build/ffmpeg/video-tests/dolby-profile84.mp4
python3 Scripts/TestFFmpegSwiftAdapter.py
bash Scripts/TestFormatCapabilities.sh
python3 Scripts/VerifyFFmpeg.py
```

The physical-device XCTest suite additionally checks Main10/HLG transforms, PQ and real Dolby-to-HLG/SDR conversions, AVFoundation decoding of complete output files, cancellation cleanup, and existing background-session behavior. `testExternalHDRFixtures` expects the generated PQ fixture and Dolby excerpt at `Documents/mb-pq-validation.mp4` and `Documents/mb-dovi-validation.mp4` in the app container and removes them after testing.

`testLockedScreenHardwareConversion` is opt-in through the test environment variable `MBF_LOCKED_SCREEN_TEST=1`. It waits for continued background execution, emits `MBF_LOCK_TEST_READY`, and runs HDR conversion while the user locks the phone. Its attachment records completed background jobs and pipeline selection. This verifies the shipping `auto` policy, including software filtering with VideoToolbox encoding; it does not request background GPU resources.

The final locked-screen test **passed**: ten conversions completed across roughly eleven seconds in the background, with 10-bit HLG and the expected 540×960 orientation preserved. VideoToolbox hardware encoding succeeded without a hardware retry. The first harness run expired after it omitted actual-work progress updates; the corrected harness now reports processed media time and cancels on expiration, matching the existing production session. No background-execution behavior in the app was changed. [Captured pipeline log](validation/video-locked-screen-iphone19-2.txt).

Final checks: 28 foreground XCTest cases plus the locked-screen case passed on the physical iPhone; native baseline, native hardware/HDR/Dolby, Swift adapter and format-capability suites passed; both framework slices passed dependency/license/filter verification; and the signed app/test build succeeded. Playback verification here means complete AVFoundation decoding of outputs, not a subjective display/calibration assessment.
