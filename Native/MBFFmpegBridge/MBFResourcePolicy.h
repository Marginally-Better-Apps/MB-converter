#ifndef MBF_RESOURCE_POLICY_H
#define MBF_RESOURCE_POLICY_H
#include <stdint.h>
// Four frame-equivalents per worker cover decode references, filtering and encode.
// Audio uses little frame memory. Video budgets at most 384 MiB of the device RAM.
static inline int mbf_worker_count(int cores, uint64_t memory, int width, int height) {
    uint64_t budget = memory / 8;
    if (budget < 96ULL * 1024 * 1024) budget = 96ULL * 1024 * 1024;
    if (budget > 384ULL * 1024 * 1024) budget = 384ULL * 1024 * 1024;
    uint64_t frame = width > 0 && height > 0 ? (uint64_t)width * height * 4 : 1024 * 1024;
    if (frame > budget / 4) return 1; // Avoid overflow on corrupt or enormous dimensions.
    uint64_t slots = budget / (frame * 4);
    int workers = cores < 1 ? 1 : cores > 8 ? 8 : cores;
    if (slots < (uint64_t)workers) workers = (int)slots;
    return workers < 1 ? 1 : workers;
}
#endif
