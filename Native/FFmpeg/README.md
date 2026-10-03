# MB Converter FFmpeg runtime

This package replaces FFmpegKit with an original MIT adapter over FFmpeg's public C libraries. The complete runtime is one **dynamic** `MBFFmpegBridge.framework` inside an XCFramework. Static PIC archives are intermediate build inputs, not libraries statically linked into the app executable. FFmpeg and LAME retain their own LGPL licenses; the application/adapter MIT license does not relicense them.

## Build

Use an Apple Silicon Mac, Python 3.12+, Xcode 26+, CMake, pkg-config, autoconf, automake and GNU libtool (`brew install autoconf automake libtool`). Host regression builds require macOS 13 or later. The initial validated build used Xcode 26.6, CMake 3.29.5, Meson 1.7.2 and Ninja 1.11.1.3. Framework manifests record the exact SDK and tool versions. The checked-in `sources.json` pins every source archive by SHA256. No codecs are downloaded at app runtime.

From the repository root:

```sh
python3 -m venv build/ffmpeg/tools
build/ffmpeg/tools/bin/python -m pip install meson==1.7.2 ninja==1.11.1.3
python3 Scripts/BuildFFmpeg.py --platform ios --platform ios-simulator
python3 Scripts/VerifyFFmpeg.py
```

The build downloads source archives on first use, checks hashes on every run, detects edits to extracted source, and invalidates dependencies when the recipe, toolchain or source pins change. Add `--offline` to prohibit downloads after the first run. `--fetch-only` downloads/extracts without compiling. The source/framework caches are ignored by Git. Build logs and per-platform headers/libraries are under `build/ffmpeg/`.

Output: `Native/FFmpeg/Artifacts/MBFFmpegBridge.xcframework`, containing arm64 device and Apple Silicon simulator slices. Intel simulator support is not included. The local Swift package intentionally requires this artifact before Xcode resolves it; run the source build first. Xcode embeds/signs the selected framework through SwiftPM. No production signing key is needed to build the runtime.

The bundle includes MP3 (LAME), FLAC, Vorbis, Opus and VP8/VP9 encoders, dav1d AV1 decoding, native AAC/PCM, and Apple VideoToolbox H.264/HEVC. Both encoder and muxer availability control the app's output menu. GPL, nonfree and version3 configuration options are disabled, and LAME's decoder/frontend are excluded. Network protocols are disabled because the app imports remote media through URLSession.

## Adapter behavior

`Native/MBFFmpegBridge/` is independently implemented and does not include FFmpegKit or its LGPLv3 wrapper code. It implements this app's single-input/single-output command subset through libav APIs. It is not a general-purpose FFmpeg CLI replacement: unsupported options fail explicitly. Every invocation owns its decoder, filter, encoder and muxer state, and cancellation is scoped to the invoking job. Probing emits the subset of FFprobe JSON used by the app.

The adapter supports conversion, stream copy, metadata policies, seeking/frame extraction, crop/rotation/scale/fps filters and VP9 two-pass statistics. Input display rotation is applied before the app's filters. VideoToolbox output uses single-pass encoding; it cannot use the software VP9 statistics-based two-pass path. AV1 export is not implemented. The app uses FFmpeg poster extraction and cached, cancellable playback copies for media Apple's native preview cannot open; see [preview behavior and validation](../../docs/DEVELOPMENT.md#format-support).

Audio editing uses `-af` graphs for sample-accurate trimming, gain with limiting,
pitch-preserving tempo, and channel selection. Filtered audio cannot use stream
copy. A completed trim graph stops decoding once all selected streams reach EOF.
The editor renders cancellable PCM previews through the same filters as export.

`-metadata_input:s:<index>` and `-map_metadata_input:s:<index>` are adapter-specific options: they map metadata from the input stream index used by the editor to its selected output stream. Standard `-metadata:s:<index>` still addresses an output index. This prevents losing audio-stream tags when extracting source stream 1 into output stream 0.

## Accelerated video and color policy

Video-to-video commands pass `-mb-acceleration auto`. `off` uses CPU decoding/filtering with the same color policy; encoder selection is unchanged. `required` rejects CPU pixel-processing stages and never retries. Commands without this option retain the legacy behavior for audio, still images and frame extraction.

Automatic mobile decoding/filtering is limited to device/path combinations that passed physical-device performance qualification. The current allowlist covers selected 4K conversions without resizing on iPhone 18 Pro; other paths retain CPU decoding/filtering and VideoToolbox encoder selection. Scaling and several HDR paths reduced CPU use but exceeded the 5% elapsed-time regression limit. See [measured results and the selection matrix](../../docs/VIDEO_ACCELERATION_VALIDATION.md). `required` remains available for testing supported paths outside that allowlist.

H.264/HEVC decoding uses VideoToolbox where the device and stream support it. Compatible square-pixel video stays in VideoToolbox frames through scaling, quarter-turn rotation/flips and H.264/HEVC encoding. Cropping, arbitrary filters, anamorphic video, incompatible formats, VP9 encoding and tone mapping use a software filter graph with one download of decoded frames. FPS adjustment preserves timestamps without touching pixel data. First-frame initialization keeps up to 32 MiB of leading packets so audio is not lost.

The small checked-in FFmpeg patch makes HEVC hardware decoding use Apple's **require hardware** property, as upstream H.264 decoding already does. This prevents the framework silently using its software HEVC decoder while diagnostics claim acceleration. Patch hashes are included in cache identities and framework manifests; the patch and original source archive are included in corresponding-source bundles.

HEVC output preserves 10-bit SDR and HLG/PQ HDR using P010/Main10. HDR output retains primaries, transfer, matrix, range and available mastering, content-light and ambient-viewing metadata. Other video outputs receive BT.709 limited-range SDR through pinned zimg 3.0.6 (`zscale`) and CPU Mobius tone mapping. Source peak precedence is MaxCLL, mastering maximum, then 10,000 nits for PQ or 1,000 nits for HLG, with a 100-nit SDR reference. Ordinary 10-to-8-bit SDR conversion uses dithering, without tone mapping.

Compatible Dolby Vision base layers become ordinary HLG/PQ/SDR when re-encoded. Dynamic Dolby Vision/HDR10+ metadata is removed instead of falsely labeling the new video; unsupported Dolby Vision-only representations fail explicitly. Valid stream copy retains source metadata. HDR-to-SDR conversion cannot use stream copy. Privacy tag removal does not remove the color information needed to interpret the pixels.

Hardware-specific failures retry once with CPU decoding/filtering and the same color policy. Cancellation, invalid media and output I/O failures are not retried. Partial output is removed; displayed progress remains monotonic and throughput estimates restart. Diagnostics identify every selected stage, hardware requirements, output format, color policy, retry and elapsed time. Main10 failures never silently downgrade to 8-bit.

Prior physical-device benchmark results and locked-screen measurements are retained in [the validation report](../../docs/VIDEO_ACCELERATION_VALIDATION.md). The device benchmark harness used for those measurements is not part of the current test target. Re-run paired physical-device correctness/performance checks before qualifying additional device/OS combinations. Metal, Core ML, AI enhancements and background GPU resource requests are not introduced.

## Verification

Build host libraries and run conversion regressions without launching an iOS simulator:

```sh
python3 Scripts/BuildFFmpeg.py --platform macos --libraries-only
python3 Native/MBFFmpegBridge/tests/run_tests.py
python3 Native/MBFFmpegBridge/tests/test_video_pipeline.py
python3 Native/MBFFmpegBridge/tests/test_video_pipeline.py --hardware
python3 Scripts/TestFFmpegSwiftAdapter.py
bash Scripts/TestFormatCapabilities.sh
```

The native suite uses a separately installed `ffmpeg`/`ffprobe` only to create fixtures and independently validate output. It links the custom library build. `MBF_TEST_VIDEOTOOLBOX=1` adds hardware H.264/HEVC tests and needs access to Apple's encoder service; a restricted shell sandbox may block that service.

Then compile the app using the unsigned-device command in `docs/DEVELOPMENT.md`. An unsigned build and host regressions do not replace signed archive validation and real-iPhone tests for thermals, hardware codecs, cancellation, Files import and output preview.

## Corresponding source and distribution

The framework contains the upstream licenses/notices and a build manifest; Settings exposes the notices. Prepare a matching local source archive after the final build:

```sh
python3 Scripts/BundleFFmpegSources.py
```

The archive includes the current application/adapter sources (including uncommitted changes), pinned dependency tarballs, recipes and build configuration. It fails if the adapter or recipe differs from the framework manifest. Extract the `app/` directory, copy the tarballs from `dependencies/` into its `build/ffmpeg/downloads/`, install the recorded build tools, and run the offline build command above. To run a modified app on a device, choose the recipient's development team and bundle identifier in Xcode. Production signing credentials are never included.

Before distribution, publish the corresponding source archive and checksum alongside the release materials, record the immutable source URL, and make it accessible from the app's source/license links. Keep notices and LGPL modification/relinking rights intact. Review the actual distribution terms and signing/rebuilding route for compliance. This branch does not by itself certify App Store eligibility, and these local scripts do not publish anything. The [GitHub release workflow](../../.github/workflows/release.yml) builds the device runtime and publishes the IPA and matching source archive with checksums after validation.
