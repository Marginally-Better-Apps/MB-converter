# MB Converter

**Convert and compress** photos, video, and audio on your iPhone and iPad. This repository is being rebuilt as an **iOS-only Expo / React Native** app on the `react-native-port` branch. The previous SwiftUI app lives in [`legacy/swift/`](legacy/swift/) for reference.

## Get the beta

<p>
  <a href="https://testflight.apple.com/join/FEA9U9HB">
    <img alt="Join on TestFlight" src="https://img.shields.io/badge/TestFlight-Join%20Beta-0A84FF?style=for-the-badge&logo=apple&logoColor=white" />
  </a>
</p>

**App Icon**

<img src="legacy/swift/Assets.xcassets/AppIcon.appiconset/AppIcon-ios-marketing-1024x1024@1x.png" alt="MB Converter app icon" width="8%" />

**Main Screen Preview** (legacy Swift UI)

<table>
  <tr>
    <td align="center">
      <strong>Light</strong><br />
      <img src="legacy/swift/docs/light_mainpage.png" alt="MB Converter light main screen" width="180" />
    </td>
    <td align="center">
      <strong>Dark</strong><br />
      <img src="legacy/swift/docs/dark_mainpage.png" alt="MB Converter dark main screen" width="180" />
    </td>
  </tr>
</table>

## Develop (Expo)

Requires Node 20+, Xcode 15+, iOS 17+ Simulator.

```sh
npm install
./scripts/download-ffmpeg-frameworks.sh   # once; vendors FFmpegKit min.v5.1.2.6 xcframeworks
npm test
npx expo run:ios                          # Dev Client (required for FFmpeg)
```

**Custom Dev Client required for conversion.** Expo Go cannot load the native FFmpeg module. Use `npx expo run:ios` (or an EAS development build), not Expo Go.

FFmpeg binaries are downloaded (not committed). See [`AGENTS.md`](AGENTS.md) and [`CREDITS.md`](CREDITS.md) (LGPL).

Bundle ID: `com.marginallybetter.converter` · Display name: **MB Converter**

Agent / port notes: see [`AGENTS.md`](AGENTS.md). Legacy Swift developer docs: [`legacy/swift/docs/DEVELOPMENT.md`](legacy/swift/docs/DEVELOPMENT.md).

## License

The app’s source code is under the [MIT License](LICENSE). FFmpeg / FFmpegKit retain LGPL (and related) terms — see [`CREDITS.md`](CREDITS.md).

## More projects

Check out our other projects at [marginally-better.app](https://marginally-better.app).
