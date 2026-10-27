# Changelog

## 1.2 — Unreleased

- **More than 100 tools for PDFs, documents, spreadsheets, images, video and audio**, all on the device: merge, split, organize, compress, sign, protect, redact, watermark and repair PDFs; convert Word, Excel, PowerPoint, Markdown, EPUB and more; crop, resize, filter, caption and remove backgrounds from photos; trim, speed up, loop and make GIFs from videos; QR codes, ZIP files and web pages to PDF.
- A Tools tab with search that understands plain English ("turn my photo into a pdf"), a landing screen for every document you open, and "Open in MB Converter" from Files, Mail and the share sheet.
- Editors on the tool screen itself: drag and drop pages, tap pages to delete or keep, place signatures, crop, trim, and a meme maker with text boxes you can put anywhere.
- Live previews while you change settings, with a Before/After button.
- Ghostscript for smaller PDFs, PDF/A archiving, repairing damaged PDFs, and PostScript/EPS.
- A simpler result screen (Save to Photos, Make Another, copyable text) and History that's saved by default, grouped by day.
- Plain words everywhere: errors say what to do, the converter says "Full quality" instead of codec jargon, and a greyed-out button says what to change.
- Better with large text and VoiceOver.
- **License change: MB Converter is now GPL-3.0-or-later** (previously MIT) so it can bundle x264. Ghostscript is AGPL-3.0-or-later.
- Compressing H.264 video to a target size now uses two-pass x264 encoding and lands close to the requested size; VideoToolbox could only make a single-pass guess.

Repository build: **1.2 (4)**.

## 1.1 — 2026-09-28

- Export MP3, FLAC, Ogg/Vorbis, Opus, and WebM (VP9/Opus), and import AV1 video with the custom FFmpeg runtime.
- Trim audio, adjust volume and playback speed while preserving pitch, and select audio channels with matching preview and export behavior.
- Trim supported videos and use updated crop, rotation, playback, and output controls.
- Preview more media formats with fallback thumbnails and cancellable playback preparation.
- Improve clipboard and direct-link imports, including audio waveform thumbnails and cleanup after cancelled or failed imports.
- Continue conversions in the background when iOS permits, with progress, cancellation, expiration handling, and optional warning notifications.
- Improve WebP encoding and PNG dimension/size estimates, and preserve video color information with HDR-to-SDR conversion where needed.
- Refresh the import, editing, conversion, results, and history screens.
- Build FFmpeg from pinned sources, bundle third-party notices, and attach matching source/rebuild materials and checksums to automated IPA releases.

Repository build: **1.1 (3)**. Automated GitHub releases use the workflow run number as their build number. Device background execution and hardware codec availability depend on the OS and device.
