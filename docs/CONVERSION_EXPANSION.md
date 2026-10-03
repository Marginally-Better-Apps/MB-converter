# On-device conversion expansion

The app offers up to 39 output choices across media, documents, data, and archives. Actual choices follow the input category and installed native encoders. Common image choices come first; older formats are in a separate group.

## Conversion engines

- PDFKit, Core Graphics, and Core Text handle PDFs, page selection, rotation, merging, page images, and searchable PDFs from text.
- Vision handles scanned-document and image OCR, plus foreground background removal. Models run locally; no downloaded model or conversion API is required.
- DOCX and ODT use bounded ZIP/XML readers and writers. They preserve editable text, paragraph breaks, tabs, and Unicode. Document artwork, tables, typography, and original page layout are not reconstructed. RTF uses native attributed-text conversion. HTML is read without loading external resources.
- CSV and TSV support quoted delimiters, newlines, Unicode, and escaped quotes. JSON conversion uses arrays of objects with consistent table columns. Text/data input is limited to 16 MiB and parsing has row, column, cell, and expansion limits.
- ImageIO provides supported system image encoders; libwebp handles WebP. ICO and ICNS wrap a 256-pixel PNG icon. Lanczos provides 2×/4× upscaling; this is resampling, not generative detail reconstruction. Background removal requires a detected foreground subject and a transparent output format.
- The latest branch already included a custom LGPL FFmpeg build with VideoToolbox, VP9, AV1 decoding, and broad native audio support. This change exposes ALAC, AIFF, and CAF and replaces a fixed two-thread setting with CPU/RAM-aware decoder, filter, and encoder budgets. It does not add GPL codecs or replace the build with FFmpegKit.
- zlib provides streaming ZIP/GZIP compression. Any selected file can be compressed; archive extraction and encrypted archives are not supported.

## Storage and resource behavior

Each unfinished conversion owns a source copy and an atomic settings record outside temporary storage. Leaving the editor waits for the checkpoint. Relaunch restores the source path, format, crop, audio edits, image tools, document settings, and metadata policy. Drafts are excluded from device backups, independent of completed-history settings, and removable from History. Batch inputs save before encoding and can resume individually.

Batch jobs run serially; each encoder uses bounded parallelism. Large raster operations are bounded by available device RAM, and PDF pages are processed one at a time. ZIP/GZIP use 256 KiB streaming buffers. PDF compression retains the smaller result; when it reduces pages to images, selectable text and interactive PDF elements may be lost. Page manipulation produces static PDFs rather than preserving forms, links, signatures, or annotations.

All conversion, compression, OCR, and image processing stays on the iPhone or iPad. Existing source-link downloads and Apple Maps metadata editing are network features. Imported files are never uploaded for conversion or sent to Maps. There is no Android target, conversion backend, or third-party conversion API.

## Research and scope

Reviewed primary product pages on October 3, 2026:

- [CloudConvert](https://cloudconvert.com/) informed broader format coverage and a single conversion flow.
- [iLovePDF](https://www.ilovepdf.com/) informed page extraction, merging, compression, Word export, image export, and OCR.
- [Apple Vision](https://developer.apple.com/documentation/vision/recognizing-text-in-images) supplies native text recognition.
- [Apple Liquid Glass](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views) informs the iOS 26 controls, with native material fallback on iOS 17–25.

This release adds practical local counterparts, not full parity with server products. Legacy binary Word (DOC), spreadsheet/presentation layout conversion, generative upscaling, archive extraction, and password/signature editing are not offered. The UI explains text-only Word conversion before exporting.

## Verification

`bash ios-test.sh` runs actual native document/data/archive conversions, filesystem draft persistence, malformed-input/resource limits, image format round trips, existing format regressions, and Swift/C adapter contracts. The native bridge has a separate real FFmpeg fixture suite. The GitHub workflow also builds the iPhone app, runs its XCTest suite, and drives draft restoration, document conversion, PDF batches, and Maps metadata editing on an iPhone Simulator. Maestro recordings use generated samples only.
