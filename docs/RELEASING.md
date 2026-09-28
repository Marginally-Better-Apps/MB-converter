# Releasing MB Converter for iOS

[Build and run](DEVELOPMENT.md) · [App Store listing copy](app-store-metadata.md) · [Screenshots](app-store-screenshots/README.md)

## Automatic GitHub releases with an IPA

The [Release IPA workflow](../.github/workflows/release.yml) runs on every push to `main`, including merged pull requests. It can also be started from **Actions → Release IPA → Run workflow**, with `main` selected.

Each successful run:

1. Installs the native build tools, builds and verifies the pinned FFmpeg runtime from source, and archives the pushed commit for iOS devices with Xcode 26.6 on the `macos-26` GitHub runner. WebP builds from its vendored sources.
2. Packages an **unsigned IPA** for signing and installation with AltStore or Sideloadly. The app's build number is the workflow run number; the marketing version comes from the Xcode project.
3. Creates a release such as `v1.1-build.12` with `MB-Converter-1.1-12-unsigned.ipa`, `MBConverter-corresponding-source.tar.gz`, and a SHA-256 checksum for each archive. The source bundle contains matching app/adapter sources, dependency archives, notices, and build configuration.

The workflow publishes only after the IPA passes validation and all four assets upload successfully. A failed upload leaves a draft that a rerun can complete. Rerunning an already published run verifies the expected assets exist and leaves that release intact. A failed build publishes nothing. Build logs are retained as Actions artifacts for seven days; release files are also kept as Actions artifacts for fourteen days and remain attached to the GitHub release afterward.

### Enable it

Commit and push the source, native packages, build scripts, and workflow to `main`. No Apple certificate, provisioning profile, App Store Connect key, or custom GitHub token is needed. The publishing job requests `contents: write` for GitHub's automatic `GITHUB_TOKEN`; the build job has read-only repository access. Repository or organization policies must allow GitHub Actions, the pinned official actions, and release/tag creation. See [GitHub's token permissions documentation](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).

Change `MARKETING_VERSION` in the Xcode project when you want a new app version. The workflow supplies `CURRENT_PROJECT_VERSION` at build time and does not commit version bumps back to the repository. The `v*-build.*` tag namespace is reserved for this workflow.

### Build the same unsigned IPA locally

```sh
# Install the native build tools first; see DEVELOPMENT.md.
python3 Scripts/BuildFFmpeg.py --platform ios
BUILD_NUMBER=12 bash Scripts/BuildUnsignedIPA.sh
```

The IPA, corresponding source bundle, both checksums, and build log appear in `build/ipa-release/`, which is ignored by Git. Omit `BUILD_NUMBER` to use the project's existing build number. An optional first argument changes the output directory.

This release is for sideloading: users must re-sign the IPA with their own account. It does not automatically submit to TestFlight or the App Store. Follow the signed archive process below for App Store distribution.

## Release configuration

| Setting | Value |
| --- | --- |
| Scheme / app target | `Converter` |
| Archive configuration | `Release` |
| Display name | MB Converter |
| Bundle identifier | `com.marginallybetter.converter` |
| Marketing version | `1.1` |
| Current build number | `3` |
| Minimum OS | iOS / iPadOS 17.0 |
| Devices | iPhone and iPad |

Use a build number that has not already been uploaded for this version. Update `CURRENT_PROJECT_VERSION` in both app configurations together. The repository is prepared as 1.1 (3); see the [changelog](../CHANGELOG.md).

## Repository preparation checks — September 28, 2026

Validation for version 1.1 (3) is recorded in [the release validation report](validation/release-1.1.md). Repository preparation covers unsigned packaging and host regressions. Signing, physical-device runtime checks of the final build, and App Store upload remain separate steps.

## Before archiving

- Build and verify the pinned native runtime, resolve the local packages, and run the unsigned Release build in the [build guide](DEVELOPMENT.md).
- Review and commit the intended source, project, lockfile, docs, and screenshot changes. Keep generated archives, debug symbols, logs, credentials, and screenshot ZIPs out of Git.
- Select the app's distribution team and verify signing access for the bundle identifier.
- Use an Xcode/SDK version accepted by [Apple's current submission requirements](https://developer.apple.com/news/upcoming-requirements/).

## Device smoke checks

Use the Release build on a physical iPhone and iPad, including iOS 17 where available. Record the device, OS version, and build number used.

- Import from Photos, Files, the clipboard, and a direct media link. Check cancellation, an invalid link, an unsupported file, and a link exceeding 150 MB.
- Convert a photo to JPEG, PNG, HEIC, WebP, and TIFF; verify crop, rotation, resolution, metadata removal, and a target-size conversion.
- Convert video to H.264 MP4, HEVC MP4, MOV, and WebM, including audio; extract audio to the supported formats. Check trimming, playback, orientation, audio synchronization, HDR preservation, and HDR-to-SDR output.
- Convert audio to MP3, FLAC, Ogg/Vorbis, Opus, M4A, AAC, and WAV; check trim, gain, speed, and channel edits against the preview. Convert an animated GIF to video and a still frame. Import AV1 and verify fallback thumbnails/playback, preparation progress, and cancellation.
- Cancel an active conversion, retry after a failure, and perform another conversion after success.
- Preview, rename, save, and share results. Confirm saved files open outside the app.
- Check session-only history after relaunch, saved history after relaunch, and deletion/disabling saved history.
- Review light/dark appearance, larger text, VoiceOver labels, and iPad rotation. Confirm diagnostics can be opened and exported after an error.

Run the shared scheme's `ConverterTests` suite as described in [Development](DEVELOPMENT.md). Automated checks do not replace the following physical-device background checks:

- On iOS 26+, start a long H.264/HEVC conversion, leave the app, and lock the screen. Verify Live Activity progress, successful output, and exactly one History entry on return. Repeat with two-pass WebM and unknown-duration input.
- Cancel through the system Live Activity; return and verify the interrupted state and Retry. Repeat cancellation from the app and immediately retry.
- On iOS 17–18, allow notifications, start a sufficiently long conversion, and leave the app. Verify the advance warning when iOS supplies enough notice; tap it before expiration and confirm the same attempt continues. Let a separate attempt expire and verify Retry starts from the beginning.
- Repeat with notifications denied, foreground return before warning delivery, completion before warning delivery, and multiple foreground/background visits. Confirm no stale or duplicate warnings.
- Verify a busy/denied scheduler falls back to limited execution and that a force-quit never promises automatic resumption.

Record device models, OS versions, results, and any system-denied scheduling separately from build validation.

## Archive and validate

In Xcode, select **Converter → Any iOS Device (arm64)**, then **Product → Archive**. The shared scheme archives with Release settings. In Organizer, use **Validate App**, then **Distribute App → App Store Connect** when ready to upload.

For a signed command-line archive with signing already configured:

```sh
xcodebuild \
  -project Converter.xcodeproj \
  -scheme Converter \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/MB-Converter.xcarchive \
  -derivedDataPath build/DerivedData \
  -onlyUsePackageVersionsFromResolvedFile \
  archive
```

Do not pass `CODE_SIGNING_ALLOWED=NO` for the archive you intend to distribute. Keep the resulting archive and dSYMs in secure release storage for crash symbolication; they are ignored by Git.

Inspect the archive to confirm:

- Version, build number, identifier, app icon, device families, and deployment target are correct.
- `PrivacyInfo.xcprivacy` is present in `Products/Applications/Converter.app`.
- The app embeds the single device-arm64 `MBFFmpegBridge.framework` with its build manifest and licenses, plus `WebP-NOTICE.txt`. The framework source hashes must match the release source bundle.
- Organizer validation and the processed App Store Connect build have no unresolved errors.

## Remaining submission work

Repository preparation does not complete the App Store Connect listing. Before submitting version 1.1:

- Finalize the support URL/contact information and copyright owner marked pending in the [listing copy](app-store-metadata.md).
- Publish the [Privacy Policy](../PRIVACY.md) at a public URL and make it accessible in the app and listing. Complete App Store Connect's privacy questionnaire against the actual shipped app and dependencies.
- Review the archive's privacy report. The app manifest declares `CA92.1` for its own preferences and `C617.1` for timestamps of files in its container. Audit third-party required-reason API usage separately; an app manifest is not a substitute for reviewing bundled SDKs. See [Apple's approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- Run `python3 Scripts/VerifyFFmpeg.py`, then `python3 Scripts/BundleFFmpegSources.py` after the final runtime build. Publish the corresponding source archive/checksum with the release, record its immutable URL, and verify the app's source/license links expose those exact materials. Verify third-party notices and source/relinking materials for the exact FFmpeg binaries being distributed. See the [runtime distribution instructions](../Native/FFmpeg/README.md), [FFmpeg license checklist](https://ffmpeg.org/legal.html), and dependencies' license files.
- Complete export-compliance, age-rating, availability, pricing, and App Review contact fields based on the actual app and developer account. Do not infer these declarations from the app's MIT license.
- Upload screenshots for the iPhone and iPad display sizes requested by App Store Connect. The repository currently contains a 6.5-inch iPhone set; check current requirements and capture any additional required sizes from the final build.
- Provide review notes explaining that no account is needed and how to import, convert, and share a file. Select the validated build and submit for review.

After version 1.1 is publicly available, tag the source revision used for that App Store release. The [main README](../README.md) already links to the App Store product.
