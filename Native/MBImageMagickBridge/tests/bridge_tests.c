#include "MBImageMagickBridge.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define COUNT(x) ((int)(sizeof(x) / sizeof((x)[0])))
static void fail(const char *message) { fprintf(stderr, "FAIL: %s\n", message); exit(1); }

static void write_ppm(const char *path, int width, int height) {
    FILE *file = fopen(path, "wb");
    if (!file) fail("open ppm");
    fprintf(file, "P6\n%d %d\n255\n", width, height);
    for (int y = 0; y < height; ++y)
        for (int x = 0; x < width; ++x) {
            unsigned char pixel[3] = {(unsigned char)(x * 255 / width), (unsigned char)(y * 255 / height), 128};
            fwrite(pixel, 1, 3, file);
        }
    fclose(file);
}

static int has_prefix(const char *path, const char *prefix) {
    char buffer[16] = {0};
    FILE *file = fopen(path, "rb");
    if (!file) return 0;
    size_t length = fread(buffer, 1, strlen(prefix), file);
    fclose(file);
    return length == strlen(prefix) && !memcmp(buffer, prefix, length);
}

int main(int argc, char **argv) {
    if (argc != 2) fail("usage: bridge_tests DIRECTORY");
    const char *directory = argv[1];
    mbim_limits limits = {.memory_bytes = 128ULL << 20, .max_pixels = 40000000ULL, .temporary_path = directory};
    if (mbim_initialize(&limits) != 0) fail("initialize");
    if (!strstr(mbim_version(), "ImageMagick 7")) fail("version");

    char *readable = mbim_formats(0), *writable = mbim_formats(1);
    const char *required_write[] = {"png", "jpeg", "tiff", "webp", "jp2", "jxl", "psd", "tga", "ico", "bmp",
                                    "pcx", "sgi", "xpm", "qoi", "eps", "pdf", "dds", "ppm", "gif", "hdr"};
    for (int i = 0; i < COUNT(required_write); ++i) {
        char needle[32];
        snprintf(needle, sizeof(needle), ",%s,", required_write[i]);
        char haystack[65536];
        snprintf(haystack, sizeof(haystack), ",%s,", writable);
        if (!strstr(haystack, needle)) { fprintf(stderr, "missing writer %s\n", required_write[i]); fail("writer"); }
    }
    if (!strstr(readable, "psd") || !strstr(readable, "jxl")) fail("readers");
    mbim_free_string(readable);
    mbim_free_string(writable);

    char source[4096], output[4096];
    snprintf(source, sizeof(source), "%s/source.ppm", directory);
    write_ppm(source, 120, 80);

    const char *roundtrip[] = {"png", "jpg", "tiff", "webp", "jp2", "jxl", "psd", "tga", "ico", "bmp",
                               "pcx", "sgi", "xpm", "qoi", "dds", "ppm", "gif", "hdr"};
    for (int i = 0; i < COUNT(roundtrip); ++i) {
        snprintf(output, sizeof(output), "%s/out.%s", directory, roundtrip[i]);
        char *error = NULL;
        if (mbim_convert(source, output, roundtrip[i], 85, 0, NULL, &error) != 0) {
            fprintf(stderr, "%s: %s\n", roundtrip[i], error ? error : "unknown");
            fail("convert");
        }
        char *json = mbim_identify(output, &error);
        if (!json || !strstr(json, "\"width\":120") || !strstr(json, "\"height\":80")) {
            fprintf(stderr, "%s identify: %s\n", roundtrip[i], json ? json : error);
            fail("identify roundtrip");
        }
        mbim_free_string(json);
    }

    snprintf(output, sizeof(output), "%s/out.eps", directory);
    if (mbim_convert(source, output, "eps", 0, 1, "#ffffff", NULL) != 0 || !has_prefix(output, "%!PS-Adobe"))
        fail("eps writer");
    snprintf(output, sizeof(output), "%s/out.pdf", directory);
    if (mbim_convert(source, output, "pdf", 85, 1, "#ffffff", NULL) != 0 || !has_prefix(output, "%PDF"))
        fail("pdf writer");

    // A layered PSD flattened to JPEG keeps the composite and its size.
    char psd[4096];
    snprintf(psd, sizeof(psd), "%s/out.psd", directory);
    snprintf(output, sizeof(output), "%s/from-psd.jpg", directory);
    if (mbim_convert(psd, output, "jpg", 90, 1, "#ffffff", NULL) != 0) fail("psd to jpg");

    // Decompression-bomb guard: a huge declared size must fail cleanly under the pixel limit.
    char bomb[4096];
    snprintf(bomb, sizeof(bomb), "%s/bomb.ppm", directory);
    FILE *file = fopen(bomb, "wb");
    fprintf(file, "P6\n30000 30000\n255\n");
    fclose(file);
    snprintf(output, sizeof(output), "%s/bomb.png", directory);
    char *error = NULL;
    if (mbim_convert(bomb, output, "png", 0, 0, NULL, &error) == 0) fail("pixel limit not enforced");
    mbim_free_string(error);

    if (mbim_identify("/nonexistent/mbim-test.png", &error)) fail("missing file identified");
    mbim_free_string(error);
    printf("PASS: %d round-trip formats, EPS/PDF writers, PSD flatten, resource limits (%s)\n",
           COUNT(roundtrip), mbim_version());
    return 0;
}
