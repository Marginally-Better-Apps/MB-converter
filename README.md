# MB Converter

Native **iOS / iPadOS** app to convert and compress video, audio, and images. Built with **SwiftUI**, **FFmpegKit** (LGPL), and native image pipelines (ImageIO / Core Image).

| | |
|---|---|
| Platforms | iOS 17+, iPadOS 17+ |
| UI | SwiftUI, system typography, light haptics |
| Media | FFmpegKit for video/audio/animated workflows; ImageIO for still images |
| State | `@Observable` view models |

## Features

- Import from **Photos**, **Files**, or the **clipboard** (images)
- Inspect metadata, pick output format, resolution, frame rate, and target size where applicable
- **Video / audio / animated** conversion via FFmpeg command-line flows wrapped in Swift
- **Still images** via `ImageConverter` (including target-size passes)
- Conversion **history** and share/save using the system share sheet (output stays in temp until the user saves)

## Requirements

- Xcode 15+ (iOS 17 SDK)
- Swift 5.9+

## Build

1. Clone the repository.
2. Open `Converter.xcodeproj` in Xcode.
3. Select the **Converter** scheme and a simulator or device, then **Run**.

Command line (use a simulator that exists on your machine):

```sh
xcodebuild -scheme Converter -destination 'platform=iOS Simulator,name=iPhone 17' -quiet build
```

### Swift packages

Resolved via Swift Package Manager (see the project’s **Package Dependencies**):

| Package | Role |
|---------|------|
| [ffmpeg-kit-spm / `ffmpeg-kit-ios-https`](https://github.com/arthenica/ffmpeg-kit) | LGPL FFmpeg bindings — **use the LGPL variant** for App Store distribution (not the GPL build). |
| [libwebp-Xcode](https://github.com/SDWebImage/libwebp-Xcode) | WebP support where used by the pipeline. |

If you ship a binary, include notices required by **LGPL** (and any other licenses of linked libraries) in your app’s legal / credits screen; this repo’s **MIT license applies to the app source here**, not to FFmpeg itself.

## Repository layout

```
├── App/                 App entry point
├── Assets.xcassets      App icon and assets
├── Core/
│   ├── Compatibility/   Format matrix (allowed conversions)
│   ├── Conversion/      Converters, FFmpeg runner, routing
│   ├── Inspection/      Metadata / probe helpers
│   ├── IO/              Import, temp storage, history
│   └── Models/          Shared types
├── DesignSystem/        Theme and reusable UI pieces
├── Features/            Screens (Home, detail, config, processing, result, history)
└── Converter.xcodeproj
```


## License

This project’s **source code** is released under the [MIT License](LICENSE).

Third-party libraries (FFmpeg via FFmpegKit, libwebp, Apple frameworks) remain under their respective licenses.

## Color theme (reference)

```
            Light       Dark
text        #050b0f     #f0f6fa
background  #eff6fb     #0B1622
primary     #003a5c     #a3ddff
secondary   #7fc7f0     #0f5680
accent      #3cb2f6     #081d2a
```

In dark mode, primary actions use `Theme.primary` (see `DesignSystem/Theme.swift`).
