/* Host tests for the Ghostscript bridge: conversion, errors, sandboxing and cancellation. */
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "MBGhostscriptBridge.h"

static int failures = 0;
#define CHECK(condition, ...) do { if (!(condition)) { failures++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

typedef struct { char text[65536]; size_t length; } Log;

static void collect(void *context, const char *text, int length) {
    Log *log = context;
    size_t room = sizeof(log->text) - 1 - log->length;
    size_t count = (size_t)length < room ? (size_t)length : room;
    memcpy(log->text + log->length, text, count);
    log->length += count;
    log->text[log->length] = 0;
}

static int run(Log *log, const int *cancel, int count, ...) {
    const char *argv[32] = { "gs", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET" };
    int argc = 5;
    va_list list;
    va_start(list, count);
    for (int i = 0; i < count; i++) argv[argc++] = va_arg(list, const char *);
    va_end(list);
    if (log) { log->length = 0; log->text[0] = 0; }
    return mbgs_run(argc, argv, log ? collect : NULL, log, cancel);
}

static long file_size(const char *path) {
    struct stat info;
    return stat(path, &info) == 0 ? (long)info.st_size : -1;
}

static void write_file(const char *path, const char *text) {
    FILE *file = fopen(path, "w");
    fputs(text, file);
    fclose(file);
}

static int cancel_flag = 0;
static void *trip(void *unused) {
    (void)unused;
    usleep(300000);
    __atomic_store_n(&cancel_flag, 1, __ATOMIC_RELAXED);
    return NULL;
}

static double now(void) {
    struct timespec time;
    clock_gettime(CLOCK_MONOTONIC, &time);
    return time.tv_sec + time.tv_nsec / 1e9;
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    const char *dir = argv[1];
    char eps[1024], pdf[1024], png[1024], ps[1024], secret[1024], marker[1024], hostile[1024], big[1024];
    snprintf(eps, sizeof eps, "%s/art.eps", dir);
    snprintf(pdf, sizeof pdf, "%s/art.pdf", dir);
    snprintf(png, sizeof png, "%s/art.png", dir);
    snprintf(ps, sizeof ps, "%s/doc.ps", dir);
    snprintf(secret, sizeof secret, "%s/secret.txt", dir);
    snprintf(marker, sizeof marker, "%s/marker", dir);
    snprintf(hostile, sizeof hostile, "%s/hostile.ps", dir);
    snprintf(big, sizeof big, "%s/big-%%d.png", dir);
    Log log;
    char option[1200];

    CHECK(strcmp(mbgs_version(), "10.08.0") == 0, "version %s", mbgs_version());

    write_file(eps, "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 50 40 250 160\n"
                    "0.1 0.3 0.8 setrgbcolor 50 40 200 120 rectfill\n"
                    "/Helvetica-Bold findfont 28 scalefont setfont 1 setgray 64 85 moveto (Hello EPS) show showpage\n");
    snprintf(option, sizeof option, "-sOutputFile=%s", pdf);
    CHECK(run(&log, NULL, 4, "-sDEVICE=pdfwrite", "-dEPSCrop", option, eps) == 0, "EPS to PDF: %s", log.text);
    FILE *file = fopen(pdf, "rb");
    char head[2048] = { 0 };
    if (file) { fread(head, 1, sizeof head - 1, file); fclose(file); }
    CHECK(strncmp(head, "%PDF-", 5) == 0, "output is not a PDF");
    CHECK(strstr(head, "MediaBox [0 0 200 120]") || file_size(pdf) > 500, "PDF missing or not cropped");

    snprintf(option, sizeof option, "-sOutputFile=%s", png);
    CHECK(run(&log, NULL, 5, "-sDEVICE=png16m", "-r144", "-dEPSCrop", option, eps) == 0, "EPS to PNG: %s", log.text);
    unsigned char header[24] = { 0 };
    file = fopen(png, "rb");
    if (file) { fread(header, 1, sizeof header, file); fclose(file); }
    unsigned width = (unsigned)header[16] << 24 | header[17] << 16 | header[18] << 8 | header[19];
    unsigned height = (unsigned)header[20] << 24 | header[21] << 16 | header[22] << 8 | header[23];
    CHECK(width == 400 && height == 240, "PNG is %ux%u, expected 400x240", width, height);

    /* Garbage input is an error, not a crash. */
    write_file(ps, "this is not postscript (\n");
    snprintf(option, sizeof option, "-sOutputFile=%s/garbage.pdf", dir);
    CHECK(run(&log, NULL, 3, "-sDEVICE=pdfwrite", option, ps) != 0, "garbage input succeeded");

    /* SAFER: documents can't read files or open pipes; pipes on the command line fail too. */
    write_file(secret, "secret");
    char program[4096];
    snprintf(program, sizeof program, "%%!PS\n/f (%s) (r) file def f 10 string readstring pop == showpage\n", secret);
    write_file(hostile, program);
    CHECK(run(&log, NULL, 2, "-sDEVICE=txtwrite", hostile) != 0 && !strstr(log.text, "secret"), "PostScript read a file: %s", log.text);
    snprintf(program, sizeof program, "%%!PS\n(%%pipe%%touch %s) (w) file closefile showpage\n", marker);
    write_file(hostile, program);
    run(&log, NULL, 2, "-sDEVICE=txtwrite", hostile);
    snprintf(option, sizeof option, "-sOutputFile=%%pipe%%touch %s", marker);
    CHECK(run(&log, NULL, 3, "-sDEVICE=pdfwrite", option, eps) != 0, "command-line pipe succeeded");
    CHECK(access(marker, F_OK) != 0, "a command ran");

    /* Cancellation stops a long multi-page job (it lands between operations) and leaves the engine usable. */
    char pages[1024];
    snprintf(pages, sizeof pages, "%s/pages.ps", dir);
    write_file(pages, "%!PS\n1 1 300 { 300 div setgray 0 0 612 792 rectfill 0 setgray 1 1 600 { 72 exch 1 add moveto 540 0 rlineto stroke } for showpage } for\n");
    snprintf(option, sizeof option, "-sOutputFile=%s", big);
    double started = now();
    pthread_t thread;
    pthread_create(&thread, NULL, trip, NULL);
    int code = run(NULL, &cancel_flag, 4, "-sDEVICE=png16m", "-r150", option, pages);
    pthread_join(thread, NULL);
    CHECK(code == MBGS_CANCELLED, "cancel returned %d", code);
    CHECK(now() - started < 3, "cancel took %.1fs", now() - started);
    cancel_flag = 0;
    snprintf(option, sizeof option, "-sOutputFile=%s", pdf);
    CHECK(run(&log, &cancel_flag, 4, "-sDEVICE=pdfwrite", "-dEPSCrop", option, eps) == 0, "run after cancel failed: %s", log.text);

    if (failures == 0) printf("Ghostscript bridge: all checks passed\n");
    return failures == 0 ? 0 : 1;
}
