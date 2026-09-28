# Changelog

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
