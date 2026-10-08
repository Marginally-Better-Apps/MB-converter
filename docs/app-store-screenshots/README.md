# App Store screenshots — 1.1

Captured October 4, 2026 from **Release 1.1 (3)**, source commit `1762c06`, on iOS/iPadOS 26.5. Each current set contains eight native JPEG screenshots, RGB with no alpha channel, and a 9:41 status bar with full signal and battery.

| App Store Connect slot | Folder | Dimensions | Orientation |
| --- | --- | --- | --- |
| iPhone 6.5-inch | [iphone-6.5](iphone-6.5/) | 1284 × 2778 | Portrait |
| iPad 13-inch | [ipad-13](ipad-13/) | 2752 × 2064 | Landscape |

These sizes match [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/), checked October 4, 2026. The 6.5-inch iPhone set can be supplied when a 6.9-inch set is not provided; the 13-inch iPad set covers the required iPad slot.

## Upload order

Extract the appropriate ZIP and upload the eight JPEGs in numerical order.

| Order | Content | iPhone | iPad |
| --- | --- | --- | --- |
| 1 | Refreshed import screen: Photos, Videos, Files, From Link, and Clipboard | [View](iphone-6.5/01-import-light.jpg) | [View](ipad-13/01-import-light.jpg) |
| 2 | JPEG → HEIC with a 1 MB target at original resolution | [View](iphone-6.5/02-photo-conversion.jpg) | [View](ipad-13/02-photo-conversion.jpg) |
| 3 | Actual conversion: 2.5 MB → 962 KB, 61% smaller, with Share and Copy | [View](iphone-6.5/03-conversion-result.jpg) | [View](ipad-13/03-conversion-result.jpg) |
| 4 | Video editor with selected trim range, crop, rotation, and playback speed controls | [View](iphone-6.5/04-video-editing.jpg) | [View](ipad-13/04-video-editing.jpg) |
| 5 | Audio editor with waveform trim, Mono channels, volume, and speed controls | [View](iphone-6.5/05-audio-editing.jpg) | [View](ipad-13/05-audio-editing.jpg) |
| 6 | Audio output menu showing M4A, MP3, WAV, AAC, FLAC, OGG, and Opus | [View](iphone-6.5/06-audio-formats.jpg) | [View](ipad-13/06-audio-formats.jpg) |
| 7 | Photo crop editor with pixel dimensions, rotation, and mirroring controls | [View](iphone-6.5/07-crop-and-rotate.jpg) | [View](ipad-13/07-crop-and-rotate.jpg) |
| 8 | Refreshed import screen in dark mode | [View](iphone-6.5/08-import-dark.jpg) | [View](ipad-13/08-import-dark.jpg) |

## ZIP handoff

The local handoff files are `release-1.1-iphone-6.5.zip` and `release-1.1-ipad-13.zip`. ZIPs are ignored by Git; the JPEGs and this guide are tracked. Recreate the archives from the repository root:

```sh
zip -j docs/app-store-screenshots/release-1.1-iphone-6.5.zip docs/app-store-screenshots/iphone-6.5/*.jpg
zip -j docs/app-store-screenshots/release-1.1-ipad-13.zip docs/app-store-screenshots/ipad-13/*.jpg
```

The older `ipad-13-screenshots/` folder contains September 14 captures and is not part of this release's upload set.

## Capture details

Screenshots were exported directly with `xcrun simctl io <device> screenshot --type=jpeg`. No resizing, compositing, retouching, or app source changes were made. The iPad captures were exported in landscape directly, without post-capture rotation.

The existing waterfall photo, six-second waterfall video, and twenty-second audio sample were imported through the app's production Files/link workflows. Link imports used a temporary localhost server. The result file was renamed to `Waterfall.heic` through the app's Rename action. Generated input filenames remain visible wherever the release app displays them. The photo conversion preserved its 3000 × 2002 resolution on both devices.

All sixteen files were visually reviewed and checked for dimensions, RGB color, and absence of alpha. Both ZIPs were checked for integrity and byte-for-byte agreement with the source JPEGs.

| Simulator | Model | Device ID |
| --- | --- | --- |
| MB Converter App Store | iPhone 13 Pro Max | `12BB93A6-491E-4610-AAA2-8B8FB0B339E8` |
| MB Converter App Store iPad | iPad Pro 13-inch (M5) | `5FF0AAE1-6E7C-4F82-9C9D-D07CDF2B42FF` |

The simulator build uses the native ARM64 FFmpeg slice:

```sh
xcodebuild -project Converter.xcodeproj -scheme Converter \
  -configuration Release \
  -destination 'platform=iOS Simulator,id=12BB93A6-491E-4610-AAA2-8B8FB0B339E8' \
  -derivedDataPath build/AppStoreScreenshots \
  -onlyUsePackageVersionsFromResolvedFile \
  CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build
```
