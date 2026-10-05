# WebP codec

This local Swift package preserves the `libwebp` product/module and vendors the
1.6.0 C sources from SDWebImage/libwebp-Xcode revision
`2b5256c29ff4e20f2a0d5ee863b62b1a22144434`. `provenance.json` records SHA-256
hashes of the unmodified source files and public header links. Only C sources,
headers, and upstream notices are retained; upstream build-system files are omitted.

The codec compiles with `-O2` and `WEBP_USE_THREAD` for **both** Debug and Release.
The later `-O2` overrides Xcode's configuration-level optimization flag. The app's
Swift optimization settings are unchanged. ARM64 NEON is selected automatically
by libwebp's CPU feature headers. Threading accelerates analysis and alpha work;
it does not parallelize every part of lossy encoding.

`COPYING`, `PATENTS`, and `AUTHORS` contain upstream notices. Their combined
`WebP-NOTICE.txt` is included in the app bundle. Keep these and `provenance.json`
updated together when deliberately upgrading the dependency. Do not edit cached
SwiftPM checkouts or apply blanket compiler flags to the application.

Validation from the repository root:

```sh
python3 Scripts/VerifyWebP.py --derived-data build/WebPValidation
python3 Scripts/TestImageConversion.py
python3 Scripts/TestImageConversion.py --debug --large
python3 Scripts/BenchmarkWebP.py
```

The macOS harness matches the production source list and codec flags. Its
`original` benchmark variant alone uses the former `-Os`, non-threaded build and
frozen buffered encoder in `Tests/Fixtures/WebPOriginalEncoder.swift.inc`.
Benchmark outputs stay under `build/webp-benchmark`; each conversion runs in a
fresh process, with fixture generation and quality checks outside the measured
interval. Default fixtures are deterministic synthetic images; add real local
photos with repeated `--photo /path/to/photo.heic` arguments.

Method 3 remains the default after method 2 failed the agreed size/quality gates.
See [validation results](../../docs/validation/webp-encoding.md).
