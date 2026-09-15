# App Store screenshots

## iPhone 6.5-inch

Captured from the current Release build in an iPhone 13 Pro Max simulator running iOS 26.5 on September 14, 2026.

All five files are native **1284 × 2778** portrait JPEGs, RGB, with no alpha channel. This matches one of the accepted dimensions shown in the supplied App Store Connect 6.5-inch upload panel. The status bar is set to 9:41 with full signal and battery.

### Suggested upload order

| Order | Screenshot | Content |
| --- | --- | --- |
| 1 | [Import — light](iphone-6.5/01-import-light.jpg) | Photos, Files, From Link, and Clipboard import options |
| 2 | [Photo conversion](iphone-6.5/02-photo-conversion.jpg) | JPEG input, HEIC output, target size, and 1080p output selection |
| 3 | [Conversion result](iphone-6.5/03-conversion-result.jpg) | Actual conversion from 2.5 MB to 969 KB, 61% smaller; share and copy actions |
| 4 | [Crop and rotate](iphone-6.5/04-crop-and-rotate.jpg) | Image preview, crop dimensions, and rotation controls |
| 5 | [Import — dark](iphone-6.5/05-import-dark.jpg) | Main screen in dark mode |

Upload the JPEG files in numerical order. The original images are kept in Git; ZIP archives are generated locally and ignored. To create a handoff archive, run this from the repository root:

```sh
cd docs/app-store-screenshots/iphone-6.5
zip -j ../iphone-6.5-screenshots.zip *.jpg
```

The waterfall photo is a sample asset from the fresh simulator photo library. The app imported and converted it through its normal production workflow. Screenshots were exported directly with `simctl`; they have not been resized, composited, or retouched. No app source changes were made for these captures.

Simulator: `MB Converter App Store` (`12BB93A6-491E-4610-AAA2-8B8FB0B339E8`).

## iPad 13-inch

Captured from the current Release build on a dedicated iPad Pro 13-inch (M5) simulator running iPadOS 26.5 on September 14, 2026.

All five files are **2752 × 2064** landscape JPEGs, RGB, with no alpha channel. This is an accepted size for the App Store Connect **13-inch iPad** screenshot slot. See [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).

### Suggested upload order

| Order | Screenshot | Content |
| --- | --- | --- |
| 1 | [Import — light](ipad-13/01-import-light.jpg) | iPad sidebar and four import options |
| 2 | [Photo conversion](ipad-13/02-photo-conversion.jpg) | HEIC output, target size, and 1080p output selection |
| 3 | [Conversion result](ipad-13/03-conversion-result.jpg) | Actual conversion from 2.5 MB to 969 KB, 61% smaller; share and copy actions |
| 4 | [Crop and rotate](ipad-13/04-crop-and-rotate.jpg) | Native iPad crop editor with pixel dimensions and rotation controls |
| 5 | [Import — dark](ipad-13/05-import-dark.jpg) | Main iPad screen in dark mode |

Extract `ipad-13-screenshots.zip` and upload the JPEG files in numerical order. The ZIP contains only the five iPad images and is generated locally, like the iPhone archive:

```sh
cd docs/app-store-screenshots/ipad-13
zip -j ../ipad-13-screenshots.zip *.jpg
```

The iPad set uses the same waterfall sample and production conversion workflow as the iPhone set. Native simulator PNG captures were rotated 90 degrees to apply the device's landscape orientation and exported as JPEGs. No scaling, compositing, or retouching was applied. No app source changes were made.

Simulator: `MB Converter App Store iPad` (`5FF0AAE1-6E7C-4F82-9C9D-D07CDF2B42FF`).
