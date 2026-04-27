# MB Converter

**Convert and compress** photos, video, and audio on your iPhone and iPad—one simple flow from choosing a format to picking where your file comes from.

**App Icon**

<img src="Assets.xcassets/AppIcon.appiconset/AppIcon-ios-marketing-1024x1024@1x.png" alt="MB Converter app icon" width="8%" />

**Main Screen Preview**

<table>
  <tr>
    <td align="center">
      <strong>Light</strong><br />
      <img src="docs/light_mainpage.png" alt="MB Converter light main screen" width="180" />
    </td>
    <td align="center">
      <strong>Dark</strong><br />
      <img src="docs/dark_mainpage.png" alt="MB Converter dark main screen" width="180" />
    </td>
  </tr>
</table>

## Supported formats

| Files | Codecs we can read |
|-------|--------------------|
| Video: MP4, MOV, M4V, MKV, WebM, AVI, FLV, F4V, TS, MTS, M2TS, 3GP, MPEG/MPG, M2V, MXF, OGV, VOB, ASF, WMV, WTV, SWF, HEVC, MJPEG | H.264, HEVC, VP8, VP9, MPEG-2, MPEG-4, MJPEG, Theora |
| Audio: MP3, M4A, WAV, AAC, FLAC, OGG, Opus, ALAC | AAC, MP3, FLAC, ALAC, Vorbis, Opus, PCM |
| Photos: JPEG, PNG, HEIC, WebP, AVIF, TIFF | handled by iOS |
| Animated: GIF | — |

### What you can save out

| Output | Codec used |
|--------|------------|
| MP4 (H.264) | H.264 |
| MP4 (HEVC) | HEVC |
| MOV | H.264 |
| M4A | AAC |
| AAC | AAC |
| WAV | PCM 16-bit |
| JPEG | — |
| PNG | — |
| HEIC | — |
| WebP (still image) | — |
| TIFF | — |

## For developers

Building from source or curious about how it’s put together? See the **[Developer documentation](docs/DEVELOPMENT.md)**.

## License

The app’s source code is under the [MIT License](LICENSE). The libraries it relies on keep their own licenses — see the developer doc for the full list.
