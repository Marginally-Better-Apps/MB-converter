// SPDX-License-Identifier: MIT
#include "MBFFmpegBridge.h"
#include <limits.h>
#include <pthread.h>
#include <sched.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define COUNT(array) ((int)(sizeof(array) / sizeof((array)[0])))

typedef struct TestContext {
    int progress_calls;
    int cancel_after_progress;
    int pre_cancel;
    int64_t time_us;
    int64_t frames;
} TestContext;

static void fail(const char *message) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }
static void log_message(void *context, const char *message) { (void)context; fprintf(stderr, "%s\n", message); }
static void progress(void *opaque, int64_t time_us, int64_t bytes, int64_t frames) {
    TestContext *context = opaque;
    if (time_us < context->time_us || bytes < 0 || frames < context->frames) fail("progress regressed");
    context->time_us = time_us;
    context->frames = frames;
    context->progress_calls++;
}
static int cancelled(void *opaque) {
    TestContext *context = opaque;
    return context->pre_cancel || (context->cancel_after_progress && context->progress_calls > 0);
}
static TestContext execute(int argc, const char *const *argv) {
    TestContext context = {0};
    if (mbf_execute(argc, argv, log_message, progress, cancelled, &context) < 0) fail(argv[argc - 1]);
    if (!context.progress_calls || context.time_us <= 0) fail("missing progress");
    return context;
}
static void path(char *result, const char *directory, const char *filename) {
    if (snprintf(result, PATH_MAX, "%s/%s", directory, filename) >= PATH_MAX) fail("path too long");
}

typedef struct Worker {
    const char *input;
    char output[PATH_MAX];
    int should_cancel;
    atomic_int *ready;
    int result;
} Worker;

static void *concurrent_job(void *opaque) {
    Worker *worker = opaque;
    atomic_fetch_add(worker->ready, 1);
    while (atomic_load(worker->ready) < 2) sched_yield();
    for (int i = 0; i < 3; ++i) {
        char *json = mbf_probe_json(worker->input, 10000);
        if (!json || !strstr(json, "\"codec_name\"")) fail("concurrent probe");
        mbf_free_string(json);
    }
    const char *command[] = {"-y", "-i", worker->input, "-vn", "-c:a", "libmp3lame", "-b:a", "128k", worker->output};
    TestContext context = {.cancel_after_progress = worker->should_cancel};
    worker->result = mbf_execute(COUNT(command), command, log_message, progress, cancelled, &context);
    if (worker->should_cancel ? worker->result >= 0 : worker->result != 0) fail("independent concurrent cancellation");
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 2) fail("usage: bridge_tests FIXTURE_DIRECTORY");
    const char *directory = argv[1];
    char input[PATH_MAX], audio[PATH_MAX], output[PATH_MAX], decoded[PATH_MAX];
    path(input, directory, "input.mp4");
    path(audio, directory, "source.wav");
    const char *encoders[] = {"libmp3lame", "libopus", "libvorbis", "flac", "libvpx-vp9"};
    for (int i = 0; i < COUNT(encoders); ++i) if (!mbf_has_encoder(encoders[i])) fail(encoders[i]);
    if (!mbf_has_decoder("libdav1d") || !mbf_has_muxer("mp3")) fail("required capabilities");
    if (mbf_has_encoder("not_a_codec") || mbf_has_muxer("not_a_muxer")) fail("false capability");
    if (!strstr(mbf_license(), "2.1") || strstr(mbf_configuration(), "--enable-gpl")) fail("license configuration");

    const char *extensions[] = {"mp3", "opus", "ogg", "flac"};
    for (int i = 0; i < COUNT(extensions); ++i) {
        char filename[80];
        snprintf(filename, sizeof(filename), "audio.%s", extensions[i]);
        path(output, directory, filename);
        const char *command[] = {"ffmpeg", "-y", "-i", audio, "-vn", "-map", "0:a:0", "-c:a", encoders[i],
            "-b:a", "128k", "-map_metadata", "-1", "-map_chapters", "-1", "-metadata", "title=Quoted \"title\"\nCafé", output};
        execute(COUNT(command), command);
        char *json = mbf_probe_json(output, 15000);
        if (!json || !strstr(json, "Quoted \\\"title\\\"\\u000aCafé")) fail("probe JSON escaping and metadata");
        mbf_free_string(json);
        snprintf(filename, sizeof(filename), "%s-decoded.wav", extensions[i]);
        path(decoded, directory, filename);
        const char *roundtrip[] = {"-y", "-i", output, "-vn", "-c:a", "pcm_s16le", "-ar", "44100", "-ac", "1", decoded};
        execute(COUNT(roundtrip), roundtrip);
    }

    char high_resolution[PATH_MAX];
    path(high_resolution, directory, "source24.m4a");
    path(output, directory, "audio24.flac");
    const char *high_res[] = {"-y", "-i", high_resolution, "-vn", "-c:a", "flac", output};
    execute(COUNT(high_res), high_res);
    path(decoded, directory, "flac24-decoded.wav");
    const char *high_res_roundtrip[] = {"-y", "-i", output, "-vn", "-c:a", "pcm_s24le", decoded};
    execute(COUNT(high_res_roundtrip), high_res_roundtrip);
    path(high_resolution, directory, "source32.wav");
    const char *unsupported_depth[] = {"-y", "-i", high_resolution, "-vn", "-c:a", "flac", output};
    if (mbf_execute(COUNT(unsupported_depth), unsupported_depth, log_message, NULL, NULL, NULL) >= 0)
        fail("FLAC silently truncated 32-bit input");

    char copy_output[PATH_MAX];
    path(copy_output, directory, "copy.mp4");
    const char *copy[] = {"-y", "-i", input, "-map", "0:v:0", "-map", "0:a:0?", "-c", "copy",
        "-f", "mp4", "-movflags", "+faststart", "-map_metadata:s:0", "-1", "-map_metadata:s:1", "-1",
        "-map_metadata", "-1", "-map_chapters", "-1", "-metadata", "title=Copy title", "-metadata:s:1", "language=fra", copy_output};
    execute(COUNT(copy), copy);
    path(output, directory, "audio-extraction.m4a");
    const char *extract_audio[] = {"-y", "-i", input, "-vn", "-map", "0:a:0", "-c", "copy", "-f", "mp4",
        "-map_metadata", "-1", "-map_metadata_input:s:0", "-1", "-map_metadata_input:s:1", "-1",
        "-metadata_input:s:1", "language=fra", "-metadata_input:s:0", "title=Must not appear on audio",
        "-metadata:s:0", "handler_name=Extracted audio", output};
    execute(COUNT(extract_audio), extract_audio);

    char pass_log[PATH_MAX];
    path(pass_log, directory, "vp9-pass");
    path(output, directory, "pass1.webm");
    const char *pass1[] = {"-y", "-i", input, "-vf", "transpose=clock,crop=80:140,scale=64:112", "-r", "10",
        "-c:v", "libvpx-vp9", "-b:v", "160k", "-pass", "1", "-passlogfile", pass_log, "-an", "-f", "webm", output};
    TestContext first_pass = execute(COUNT(pass1), pass1);
    if (first_pass.time_us < 1400000 || first_pass.frames != 15) fail("first-pass duration statistics");
    path(output, directory, "pass2.webm");
    const char *pass2[] = {"-y", "-i", input, "-vf", "transpose=clock,crop=80:140,scale=64:112", "-r", "10",
        "-c:v", "libvpx-vp9", "-b:v", "160k", "-pass", "2", "-passlogfile", pass_log,
        "-c:a", "libopus", "-b:a", "96k", "-ac", "2", "-ar", "48000", "-f", "webm", output};
    execute(COUNT(pass2), pass2);

    path(output, directory, "seek.png");
    const char *seek[] = {"-y", "-ss", "0.5", "-i", input, "-frames:v", "1", "-c:v", "png", "-f", "image2", output};
    TestContext seek_context = execute(COUNT(seek), seek);
    if (seek_context.frames != 1) fail("frame extraction limit");
    path(output, directory, "seek-reference.png");
    const char *seek_reference[] = {"-y", "-i", input, "-vf", "select=gte(n\\,6)", "-frames:v", "1", "-c:v", "png", "-f", "image2", output};
    execute(COUNT(seek_reference), seek_reference);
    char rotated[PATH_MAX];
    path(rotated, directory, "rotated.mp4");
    path(output, directory, "rotated.png");
    const char *rotate[] = {"-y", "-i", rotated, "-frames:v", "1", "-c:v", "png", "-f", "image2", output};
    execute(COUNT(rotate), rotate);
    path(output, directory, "rotation-reference.png");
    const char *rotate_reference[] = {"-y", "-i", input, "-vf", "transpose=cclock", "-frames:v", "1", "-c:v", "png", "-f", "image2", output};
    execute(COUNT(rotate_reference), rotate_reference);
    path(output, directory, "rotation-copy.mp4");
    const char *rotate_copy[] = {"-y", "-i", rotated, "-c", "copy", output};
    execute(COUNT(rotate_copy), rotate_copy);
    char av1[PATH_MAX];
    path(av1, directory, "av1.mkv");
    path(output, directory, "av1.png");
    const char *av1_decode[] = {"-y", "-i", av1, "-frames:v", "1", "-c:v", "png", output};
    execute(COUNT(av1_decode), av1_decode);

    path(output, directory, "invalid-output.png");

    TestContext pre_cancel = {.pre_cancel = 1};
    if (mbf_execute(COUNT(copy), copy, log_message, progress, cancelled, &pre_cancel) >= 0) fail("pre-cancellation");
    const char *unsupported[] = {"-y", "-i", input, "-unsupported_option", "true", output};
    if (mbf_execute(COUNT(unsupported), unsupported, NULL, NULL, NULL, NULL) >= 0) fail("unsupported option accepted");
    const char *same_file[] = {"-y", "-i", input, "-c", "copy", input};
    if (mbf_execute(COUNT(same_file), same_file, NULL, NULL, NULL, NULL) >= 0) fail("overwriting input accepted");
    const char *bad_seek[] = {"-y", "-ss", "1000", "-i", input, "-frames:v", "1", "-c:v", "png", output};
    if (mbf_execute(COUNT(bad_seek), bad_seek, NULL, NULL, NULL, NULL) >= 0) fail("empty extraction accepted");
    if (mbf_probe_json("/nonexistent/mbffmpeg-test", 1)) fail("invalid probe succeeded");

    atomic_int ready = 0;
    Worker workers[2] = {{.input = audio, .ready = &ready}, {.input = audio, .ready = &ready, .should_cancel = 1}};
    path(workers[0].output, directory, "concurrent.mp3");
    path(workers[1].output, directory, "cancelled.mp3");
    pthread_t threads[2];
    for (int i = 0; i < 2; ++i) if (pthread_create(&threads[i], NULL, concurrent_job, &workers[i])) fail("pthread_create");
    for (int i = 0; i < 2; ++i) if (pthread_join(threads[i], NULL)) fail("pthread_join");
    execute(COUNT(copy), copy); // A failed/cancelled job must not poison the next job.

    if (getenv("MBF_TEST_VIDEOTOOLBOX")) {
        const char *hardware[] = {"h264_videotoolbox", "hevc_videotoolbox"};
        for (int i = 0; i < 2; ++i) {
            path(output, directory, i ? "hevc.mp4" : "h264.mp4");
            const char *command[] = {"-y", "-i", input, "-c:v", hardware[i], "-b:v", "200k",
                "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", "-tag:v", i ? "hvc1" : "avc1", output};
            execute(COUNT(command), command);
        }
    }
    printf("PASS: repeated native jobs, audio roundtrips, two-pass VP9, metadata, seek, orientation, AV1, cancellation and concurrency (%s)\n", mbf_version());
    return 0;
}
