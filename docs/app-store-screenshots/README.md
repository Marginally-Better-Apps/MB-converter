# App Store screenshots

Captured from the current Release build in an iPhone 13 Pro Max simulator running iOS 26.5 on September 14, 2026.

All five files are native **1284 × 2778** portrait JPEGs, RGB, with no alpha channel. This matches one of the accepted dimensions shown in the supplied App Store Connect 6.5-inch upload panel. The status bar is set to 9:41 with full signal and battery.

## Suggested upload order

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
