// MB Converter's minimal C interface over ImageMagick's MagickWand API (MIT).
// ImageMagick itself is distributed under the ImageMagick License; see the framework's Licenses folder.
#ifndef MBIMAGEMAGICKBRIDGE_H
#define MBIMAGEMAGICKBRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

/// Resource limits applied before the first job. Zero keeps the bridge default.
typedef struct mbim_limits {
    unsigned long long memory_bytes;   // default 384 MiB
    unsigned long long disk_bytes;     // default 2 GiB (spills to temporary_path)
    unsigned long long max_pixels;     // default 160 megapixels per image
    unsigned long long max_dimension;  // default 32768 pixels per side
    unsigned long long time_seconds;   // default 180 seconds per job
    unsigned long long threads;        // default 2
    const char *temporary_path;        // default: process temporary directory
} mbim_limits;

/// Initializes ImageMagick once. Safe to call repeatedly; later calls are ignored.
int mbim_initialize(const mbim_limits *limits);

/// ImageMagick release, e.g. "ImageMagick 7.1.2-34 Q16-HDRI ...".
const char *mbim_version(void);

/// Comma-separated, lowercase format names ImageMagick can read (`writable` = 0) or write (1).
/// Caller frees with mbim_free_string.
char *mbim_formats(int writable);

/// Converts `input` to `output`. `format` (e.g. "psd", "jxl") overrides the output extension.
/// `quality` 1–100 for lossy formats (0 = format default). `flatten` merges layers/pages onto
/// `background` (hex like "#ffffff") for formats without alpha or multi-image support.
/// Returns 0 on success; on failure `error_message` (when non-NULL) receives a string to free.
int mbim_convert(const char *input, const char *output, const char *format, int quality,
                 int flatten, const char *background, char **error_message);

/// JSON with width, height, frames (images in the file) and the detected format. Free the result.
char *mbim_identify(const char *input, char **error_message);

void mbim_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
