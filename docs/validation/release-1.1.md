# Version 1.1 repository validation

Date: September 28, 2026. Repository version: **1.1 (3)**.

## Build and packaging

- Rebuilt the pinned FFmpeg device and Apple Silicon simulator framework slices from cached source with Xcode 27.0 (27A266a). Rebuilt the macOS framework for host regression tests. No simulator was launched.
- Verified FFmpeg source/recipe/adapter/patch identities, framework architectures, dynamic linkage, required codec/filter symbols, bundled notices, and build configuration.
- Verified vendored libwebp hashes and ARM64 NEON/threading flags.
- Built an unsigned Release archive with `bash Scripts/BuildUnsignedIPA.sh build/release-1.1`. The IPA reports version 1.1 (3), bundle identifier `com.marginallybetter.converter`, iOS 17.0 minimum, and iPhone/iPad support.
- Validated the IPA ZIP, executable, privacy manifest, FFmpeg framework/build manifest/license, WebP notice, and absence of signatures/provisioning profiles.
- Built the shared `ConverterTests` target with `build-for-testing` for `generic/platform=iOS`. This compiles the tests; it does not execute them.
- Checked the corresponding source archive preserves WebP public-header symlinks, dependency archives, source files, notices, and build recipes.

## Host regressions

All of these passed against the current sources:

```sh
bash Scripts/TestAutoTargetPlanner.sh
bash Scripts/TestFormatCapabilities.sh
python3 Scripts/TestFFmpegSwiftAdapter.py
python3 Native/MBFFmpegBridge/tests/run_tests.py
python3 Native/MBFFmpegBridge/tests/test_video_pipeline.py
python3 Scripts/TestAudioEditing.py
python3 Scripts/TestAudioWaveform.py
python3 Scripts/TestClipboardImports.py --ffmpeg
python3 Scripts/TestRemoteImports.py --ffmpeg-framework build/ffmpeg/macos-arm64/MBFFmpegBridge.framework
python3 Scripts/TestImageConversion.py --ffmpeg
python3 Scripts/TestMediaPreview.py
```

The audio suite's old assertion incorrectly expected video exports to discard every audio edit. It now checks that volume/channels are retained, audio trim/speed cannot desynchronize video, and effects disable unchanged stream-copy output. Conversion tests independently verify PCM samples, pitch, duration, channels, and compressed output.

## Release automation

- Parsed the workflow YAML and syntax-checked every shell block and the IPA packaging script.
- Exercised the publish shell locally with a stub GitHub CLI: new release, resumed draft, already-published release, missing published source assets, corrupt source checksum, and upload failure. Successful paths require the IPA, corresponding source, and both checksums; failure paths do not publish.
- The workflow builds the native runtime before archiving and uploads all four release assets. A live GitHub Actions run was not triggered during preparation.
- Checked project/plist syntax, metadata lengths, source-bundle contents, and Git whitespace/ignore rules.

## Remaining distribution checks

- Existing asset-catalog warnings report 17 unassigned dark icon variants. App Intents metadata extraction is skipped because there is no App Intents dependency. Host tests also report macOS 27 AVFoundation deprecation warnings.
- Physical-device runtime tests of this final package, signed archive validation, and App Store submission were not performed. Prior device measurements remain in the video acceleration report; they do not replace final-build checks.
- Follow [the release checklist](../RELEASING.md) for device smoke tests and pending App Store listing fields. No binaries, sources, tags, or releases were pushed or published during repository preparation.

Generated archives and logs are under ignored `build/` paths.
