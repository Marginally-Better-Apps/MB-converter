# App Store Preview Videos

These are native-screen previews captured from Maestro runs and exported as silent H.264 MP4s.

| Device | Preview | Duration | Dimensions |
| --- | --- | ---: | ---: |
| iPhone | [MB-Converter-iPhone-Preview.mp4](iphone/MB-Converter-iPhone-Preview.mp4) | 19.4 s | 886 × 1920 portrait |
| iPad | [MB-Converter-iPad-Preview.mp4](ipad/MB-Converter-iPad-Preview.mp4) | 20.7 s | 1600 × 1200 landscape |

The preview shows selecting a waterfall photo, choosing HEIC with a 1 MB target, and the completed conversion result. The source image used by the flows is `assets/waterfall.jpg`.

## Recreate the captures

With the app installed and the named simulators booted, run:

```sh
maestro test --udid 12BB93A6-491E-4610-AAA2-8B8FB0B339E8 \
  --test-output-dir /tmp/maestro-iphone \
  docs/app-store-videos/flows/iphone-demo.yaml

maestro test --udid 5FF0AAE1-6E7C-4F82-9C9D-D07CDF2B42FF \
  --test-output-dir /tmp/maestro-ipad \
  docs/app-store-videos/flows/ipados-demo.yaml
```

On a fresh install, dismiss the iOS notification permission prompt once before recording. The flows use `stopApp` to restart from the home screen without clearing app permissions.

## App Store Connect format

Apple's current [App Preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/) allow 15–30 second previews and list these portrait iPhone and landscape iPad dimensions. Both exports are 30 fps, H.264, under 5 MB, and have no audio track.
