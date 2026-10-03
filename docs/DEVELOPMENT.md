# Build and run MB Converter

MB Converter is a native SwiftUI app for iOS and iPadOS 17 or later. Video and audio conversion use a custom FFmpeg runtime and an original in-process adapter; still images use ImageIO, Core Image, and libwebp.

[App overview](../README.md) · [Release guide](RELEASING.md)

## Requirements

- A Mac with **Xcode 26 or later**, its command-line tools, and the iOS SDK installed. The project uses Swift 5 language mode; you do not need a separate Swift installation.
- An Apple Silicon Mac, Python 3.12+, CMake, pkg-config, autoconf, automake and GNU libtool for the custom engine build.
- Internet access for the initial FFmpeg source archives and build tools; libwebp sources are vendored.
- For a physical device: an Apple account added in Xcode, a signing team, and an iPhone or iPad running iOS/iPadOS 17 or later with Developer Mode enabled.
- For App Store distribution: an Apple Developer Program membership and access to this app in App Store Connect.

The deployment target remains iOS 17. Building with a newer SDK does not raise that minimum. App Store uploads currently require Xcode 26 or later and the iOS 26 SDK or later; check [Apple's current requirements](https://developer.apple.com/news/upcoming-requirements/) before submitting.

## Run in Xcode

```sh
git clone https://github.com/Marginally-Better-Apps/MB-converter.git
cd MB-converter
open Converter.xcodeproj
```

1. Build the custom engine using the commands below, then let Xcode resolve the Swift package dependencies.
2. Select the **Converter** scheme.
3. Select an installed iPhone/iPad simulator or a connected device as the run destination.
4. For a physical device, open the **Converter** target's **Signing & Capabilities**, select your own team, and use a unique bundle identifier for your personal build. Enable automatic signing. The checked-in team and bundle identifier belong to the published app's maintainers.
5. Choose **Product → Run** (`⌘R`).

No API keys, backend services, CocoaPods, or environment files are needed. Local file conversion can run offline once the app and dependencies are installed. Hardware-backed video encoders should also be tested on a real device.

## Build from the command line

Run commands from the repository root. Check the selected toolchain with `xcodebuild -version`; if it points at Command Line Tools instead of Xcode, select the Xcode installation in **Xcode → Settings → Locations**.

Build the pinned custom engine first. See [runtime build details](../Native/FFmpeg/README.md) for caching, verification and source/relink materials.

```sh
python3 -m venv build/ffmpeg/tools
build/ffmpeg/tools/bin/python -m pip install meson==1.7.2 ninja==1.11.1.3
python3 Scripts/BuildFFmpeg.py --platform ios --platform ios-simulator
python3 Scripts/VerifyFFmpeg.py
```

Resolve the checked-in dependency versions:

```sh
xcodebuild -resolvePackageDependencies \
  -project Converter.xcodeproj \
  -scheme Converter \
  -onlyUsePackageVersionsFromResolvedFile
```

Compile a Release build for iOS devices without signing or installing it:

```sh
xcodebuild \
  -project Converter.xcodeproj \
  -scheme Converter \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO \
  build
```

This checks compilation and app packaging. It does not validate signing, exercise conversions, or produce an App Store upload. The [release guide](RELEASING.md) covers signed archives and device checks.

## Dependencies and reproducible builds

| Dependency | Pinned version | Role |
| --- | --- | --- |
| [MBFFmpeg](../Native/FFmpeg/README.md) | FFmpeg 9.0.1 and codec source hashes in `Native/FFmpeg/sources.json` | Custom LGPL2.1 media conversion and probing; original MIT adapter |
| [MBWebP](../Native/WebP/README.md) | libwebp 1.6.0, vendored hashes in `Native/WebP/provenance.json` | Optimized, threaded still WebP encoding |

Both Swift packages are local. Keep the FFmpeg source manifest and WebP provenance manifest in Git; review dependency upgrades and commit source pins, vendored sources, and notices together.

The local `Native/FFmpeg` package loads the generated XCFramework from `Artifacts/`; build it before opening Xcode on a fresh checkout. The recipe compiles sources into one dynamically linked framework with the original adapter. Build caches, generated frameworks and downloaded packages are ignored. SwiftPM embeds the framework automatically; the old FFmpegKit package is no longer referenced.

### Format support

`Core/Compatibility/FormatMatrix.swift` defines the outputs offered for each input category. `CodecCapability.swift` handles encoder availability and import checks. `FFmpegRuntimeInfo.swift` reports the bundled runtime configuration.

The app offers MP4 (H.264/HEVC), MOV, WebM (VP9/Opus), MP3, FLAC, Ogg/Vorbis, Opus, M4A, AAC, WAV, JPEG, PNG, HEIC, WebP, and TIFF output when their actual encoders/muxers are present. GIF inputs can become video or a still image. AV1 input uses dav1d. Two-pass encoding is offered only for VP9; VideoToolbox H.264/HEVC uses single-pass encoding.

Previews try ImageIO/AVFoundation first. `MediaPreviewRenderer` extracts PNG posters
when native decoding fails. Playback preparation starts only on opening the player:
compatible H.264/HEVC and AAC streams can be copied into MP4/M4A; other video uses
an H.264/AAC preview bounded to 1280×720 at 30 fps, and audio uses AAC with a PCM
fallback. The existing edit composition applies crop/rotation to the prepared copy
using source-relative coordinates. Closing the player cancels preparation. A native
player failure triggers one decoded retry; unreadable files show an error.

Preview files live in a separate temporary cache keyed by source path, dates and
size. It retains up to 24 entries/256 MiB, excluding files held by active players,
and clears the previous session on first use. Still images unsupported by ImageIO
also use FFmpeg for import inspection and full-resolution export decoding. Original
media and export metadata settings remain unchanged. This does not expand the
recognized file extension list or enable native video trimming for unsupported inputs.

## Repository layout

| Path | Contents |
| --- | --- |
| `App/` | App entry point, navigation, appearance, privacy manifest |
| `Assets.xcassets/` | App icon and assets |
| `Core/` | Conversion, metadata inspection, format compatibility, imports, history, diagnostics, models |
| `DesignSystem/` | Theme, haptics, reusable controls |
| `Features/` | Import, editing, conversion, results, history, and diagnostics screens |
| `Scripts/` | Native builds, dependency verification, regression harnesses, and release packaging |
| `Native/` | Custom FFmpeg source pins/build package, C adapter and native regression tests |
| `Converter.xcodeproj/` | Project, shared scheme, dependency lockfile |
| `docs/` | Build/release guides, listing copy, original screenshots |

## Storage and diagnostics

Imported files and conversion working files use the app's temporary directory and are cleaned at launch. Session-only history is also cleared on the next launch. Saved history copies output files into Application Support until the user deletes them or disables saved history.

Settings → Error Log displays diagnostics and supports copying or exporting a report. Reports may contain file paths, media metadata, conversion commands, and device information. They are not automatically uploaded; review reports before sharing them publicly.

`App/PrivacyInfo.xcprivacy` declares app-local preferences and file timestamp access. Revisit those declarations whenever storage, diagnostics, networking, or dependencies change.

## Validation

Run `python3 Scripts/TestMediaPreview.py` after building the macOS FFmpeg framework
to exercise real unsupported-format posters/playback, stream copy, cache reuse and
invalidation, and cancellation. `MediaPreviewPlaybackTests` in ConverterTests checks
native playback reuse, cancellation during preparation, inactive app behavior, and
bounded retries after native player failures. `python3 Scripts/TestImageConversion.py
--ffmpeg` adds a real JPEG-LS ImageIO fallback regression to the image suite.

Audio editing keeps trim bounds in source time and stores volume, speed, and
channel choices in the conversion configuration. Preview and export share the
same FFmpeg filter graph; edited duration drives target-size planning. The audio
editor reuses the video trim handles, scrubbing, and grouped undo behavior.

Run `python3 Scripts/TestAudioEditing.py` after building the macOS FFmpeg framework
to verify exact PCM trim/channel samples, volume and limiting, pitch-preserving
speed, compressed formats, preview/export agreement, cancellation cleanup, and
output planning. `AudioEditorPreviewTests` in the ConverterTests target checks
preview reuse, source-to-output seeking, stale playback cancellation, and saves
light/dark editor images as test attachments for visual review.

Run `python3 Scripts/TestClipboardImports.py` for clipboard import regressions on
macOS without a simulator or access to the real clipboard. It compiles the import
service and Home view model with host adapters, covering failed HEIC requests,
image-data and alternate-file fallbacks, temporary-file lifetime, disabled paste
controls, and stale asynchronous results. Add `--ffmpeg` to verify real WMV,
WebM, AVI, AV1/MKV, MPEG-TS, FLV, JPEG-LS, GIF, WebP, Opus, Ogg and FLAC thumbnails
through direct file URLs, expiring providers, and raw clipboard data. This mode
uses the custom macOS framework and the host ffmpeg CLI to create fixtures.
Source-app/iOS provider behavior still needs device verification.

Clipboard thumbnails use the same FFmpeg still-frame fallback as the full preview,
for every recognized image/video format the bundled runtime can decode. Decoding
runs off the main actor. Provider files are copied before their callbacks return;
fallback work and duration probing finish before those owned copies are removed.
Raw clipboard media receives the same thumbnail path. Clipboard revisions cancel
old work and cannot display stale results.

Clipboard audio thumbnails sample 24 short windows across the recording, then
render a 144-pixel waveform once per clipboard change. Sampling runs in the
provider's background callback, with coordinated file access, at most 2,048
frames per window and a reusable buffer (up to 64 KiB for eight channels).
Cancellation and a cooperative 500 ms budget are checked between native decoder
calls. If native decoding fails, FFmpeg renders at most the first 12 seconds into
a small stereo PCM file for a waveform thumbnail, then removes it. Native waveforms
sample the whole recording; fallback waveforms represent that initial excerpt.
Unreadable media keeps the no-thumbnail fallback. The waveform is a sampled
overview, so very brief events between sample windows can be missed.

Run `python3 Scripts/TestAudioWaveform.py` for waveform regressions, or add
`--benchmark` to measure one-hour PCM and short/30-minute compressed fixtures.
The optional benchmarks need the `ffmpeg` CLI and access to system audio decoder
services. On the development Mac, cold sampling took 8 ms for a one-hour WAV and
9–60 ms for 30-minute MP3/M4A/FLAC/AAC/Ogg/Opus files; these are host measurements,
not iPhone performance guarantees.

Run `python3 Scripts/TestRemoteImports.py` for link import regressions on macOS,
without a simulator or network. It exercises HTTP rejection, web-page responses,
empty/truncated downloads, temporary-file cleanup, progress, and media validation.
For real AVI/WebM fallback coverage, add
`--ffmpeg-framework build/ffmpeg/macos-arm64/MBFFmpegBridge.framework` after building
the host engine; this mode also needs the `ffmpeg` CLI to generate fixtures.
The suite needs access to macOS type identification and media services.

PNG uses a dimensions slider, with aspect ratio preserved and no upscaling. Both
configuration screens estimate size as the full-resolution PNG byte count times
the selected pixel-count ratio. One background baseline encode includes crop,
rotation and retained metadata; changing dimensions updates the estimate without
encoding again. The estimate is advisory. Export uses the normal single-pass
ImageIO path, with no target-byte search or color reduction. Only the baseline
byte count and dimensions are retained.

Run the standalone image suite with `python3 Scripts/TestImageConversion.py`, or
add `--large` for a 48MP HEIC → PNG/WebP benchmark. It covers selected/exported
dimensions, transparency, crop/rotation, retained metadata, cancellation, first-frame
measurement, instant slider estimates and stale-baseline rejection. JPEG/HEIC
size targeting and WebP progress/cancellation are checked too. The suite needs
access to macOS system image encoders; it does not launch a simulator.

WebP renders into encoder-owned pixels, corrects premultiplied alpha, and compiles
its codec with `-O2` and threading even in Debug. Run
`python3 Scripts/BenchmarkWebP.py` to compare the original encoder and optimized
methods 3/2; see [codec build details](../Native/WebP/README.md).

The shared Converter scheme includes `ConverterTests`, covering background execution, expiration/retry races, warning scheduling and notification authorization, native image/audio cancellation cleanup, and VideoToolbox output. Run it on an installed simulator:

```sh
xcodebuild -project Converter.xcodeproj -scheme Converter \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -derivedDataPath build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile CODE_SIGNING_ALLOWED=NO test
```

The continued-processing registration smoke test runs only on a physical iOS 26+ device and reports a skip if the system declines extended execution. Simulator tests cannot validate background scheduling or Lock Screen presentation. Standalone suites also cover native conversion round trips, Swift argument/probe/cancellation contracts and format capability gates; see the [runtime verification instructions](../Native/FFmpeg/README.md).

## License

The application and original adapter source are under the [MIT License](../LICENSE). FFmpeg, LAME, libwebp and other bundled libraries have their own licenses. Retain their notices and distribute the matching source/rebuild materials before release. The app's MIT license does not relicense its dependencies.


## Background conversion

The app owns one conversion session independently of its processing view. On iOS/iPadOS 26+, each user-started conversion requests a `BGContinuedProcessingTask` with immediate execution (`.fail`). The system supplies its progress Live Activity and cancellation control; there is no custom ActivityKit widget or push service. The Info.plist permits `$(PRODUCT_BUNDLE_IDENTIFIER).conversion.*` and enables the processing background mode. The current CPU/VideoToolbox pipeline does not request the separate background GPU resource.

Older systems and rejected requests use a UIKit background assertion. This provides limited, discretionary time; it is not a promise that a long encode will finish. If no assertion is available, the app asks the user to keep it open. Expiration stops the encoder, releases the assertion, and offers Retry from the beginning. Force-quitting does not preserve the job. Returning before expiration keeps the same encode running; leaving again does not guarantee a fresh allowance.

The first limited-time conversion requests notification permission. When backgrounded, a finite UIKit remaining-time estimate schedules one advisory local warning about ten seconds before the estimated deadline. Earlier estimates can move it forward. Returning, finishing, failing, or cancelling removes pending and delivered warnings, including adds that finish asynchronously. Permission denial, Focus, delayed notification delivery, and early system expiration can prevent advance notice. Extended tasks expose no comparable deadline and do not get an invented countdown.

Results enter the existing session/saved History store before background execution ends. Navigation waits for the app to become active. Inputs and working directories use protection that permits access after the first device unlock so locking the screen does not revoke file access during an active conversion.

Video acceleration and HDR color policy, software fallbacks, and physical-device benchmark instructions are documented in [the runtime guide](../Native/FFmpeg/README.md#accelerated-video-and-color-policy).
