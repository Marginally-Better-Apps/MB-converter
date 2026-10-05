// SPDX-License-Identifier: MIT
// Original MB Converter adapter; links only to FFmpeg's public library API.
#ifndef MB_FFMPEG_BRIDGE_H
#define MB_FFMPEG_BRIDGE_H

#include <stdint.h>

#if defined(__GNUC__)
#define MBF_EXPORT __attribute__((visibility("default")))
#else
#define MBF_EXPORT
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*mbf_log_callback)(void *context, const char *message);
typedef void (*mbf_progress_callback)(void *context, int64_t output_time_us,
                                    int64_t bytes, int64_t frame_count);
typedef int (*mbf_cancel_callback)(void *context);

/* Synchronous, reentrant execution of the app's single-input/single-output
 * command subset. argv[0] may be "ffmpeg", or argv may start with an option.
 * All arguments and callback contexts must remain valid until return. Callbacks
 * run on the calling thread. Returns zero on success or a negative AVERROR.
 * Unknown options are errors. This is not the FFmpeg command-line executable.
 * The app-specific -metadata_input:s:N and -map_metadata_input:s:N options
 * address an input stream's selected output, so extraction preserves its tags.
 * Standard -metadata:s:N and -map_metadata:s:N still address output indices.
 * -mb-acceleration auto|off|required opts video transcoding into the color-aware
 * pipeline. auto tries VideoToolbox decoding/filtering and retries hardware
 * failures once in software. off retains the same color policy with CPU
 * decoding/filtering (encoder selection is unchanged). required rejects any
 * CPU pixel-processing stage and never retries. Omission keeps legacy callers.
 */
MBF_EXPORT int mbf_execute(int argc, const char *const *argv,
                mbf_log_callback log, mbf_progress_callback progress,
                mbf_cancel_callback cancel, void *context);

/* A local-file ffprobe-shaped JSON document, or NULL on error/timeout.
 * timeout_ms <= 0 uses a 10-second deadline. Free with mbf_free_string(). */
MBF_EXPORT char *mbf_probe_json(const char *path, int timeout_ms);
MBF_EXPORT void mbf_free_string(char *value);

MBF_EXPORT int mbf_has_encoder(const char *name);
MBF_EXPORT int mbf_has_decoder(const char *name);
MBF_EXPORT int mbf_has_muxer(const char *name);
MBF_EXPORT const char *mbf_version(void);
MBF_EXPORT const char *mbf_license(void);
MBF_EXPORT const char *mbf_configuration(void);

#ifdef __cplusplus
}
#endif
#endif
