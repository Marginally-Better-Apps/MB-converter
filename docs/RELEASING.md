# Releasing MB Converter for iOS

[Build and run](DEVELOPMENT.md) · [App Store listing copy](app-store-metadata.md) · [Screenshots](app-store-screenshots/README.md)

## Automatic GitHub releases with an IPA

The [Release IPA workflow](../.github/workflows/release.yml) runs on every push to `main`, including merged pull requests. It can also be started from **Actions → Release IPA → Run workflow**, with `main` selected.

Each successful run:

1. Archives the pushed commit for iOS devices with Xcode 26.6 on the `macos-26` GitHub runner, using the checked-in dependency versions.
2. Packages an **unsigned IPA** for signing and installation with AltStore or Sideloadly. The app's build number is the workflow run number; the marketing version comes from the Xcode project.
3. Creates a release such as `v1.0-build.12` with `MB-Converter-1.0-12-unsigned.ipa` and its SHA-256 checksum attached.

The workflow publishes only after the IPA passes validation and both assets upload successfully. A failed upload leaves a draft that a rerun can complete. Rerunning an already published run verifies the expected assets exist and leaves that release intact. A failed build publishes nothing. Build logs are retained as Actions artifacts for seven days; release files are also kept as Actions artifacts for fourteen days and remain attached to the GitHub release afterward.

### Enable it

Commit and push the workflow and `Scripts/BuildUnsignedIPA.sh` to `main`. No Apple certificate, provisioning profile, App Store Connect key, or custom GitHub token is needed. The publishing job requests `contents: write` for GitHub's automatic `GITHUB_TOKEN`; the build job has read-only repository access. Repository or organization policies must allow GitHub Actions, the pinned official actions, and release/tag creation. See [GitHub's token permissions documentation](https://docs.github.com/en/actions/tutorials/authenticate-with-github_token).

Change `MARKETING_VERSION` in the Xcode project when you want a new app version. The workflow supplies `CURRENT_PROJECT_VERSION` at build time and does not commit version bumps back to the repository. The `v*-build.*` tag namespace is reserved for this workflow.

### Build the same unsigned IPA locally

```sh
BUILD_NUMBER=12 bash Scripts/BuildUnsignedIPA.sh
```

The IPA, checksum, and build log appear in `build/ipa-release/`, which is ignored by Git. Omit `BUILD_NUMBER` to use the project's existing build number. An optional first argument changes the output directory.

This release is for sideloading: users must re-sign the IPA with their own account. It does not automatically submit to TestFlight or the App Store. Follow the signed archive process below for App Store distribution.

## Release configuration

| Setting | Value |
| --- | --- |
| Scheme / app target | `Converter` |
| Archive configuration | `Release` |
| Display name | MB Converter |
| Bundle identifier | `com.marginallybetter.converter` |
| Marketing version | `1.0` |
| Current build number | `2` |
| Minimum OS | iOS / iPadOS 17.0 |
| Devices | iPhone and iPad |

Use a build number that has not already been uploaded for this version. Update `CURRENT_PROJECT_VERSION` in both app configurations together. Keep version 1.0 for the first release unless the App Store Connect record requires otherwise.

## Repository preparation checks — September 14, 2026

- Unsigned device Release build passed with Xcode 26.6 and the iOS 26.5 SDK using the pinned dependencies.
- The packaged app reports version 1.0 (2), iOS 17 minimum, and both iPhone and iPad support. Its privacy manifest matches the source manifest.
- All nine embedded frameworks contain only `arm64`; the architecture-stripping phase completed successfully.
- Documentation links, project/manifest syntax, and Git ignore rules passed validation. No tracked build artifacts or credentials needed removal.
- Existing warnings remain: 17 unassigned dark app-icon images in the asset catalog and Swift concurrency warnings in `ImportService` and `AudioConverter`. Review the icon catalog before submission and the concurrency warnings before adopting Swift 6 language mode. App Intents metadata extraction also reports that it is skipped because the app has no App Intents dependency.

This was a compilation and packaging check. No simulator or physical-device runtime tests, signed archive validation, or App Store upload were performed during repository preparation.

## Before archiving

- Resolve the checked-in packages and run the unsigned Release build in the [build guide](DEVELOPMENT.md).
- Review and commit the intended source, project, lockfile, docs, and screenshot changes. Keep generated archives, debug symbols, logs, credentials, and screenshot ZIPs out of Git.
- Select the app's distribution team and verify signing access for the bundle identifier.
- Use an Xcode/SDK version accepted by [Apple's current submission requirements](https://developer.apple.com/news/upcoming-requirements/).

## Device smoke checks

Use the Release build on a physical iPhone and iPad, including iOS 17 where available. Record the device, OS version, and build number used.

- Import from Photos, Files, the clipboard, and a direct media link. Check cancellation, an invalid link, an unsupported file, and a link exceeding 150 MB.
- Convert a photo to JPEG, PNG, HEIC, WebP, and TIFF; verify crop, rotation, resolution, metadata removal, and a target-size conversion.
- Convert video to H.264 MP4, HEVC MP4, and MOV, including audio; extract M4A, AAC, and WAV. Check playback, orientation, and audio synchronization.
- Convert an audio file and an animated GIF. Confirm the GIF-to-image path exports a still frame and that an AV1 video produces a useful unsupported-format message.
- Cancel an active conversion, retry after a failure, and perform another conversion after success.
- Preview, rename, save, and share results. Confirm saved files open outside the app.
- Check session-only history after relaunch, saved history after relaunch, and deletion/disabling saved history.
- Review light/dark appearance, larger text, VoiceOver labels, and iPad rotation. Confirm diagnostics can be opened and exported after an error.

The repository has no automated test suite yet. These checks must be performed and recorded separately from build validation.

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
- The existing **Strip Invalid Framework Architectures** build phase removed unsupported `arm64e` slices from embedded FFmpeg frameworks and re-signed modified frameworks.
- Organizer validation and the processed App Store Connect build have no unresolved errors.

## Remaining submission work

Repository preparation does not complete the App Store Connect listing. Before submitting version 1.0:

- Finalize the support URL/contact information and copyright owner marked pending in the [listing copy](app-store-metadata.md).
- Publish the [Privacy Policy](../PRIVACY.md) at a public URL and make it accessible in the app and listing. Complete App Store Connect's privacy questionnaire against the actual shipped app and dependencies.
- Review the archive's privacy report. The app manifest declares `CA92.1` for its own preferences and `C617.1` for timestamps of files in its container. Audit third-party required-reason API usage separately; an app manifest is not a substitute for reviewing bundled SDKs. See [Apple's approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).
- Verify third-party notices and source/relinking materials for the exact FFmpegKit/FFmpeg binaries being distributed, and include accessible acknowledgements. See the [FFmpeg license checklist](https://ffmpeg.org/legal.html) and the dependencies' license files.
- Complete export-compliance, age-rating, availability, pricing, and App Review contact fields based on the actual app and developer account. Do not infer these declarations from the app's MIT license.
- Upload screenshots for the iPhone and iPad display sizes requested by App Store Connect. The repository currently contains a 6.5-inch iPhone set; check current requirements and capture any additional required sizes from the final build.
- Provide review notes explaining that no account is needed and how to import, convert, and share a file. Select the validated build and submit for review.

After the app is publicly available, replace the TestFlight install link in the [main README](../README.md) with the verified App Store product link and tag the source revision used for that release.
