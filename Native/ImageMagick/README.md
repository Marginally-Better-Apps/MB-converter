# MB Converter image runtime (ImageMagick)

`MBImageMagickBridge.xcframework` is a dynamic framework containing ImageMagick 7 (Q16 HDRI) and its
permissively licensed delegates: libpng, libjpeg-turbo, libtiff, libwebp, OpenJPEG, Little CMS, libjxl
(with Highway and Brotli). It exports only the six `mbim_*` functions declared in
`Native/MBImageMagickBridge/include/MBImageMagickBridge.h`, so its bundled libraries never clash with
the app's own libwebp or with the FFmpeg runtime.

The app uses Apple's ImageIO first and falls back to ImageMagick for formats ImageIO can't read or write:
PSD, TGA, ICO, PCX, QOI, DDS, SGI, XPM, Radiance HDR, Netpbm, JPEG 2000, JPEG XL, and EPS output.

## Build

```sh
python3 Scripts/BuildImageMagick.py --platform ios --platform ios-simulator
python3 Scripts/VerifyImageMagick.py
```

Every source archive is pinned by SHA-256 in `sources.json` (with mirrors where upstream offers identical
files). Output: `Native/ImageMagick/Artifacts/MBImageMagickBridge.xcframework` (git-ignored).

Host tests (no simulator):

```sh
python3 Scripts/BuildImageMagick.py --platform macos --libraries-only
python3 Native/MBImageMagickBridge/tests/run_tests.py
```

## Safety limits

The bridge applies resource limits before the first job (memory, disk spill, 200 MP per image,
32,768 px per side, 240 s per job, 2–4 threads) so decompression bombs and huge files fail with an
error instead of exhausting memory. No external delegates run: PostScript/PDF *reading* would need
Ghostscript (AGPL) and is deliberately unavailable; EPS and PDF *writing* are built in.

## Licenses

ImageMagick is distributed under the ImageMagick License (Apache 2.0 derived); each delegate keeps its own
permissive license. The framework's `Licenses/` folder carries every notice, and Settings → Open Source
Licenses shows them.
