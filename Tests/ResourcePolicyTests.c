#include <assert.h>
#include <stdio.h>
#include "../Native/MBFFmpegBridge/MBFResourcePolicy.h"
int main(void) {
    assert(mbf_worker_count(8, 8ULL * 1024 * 1024 * 1024, 1920, 1080) == 8);
    assert(mbf_worker_count(8, 2ULL * 1024 * 1024 * 1024, 7680, 4320) == 1);
    assert(mbf_worker_count(1, 8ULL * 1024 * 1024 * 1024, 1920, 1080) == 1);
    assert(mbf_worker_count(8, 8ULL * 1024 * 1024 * 1024, 0, 0) <= 8);
    assert(mbf_worker_count(8, 8ULL * 1024 * 1024 * 1024, 1 << 30, 1 << 30) == 1);
    puts("CPU and memory policy passed");
}
