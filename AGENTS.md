# MB Converter — agent notes (Expo port)

iOS-only Expo / React Native rebuild of MB Converter. Plan: https://planista.shloklab.us/qmzH-8FH2l9RYimT (v4).

## Branch model

| Branch | Role |
|--------|------|
| `main` | Shipping Swift app today; receive **one** final cutover PR |
| `react-native-port` | Integration branch (fake-main for the port) |
| `epic-*` | Feature branches; merge **locally** into `react-native-port` |

- Do **not** open per-epic GitHub PRs or record per-epic demos.
- At the end of the port: one PR `react-native-port` → `main`, one Simulator demo video on Planista.

## Stack (pinned at scaffold)

- Expo SDK 57 + Expo Router
- TypeScript strict
- NativeWind v4 + theme tokens from `legacy/swift/DesignSystem/Theme.swift`
- Jest + Testing Library (unit/component)
- Maestro on iOS Simulator (e2e + final demo)
- State: React state + Context first; Zustand only if needed

## Critical constraints

1. **Custom Dev Client required** — FFmpeg and other native modules will **not** run in Expo Go. Use `npx expo run:ios` / a development build. Document this in any user-facing run instructions.
2. **iOS / iPadOS 17+ only** — Android may exist from the template but is not a delivery target; CI must not build Android.
3. **Swift reference lives in `legacy/swift/`** — domain/FFmpeg behavior reference; do not delete until human sign-off. Prefer RN idioms over pixel-perfect SwiftUI clones.
4. **TDD** — domain and critical UI: failing tests first, then implement, `npm test` green before merge to `react-native-port`.
5. **No browser demo** — final acceptance video is headed iOS Simulator + Maestro + `simctl recordVideo` via `./scripts/record-demo.sh`.

## Layout

```
app/                 Expo Router screens
components/          Shared UI
constants/           Theme tokens, colors
legacy/swift/        Previous SwiftUI app (reference)
e2e/                 Maestro flows (CI); e2e/demo/ for final recording only
scripts/             Demo recording helpers
```

## Commands

```sh
npm install
npm test
npm start          # Metro; use Dev Client for native modules
npm run ios        # opens iOS Simulator (Expo Go until custom client exists)
npx expo run:ios   # preferred once native modules / Dev Client are in place
```

### Testing Library

This project uses `@testing-library/react-native` v14 (`await render(...)`). Prefer package docs under `node_modules/@testing-library/react-native/docs/` (start with `guides/llm-guidelines.md`) over stale training data.

## Epic order

0 Foundation → 1 FFmpegModule → 2 Import/Home → 3 Conversion → 4 Config/History → 5 Polish + final demo + one PR

Read Expo docs for the pinned SDK before changing native config: https://docs.expo.dev/versions/v57.0.0/
