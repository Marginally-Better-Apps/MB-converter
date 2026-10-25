# MB Converter PDF/PostScript runtime (Ghostscript)

`MBGhostscriptBridge.xcframework` is a dynamic framework containing Ghostscript 10.08.0 with the
libraries it bundles (FreeType, Little CMS, OpenJPEG, jbig2dec, libtiff, libpng, libjpeg, zlib).
Fonts, ICC profiles and PostScript init files are compiled into its ROM file system, so it needs no
resources on disk. It exports only `mbgs_run` and `mbgs_version`
(`Native/MBGhostscriptBridge/include/MBGhostscriptBridge.h`).

The app uses it where PDFKit falls short:

- **Compress PDF** — resamples images with `pdfwrite` while text, vectors and links stay intact.
  PDFs with fillable form fields skip it (pdfwrite drops form fields) and use PDFKit instead.
- **Grayscale PDF** — converts colors, not pixels: text stays text.
- **Repair PDF** — rebuilds broken cross-reference tables and recovers truncated files.
- **Convert to PDF/A** — PDF/A-1b, 2b or 3b with an sRGB output intent and embedded fonts.
- **EPS, PostScript and Illustrator files** — open as PDF or images; PDFs export to EPS/PostScript.

## Build

```sh
python3 Scripts/BuildGhostscript.py --platform ios --platform ios-simulator
python3 Scripts/VerifyGhostscript.py
```

The source archive is pinned by SHA-256 in `sources.json` (its upstream SHA-512 is recorded too).
Output: `Native/Ghostscript/Artifacts/MBGhostscriptBridge.xcframework` (git-ignored). A full build takes
about three minutes; changing only packaging reuses the compiled library.

Host tests (no simulator):

```sh
python3 Scripts/BuildGhostscript.py --platform macos
python3 Native/MBGhostscriptBridge/tests/run_tests.py
```

## Safety

- Every job runs with `-dSAFER`: documents can't read or write files beyond those passed in.
- The bridge links its own `popen`/`pclose` that always fail, so nothing can start a process, not even
  a `%pipe%` output named on the command line. `VerifyGhostscript.py` checks the binary imports no
  process-spawning functions.
- Ghostscript is built with `CHECK_INTERRUPTS`, and the bridge's poll hook stops a job when the Swift
  task is cancelled. Jobs are serialized (Ghostscript keeps process-wide state).

## License

Ghostscript is © Artifex Software, licensed under the GNU Affero General Public License version 3 or
later; the app's GPL-3.0-or-later license is compatible with it (GPLv3 §13). The app is not a network
service, so the AGPL's remote-interaction clause doesn't add obligations, but every distributed build
must come with Ghostscript's corresponding source: `Scripts/BundleFFmpegSources.py` includes the pinned
archive, build manifests and configure logs. The framework's `Licenses/Ghostscript/` folder carries the
notices, shown in Settings → Open Source Licenses.
