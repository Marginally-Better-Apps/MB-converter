# Build and run MB Converter

MB Converter is a native SwiftUI app for iOS and iPadOS 17 or later. Video and audio conversion use FFmpegKit; still images use ImageIO, Core Image, and libwebp.

[App overview](../README.md) · [Release guide](RELEASING.md)

## Requirements

- A Mac with **Xcode 26 or later**, its command-line tools, and the iOS SDK installed. The project uses Swift 5 language mode; you do not need a separate Swift installation.
- Internet access for the initial Swift package and binary-framework downloads.
- For a physical device: an Apple account added in Xcode, a signing team, and an iPhone or iPad running iOS/iPadOS 17 or later with Developer Mode enabled.
- For App Store distribution: an Apple Developer Program membership and access to this app in App Store Connect.

The deployment target remains iOS 17. Building with a newer SDK does not raise that minimum. App Store uploads currently require Xcode 26 or later and the iOS 26 SDK or later; check [Apple's current requirements](https://developer.apple.com/news/upcoming-requirements/) before submitting.

## Run in Xcode

```sh
git clone https://github.com/Marginally-Better-Apps/MB-converter.git
cd MB-converter
open Converter.xcodeproj
```

1. Let Xcode resolve the Swift package dependencies.
2. Select the **Converter** scheme.
3. Select an installed iPhone/iPad simulator or a connected device as the run destination.
4. For a physical device, open the **Converter** target's **Signing & Capabilities**, select your own team, and use a unique bundle identifier for your personal build. Enable automatic signing. The checked-in team and bundle identifier belong to the published app's maintainers.
5. Choose **Product → Run** (`⌘R`).

No API keys, backend services, CocoaPods, or environment files are needed. Local file conversion can run offline once the app and dependencies are installed. Hardware-backed video encoders should also be tested on a real device.

## Build from the command line

Run commands from the repository root. Check the selected toolchain with `xcodebuild -version`; if it points at Command Line Tools instead of Xcode, select the Xcode installation in **Xcode → Settings → Locations**.

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
| [ffmpeg-kit-spm](https://github.com/tylerjonesio/ffmpeg-kit-spm) | Revision `6053b0e4f8607314ff5e14e0b18fc250c0f87c9b`, referencing binary release `min.v5.1.2.6` | FFmpeg 5.1.2 media conversion and probing |
| [libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode) | 1.6.0 in `Package.resolved` | Still WebP encoding |

Keep [`Package.resolved`](../Converter.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved) in Git. FFmpegKit is pinned to a revision in the Xcode project. Review dependency updates and commit the resulting lockfile changes together; release builds use `-onlyUsePackageVersionsFromResolvedFile` to prevent silent re-resolution.

FFmpegKit downloads prebuilt XCFrameworks from the package's GitHub release. If resolution fails, check the download error and access to those assets before changing versions. Build caches and downloaded packages are ignored; the lockfile, shared scheme, source assets, and original release screenshots are retained.

### Format support

`Core/Compatibility/FormatMatrix.swift` defines the outputs offered for each input category. `CodecCapability.swift` handles encoder availability and import checks. `FFmpegRuntimeInfo.swift` reports the bundled runtime configuration.

The app offers MP4 (H.264/HEVC), MOV, M4A, AAC, WAV, JPEG, PNG, HEIC, WebP, and TIFF output. GIF inputs can become MP4 or a still image. AV1 video is blocked at import. Additional encoders named in the code do not imply that those formats are offered in the UI.

## Repository layout

| Path | Contents |
| --- | --- |
| `App/` | App entry point, navigation, appearance, privacy manifest |
| `Assets.xcassets/` | App icon and assets |
| `Core/` | Conversion, metadata inspection, format compatibility, imports, history, diagnostics, models |
| `DesignSystem/` | System appearance bridge, haptics, reusable controls |
| `Features/` | Import, editing, conversion, results, history, and diagnostics screens |
| `Scripts/` | Build-time removal of unsupported framework architectures |
| `Converter.xcodeproj/` | Project, shared scheme, dependency lockfile |
| `docs/` | Build/release guides, listing copy, original screenshots |

## Appearance

The interface uses system typography, semantic colors, native controls, and system spacing. iOS 26 uses Liquid Glass for floating controls and action groups. iOS 17 and 18 use the matching system material fallback. `DesignSystem/Theme.swift` only bridges older call sites to Apple semantic colors and contains no app palette.

## Storage and diagnostics

Imported files and conversion working files use the app's temporary directory and are cleaned at launch. Session-only history is also cleared on the next launch. Saved history copies output files into Application Support until the user deletes them or disables saved history.

Settings → Error Log displays diagnostics and supports copying or exporting a report. Reports may contain file paths, media metadata, conversion commands, and device information. They are not automatically uploaded; review reports before sharing them publicly.

`App/PrivacyInfo.xcprivacy` declares app-local preferences and file timestamp access. Revisit those declarations whenever storage, diagnostics, networking, or dependencies change.

## Validation

The project currently has an empty `ConverterTests` target and no testables in the shared scheme. A successful build is not a passing automated test suite. Use the device smoke checks in the [release guide](RELEASING.md) before shipping.

## License

The application source is under the [MIT License](../LICENSE). FFmpegKit, FFmpeg, libwebp, and other bundled libraries have their own licenses. Retain their notices and review the exact distributed binaries and corresponding source before release. The app's MIT license does not relicense its dependencies.
