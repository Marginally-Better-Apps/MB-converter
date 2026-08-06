# Credits & third-party notices

## FFmpeg / FFmpegKit

This app vendors binary builds of **FFmpeg** via [tylerjonesio/ffmpeg-kit-spm](https://github.com/tylerjonesio/ffmpeg-kit-spm) (`min.v5.1.2.6`), the same package used by the legacy Swift app.

FFmpeg is licensed under the **LGPL v2.1+** / **LGPL v3** (depending on build configuration). The min package is intended for LGPL-compatible use (no GPL-only external libraries such as libx264 in that build). Source for FFmpeg is available from [https://ffmpeg.org](https://ffmpeg.org).

FFmpegKit wrapper sources: [arthenica/ffmpeg-kit](https://github.com/arthenica/ffmpeg-kit) (and the tylerjonesio SPM packaging).

Application source code remains under the MIT License (see [LICENSE](LICENSE)). FFmpeg and other native dependencies retain their own licenses.
