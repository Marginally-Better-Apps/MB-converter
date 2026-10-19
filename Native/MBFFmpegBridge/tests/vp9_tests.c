// SPDX-License-Identifier: MIT
// Inspect the actual opened libvpx encoder, then finish a real conversion.
#include "../MBFFmpegBridge.c"
#include <assert.h>

static void check(const char *input, const char *output, const char *filter, int expected_threads) {
    const char *args[] = {"-y", "-i", input, "-vf", filter, "-c:v", "libvpx-vp9", "-b:v", "1400k",
                          "-c:a", "libopus", "-b:a", "96k", output};
    MBFJob job = {0};
    assert(mbf_parse(&job, sizeof(args) / sizeof(args[0]), args) == 0);
    assert(mbf_open(&job) == 0);
    AVCodecContext *encoder = job.streams[0].encoder;
    int64_t row_mt = 0, speed = 0, deadline = 0;
    assert(av_opt_get_int(encoder->priv_data, "row-mt", 0, &row_mt) == 0);
    assert(row_mt == 1 && "VP9 must enable row multithreading");
    assert(encoder->thread_count == expected_threads);
    assert(av_opt_get_int(encoder->priv_data, "cpu-used", 0, &speed) == 0 && speed == 4);
    assert(av_opt_get_int(encoder->priv_data, "deadline", 0, &deadline) == 0 && deadline == 1000000);
    assert(mbf_convert(&job) == 0);
    mbf_cleanup(&job);
}

int main(int argc, char **argv) {
    assert(argc == 3);
    int cores = FFMAX(1, av_cpu_count());
    check(argv[1], argv[2], "scale=1280:720", FFMIN(8, cores));
    check(argv[1], argv[2], "scale=160:96", FFMIN(2, cores));
    av_cpu_force_count(1);
    check(argv[1], argv[2], "scale=1280:720", 1);
    av_cpu_force_count(16);
    check(argv[1], argv[2], "scale=1280:720", 8);
    av_cpu_force_count(-1);
    puts("PASS: real VP9 encoder uses bounded worker threads and row multithreading at the existing quality preset");
}
