# Custom FFmpeg build assessment

Research date: September 15, 2026. This is an engineering recommendation, not a completed build or a legal certification of App Store eligibility.

This document records the pre-implementation investigation. For the implemented runtime and current validation/distribution steps, see [Native/FFmpeg/README.md](../Native/FFmpeg/README.md).

MP3 export and substantially broader format support are feasible. For a conservative licensing profile, build upstream FFmpeg under LGPL 2.1 with a selected set of external libraries, package it as signed iOS frameworks inside XCFrameworks, and replace the LGPLv3 FFmpegKit wrapper with an independently implemented adapter. This requires an engine migration, not just changing a package URL. Start with MP3/FLAC/Opus/Vorbis, then validate WebM export and AV1 import on devices.

## What this app currently ships

The project pins `tylerjonesio/ffmpeg-kit-spm` at `6053b0e4f8607314ff5e14e0b18fc250c0f87c9b`; its package manifest selects `min.v5.1.2.6`, documented as FFmpeg 5.1.2. The cached device framework's embedded configuration enables `--enable-version3`, and its license string says LGPL version 3 or later. The FFmpegKit wrapper's own license is also LGPLv3. “Min” does not mean LGPL2.1.

The binary configuration disables encoders and muxers globally, then enables a narrow list. LAME, FLAC and Opus encoding and MP3/FLAC/Ogg/WebM muxing are absent from those lists. MP3 input decoding and MP3 output encoding are separate capabilities.

Local evidence: `Converter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`, cached `build/SourcePackages/checkouts/ffmpeg-kit-spm/Package.swift`, its `LICENSE`, and the device `libavcodec.framework/libavcodec` configuration strings. Build-cache paths are evidence from this checkout, not tracked dependencies.

## Proposed capabilities

| Feature | Build components | App work |
| --- | --- | --- |
| MP3 export and audio extraction | LAME / `libmp3lame`, MP3 muxer | Enable output; fix capability detection |
| FLAC export | FFmpeg native FLAC encoder and muxer | Enable output; preserve lossless settings |
| Ogg/Vorbis export | libvorbis, libogg dependency, Ogg muxer | Enable output; fix inspection/routing |
| Opus export | libopus, Ogg/Opus muxing | Enable output; fix inspection/routing |
| WebM export | libvpx VP9, libopus, WebM muxer | Enable existing video path; tune and measure performance |
| AV1 input | dav1d and relevant demuxers | Replace unconditional AV1 rejection with capability check |
| Existing H.264/HEVC export | Apple VideoToolbox | Preserve hardware encoding |

LAME is LGPL; Opus, Vorbis, libvpx and dav1d have permissive library licenses. Exact dependency versions, notices and applicable patent terms still need to be retained/reviewed. See [LAME](https://lame.sourceforge.io/), [Opus licensing](https://opus-codec.org/license/), [Vorbis](https://xiph.org/vorbis/), [WebM software license](https://www.webmproject.org/license/software/) and [dav1d COPYING](https://github.com/videolan/dav1d/blob/master/COPYING). FFmpeg documents the encoder/decoder integrations in its [codec reference](https://ffmpeg.org/ffmpeg-codecs.html).

AV1 decoding does not provide AV1 encoding. Defer AV1 export until its size, speed, memory and thermal costs justify another encoder. Keep existing ImageIO/Core Image/libwebp image paths. Adding conversion support also does not make AVKit previews support every output.

## Build choices

| Approach | Benefit | Limitation |
| --- | --- | --- |
| Own upstream FFmpeg build plus original adapter | Control versions, formats and an LGPL2.1 licensing profile | Highest integration effort; command execution/probing must be replaced |
| Self-build FFmpegKitNext | Maintained continuation with familiar command/session APIs | Wrapper and produced bundles remain LGPLv3; requires reviewing that distribution model |
| Enlarge the existing 5.1.2 fork | Closest to today's app | Retains old code and LGPLv3; existing recipe follows a moving source branch |

As of this research, [upstream FFmpeg](https://ffmpeg.org/download.html) lists 9.0.1 as its latest stable release. [FFmpegKitNext](https://github.com/arthenica/ffmpeg-kit-next) lists version 9.0.0 built around FFmpeg 9.0.1. Its license section explicitly says its scripts always enable version 3. Removing a configure flag does not relicense the wrapper. A maintained successor exists, so the choice is not limited to abandoned FFmpegKit binaries.

For the first approach, use a pinned source release and original C/Objective-C/Swift integration over libavformat/libavcodec/libavfilter. Alternatively, adapting upstream `fftools` into an in-process command runner requires maintaining lifecycle, cancellation and repeated-execution patches. Building standalone FFmpeg executables alone will not replace `FFmpegKit.executeAsync` in this iOS app. Do not copy LGPLv3 wrapper code into an adapter claimed to have an LGPL2.1-only dependency profile.

Suggested FFmpeg configuration policy, **not a complete cross-compilation command**:

```text
--disable-gpl --disable-nonfree --disable-version3
--disable-autodetect --enable-shared --disable-static
--enable-libmp3lame --enable-libopus --enable-libvorbis
--enable-libvpx --enable-libdav1d
--enable-videotoolbox --enable-audiotoolbox
--disable-network --disable-devices --disable-doc
```

These options follow the [upstream configure interface](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n9.0.1/configure). Cross-compilation still needs SDK/architecture flags, built dependencies and framework packaging. Preserve required system compression libraries explicitly with autodetection disabled. Either retain the default non-GPL codec/container set or audit a complete allowlist: adding external libraries to the existing narrow encoder/muxer lists is insufficient. The app already downloads files through URLSession, allowing FFmpeg networking/TLS dependencies to be omitted. Keep native AAC; avoid unnecessary GPL or version-3-only dependencies, including x264/x265 and GMP, in this profile.

Pin dependency commits/tarball hashes and toolchain versions; build arm64 iOS device frameworks and separate simulator slices as needed. Package with `xcodebuild -create-xcframework`, publish immutable checksummed SwiftPM artifacts with their source archives, and embed/sign only the appropriate device slice. Measure installed size and encoding speed rather than estimating savings from package names.

## App Store and license requirements

Apple's rules permit assessing this as bundled native functionality: use public APIs, keep executable code inside the submitted app, and use permitted file access. Do not download codec plugins at runtime. This is an engineering reading of [guidelines 2.5.1–2.5.2](https://developer.apple.com/app-store/review/guidelines/#software-requirements), not Apple preapproval of a particular build.

Separately, [FFmpeg's compliance guidance](https://ffmpeg.org/legal.html) calls for the appropriate license, attribution and exact corresponding source/build changes, including LGPL dependencies such as LAME. Prefer dynamic frameworks, but dynamic linking by itself does not establish compliance on iOS.

[LGPL2.1 section 6](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/COPYING.LGPLv2.1) requires preserving modification/reverse-engineering rights and a qualifying relinking route. Because MB Converter is MIT/open source, provide the matching application source, all necessary library source/patches, build instructions and materials needed to rebuild with modified libraries. Document and verify rebuilding/re-signing with the recipient's development identity; never distribute production signing credentials. Have the actual distribution terms and iOS signing constraints reviewed rather than assuming a GitHub link is sufficient.

LGPLv3 adds requirements concerning installation information when applicable; [section 4](https://raw.githubusercontent.com/FFmpeg/FFmpeg/master/COPYING.LGPLv3) defines the conditions. This is why an LGPL2.1 profile is the more conservative recommendation, not a claim that Apple has a blanket ban on LGPLv3. The current build needs that review too. Apple's [standard EULA](https://www.apple.com/legal/internet-services/itunes/dev/stdeula/) includes an open-source exception to certain restrictions, but that does not settle every license/distribution obligation.

MP3 is not inherently a GPL feature or an App Store prohibition. Fraunhofer confirms that its/Technicolor's [MP3 licensing program ended in 2017](https://www.iis.fraunhofer.de/en/ff/amm/consumer-electronics/mp3.html?t=i). This does not eliminate the LAME copyright license or establish patent clearance for every other codec.

## Required integration and validation

1. Update `Core/Compatibility/FormatMatrix.swift`: MP3, FLAC, Ogg, Opus and WebM are currently excluded before capability filtering.
2. Replace library-name guesses in `CodecCapability.swift`/`FFmpegRuntimeInfo.swift` with actual encoder, decoder and muxer availability. The current wrapper catalog uses names such as `mp3lame` and `opus`, whereas the app requests `libmp3lame` and `libopus`. FLAC/native Opus availability is currently assumed incorrectly for this binary.
3. Add FFmpeg-based audio inspection in `Core/Inspection/MediaInspector.swift`. Route FFmpeg conversions before the AVFoundation track requirement in `Core/Conversion/AudioConverter.swift`; otherwise non-native input formats and inspection of new outputs can still fail.
4. Replace the AV1 rejection only when a usable decoder exists. Preserve preview fallbacks for files Apple cannot play.
5. Migrate runner/session cancellation, progress, FFprobe metadata/tag discovery and runtime diagnostics if replacing FFmpegKit. Add accessible third-party notices and release-specific source/rebuild links.
6. Validate actual device encode/probe/decode round trips: WAV→MP3, multichannel FLAC→MP3, Ogg/Opus input, FLAC losslessness, WebM A/V sync and AV1→H.264. Exercise metadata, cancellation, repeated conversions and existing formats. Check codec/muxer/license inventory, archive signing, app size and performance before submission.

The initial investigation inspected sources and cached binaries and checked primary upstream/Apple documentation. It did not establish App Review approval.
