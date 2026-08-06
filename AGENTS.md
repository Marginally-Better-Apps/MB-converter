# MB Converter — agent notes (Expo port)

iOS-only Expo / React Native rebuild of MB Converter. Plan: https://planista.shloklab.us/qmzH-8FH2l9RYimT (v4).

## Branch model

| Branch | Role |
|--------|------|
| `main` | Shipping Swift app today; receive **one** final cutover PR |
| `react-native-port` | Integration branch (fake-main for the port) |
| `epic-*` / `fix-*` | Feature or CI fix branches |

- Epic work may open GitHub PRs **into `react-native-port`** to verify CI; merge when green.
- Final cutover is one PR `react-native-port` → `main` (CI also runs on `main` PRs/pushes), plus one Simulator demo video on Planista.
- Do **not** record per-epic demos.

## Stack (pinned at scaffold)

- Expo SDK 57 + Expo Router
- TypeScript strict
- NativeWind v4 + theme tokens from `legacy/swift/DesignSystem/Theme.swift`
- Jest + Testing Library (unit/component)
- Maestro on iOS Simulator (e2e + final demo)
- State: React state + Context first; Zustand only if needed
- Local Expo Modules: `ffmpeg-module` (FFmpegKit) + `image-encode-module` (ImageIO still-image encode)

## Critical constraints

1. **Custom Dev Client required** — FFmpeg and other native modules will **not** run in Expo Go. Use `npx expo run:ios` / a development build. Document this in any user-facing run instructions.
2. **iOS / iPadOS 17+ only** — Android may exist from the template but is not a delivery target; CI must not build Android.
3. **Swift reference lives in `legacy/swift/`** — domain/FFmpeg behavior reference; do not delete until human sign-off. Prefer RN idioms over pixel-perfect SwiftUI clones.
4. **TDD** — domain and critical UI: failing tests first, then implement, `npm test` green before merge to `react-native-port`.
5. **No browser demo** — final acceptance video is headed iOS Simulator + Maestro + `simctl recordVideo` via `./scripts/record-demo.sh`.

## FFmpeg frameworks (Epic 1)

Vendored binaries match the Swift app: **tylerjonesio/ffmpeg-kit-spm `min.v5.1.2.6`**.

xcframeworks are **not** committed (too large). Download before prebuild / `pod install`:

```sh
./scripts/download-ffmpeg-frameworks.sh
# or
npm run download:ffmpeg
```

- SHA256 pins live in `scripts/download-ffmpeg-frameworks.sh` (from upstream `Package.swift`).
- Extracted to `modules/ffmpeg-module/ios/Frameworks/*.xcframework` (gitignored).
- Zips cached under `.cache/ffmpeg-kit-spm/` (gitignored).
- Expo config plugin `ffmpeg-module` runs the download during `expo prebuild`.
- Podspec also downloads if frameworks are missing when CocoaPods evaluates the pod.
- **CI must run the download script** (or rely on the config plugin / podspec) before building iOS.

Linked system frameworks/libs: VideoToolbox, AudioToolbox, AVFoundation, z, bz2, iconv, lzma.

LGPL note: see [`CREDITS.md`](CREDITS.md).

### TypeScript command builders

Domain logic under `src/core/` (ported from `legacy/swift/Core/Conversion/*` + Compatibility):

- `src/core/ffmpeg/*` — quote, metadata flags, video/audio/animated command builders
- `src/core/compatibility/CodecCapability.ts`, `FormatMatrix.ts`
- Golden-string unit tests in `src/core/__tests__/`

JS API (`ffmpeg-module`): `execute`, `cancel`, `probe`, `getRuntimeInfo`, events `onProgress` / `onLog`.

## Import / Home (Epic 2)

- Domain: `src/core/io/` (`ImportService`, `ImportStorage`, size cap 150 MB, remote helpers).
- UI: Expo Router home (`app/(tabs)/index.tsx`) + import detail (`app/import-detail.tsx`).
- State: `ImportProvider` / `useImport` in `src/features/home/ImportContext.tsx`.
- Native permissions (Custom Dev Client): photo library via `expo-image-picker` plugin + `NSPhotoLibraryUsageDescription` in `app.json`. Rebuild Dev Client after changing plugins/Info.plist.
- Clipboard paste uses `expo-clipboard` image/URL APIs (best-effort vs Swift pasteboard UTIs).
- Home **Try sample file** copies `fixtures/media/tiny.mp4` (small real H.264 MP4) into cache for Maestro navigation / light encode demos.

## Conversion (Epic 3)

- Domain: `src/core/conversion/` — router, bitrate planner, remux helpers, image quality binary-search, progress fraction, `ConversionService` (mocked FFmpeg/ImageEncode in unit tests).
- Native: `modules/image-encode-module` — ImageIO encode for JPEG/PNG/HEIC/TIFF; WebP best-effort via system UTType (no libwebp download; CI unchanged).
- UI flow: import-detail → `convert/config` → `convert/processing` → `convert/result` (share via `expo-sharing`, save via `expo-media-library`).
- State: `ConversionProvider` in `src/features/conversion/ConversionContext.tsx`.
- Maestro: `e2e/convert-nav.yaml` (CI); `e2e/demo/full-flow.yaml` skeleton for final recording.

Rebuild Dev Client after adding `image-encode-module` / media-library plugins:

```sh
npm run download:ffmpeg
npx expo run:ios
```

## Layout

```
app/                 Expo Router screens
components/          Shared UI
constants/           Theme tokens, colors
src/core/            Conversion domain (TS) + FFmpeg command builders
modules/ffmpeg-module/       Expo Module (iOS FFmpegKit wrapper + config plugin)
modules/image-encode-module/ Expo Module (iOS ImageIO encode + no-op plugin)
fixtures/media/      Tiny real media fixtures (e.g. H.264 MP4)
legacy/swift/        Previous SwiftUI app (reference)
e2e/                 Maestro flows (CI); e2e/demo/ for final recording only
scripts/             Demo recording + FFmpeg framework download
```

## Commands

```sh
npm install
./scripts/download-ffmpeg-frameworks.sh   # required once before native iOS build
npm test
npm start          # Metro; use Dev Client for native modules
npx expo run:ios   # prebuild + Dev Client (runs FFmpeg download via config plugin)
```

## CI (GitHub Actions)

Workflows on `react-native-port` and `main` (push/PR) plus `workflow_dispatch`. Markdown/LICENSE-only changes are skipped via `paths-ignore`.

| Workflow | Jobs | Runner | Notes |
|----------|------|--------|-------|
| `.github/workflows/ci.yml` | `unit`, `e2e` | Ubuntu / macOS-15 | Unit: `npm ci` + `npm test` only. E2e: pick Xcode with Swift 6.2+ (26.x → 16.4 → 16.3), download FFmpeg frameworks, `expo prebuild -p ios`, arm64 Simulator Release build, Maestro on `e2e/` **excluding** `e2e/demo/`. |
| `.github/workflows/ipa-unsigned.yml` | `unsigned-ipa` | macOS-15 | Same Xcode selection; download frameworks, clean iOS prebuild, unsigned `xcodebuild archive`, artifact `MB-Converter-unsigned.ipa`. |

Optimizations: unit never waits on macOS; npm cache via `setup-node`; CocoaPods + DerivedData + FFmpeg zip caches on macOS jobs; no Android builds. Image encode module needs no extra CI download step. Expo SDK 57 needs Swift tools 6.2+ — do not pin Xcode 16.2.

### Testing Library

This project uses `@testing-library/react-native` v14 (`await render(...)`). Prefer package docs under `node_modules/@testing-library/react-native/docs/` (start with `guides/llm-guidelines.md`) over stale training data.

## Epic order

0 Foundation → 1 FFmpegModule → 2 Import/Home → 3 Conversion → 4 Config/History → 5 Polish + final demo + one PR

Read Expo docs for the pinned SDK before changing native config: https://docs.expo.dev/versions/v57.0.0/
