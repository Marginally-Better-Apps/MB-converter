#include "MBImageMagickBridge.h"

#include <MagickWand/MagickWand.h>
#include <ctype.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pthread_once_t mbim_once = PTHREAD_ONCE_INIT;
static mbim_limits mbim_requested_limits;
static int mbim_has_requested_limits = 0;

static unsigned long long pick(unsigned long long value, unsigned long long fallback) {
    return value ? value : fallback;
}

static void mbim_genesis(void) {
    const mbim_limits *limits = mbim_has_requested_limits ? &mbim_requested_limits : NULL;
    if (limits && limits->temporary_path && *limits->temporary_path) {
        setenv("MAGICK_TEMPORARY_PATH", limits->temporary_path, 1);
    }
    // No external delegates (Ghostscript, etc.) exist on iOS; never try to spawn them.
    setenv("MAGICK_CONFIGURE_PATH", "/nonexistent", 0);
    MagickWandGenesis();
    SetMagickResourceLimit(MemoryResource, pick(limits ? limits->memory_bytes : 0, 384ULL << 20));
    SetMagickResourceLimit(MapResource, pick(limits ? limits->memory_bytes : 0, 384ULL << 20) * 2);
    SetMagickResourceLimit(DiskResource, pick(limits ? limits->disk_bytes : 0, 2ULL << 30));
    SetMagickResourceLimit(AreaResource, pick(limits ? limits->max_pixels : 0, 160000000ULL));
    SetMagickResourceLimit(WidthResource, pick(limits ? limits->max_dimension : 0, 32768ULL));
    SetMagickResourceLimit(HeightResource, pick(limits ? limits->max_dimension : 0, 32768ULL));
    SetMagickResourceLimit(TimeResource, pick(limits ? limits->time_seconds : 0, 180ULL));
    SetMagickResourceLimit(ThreadResource, pick(limits ? limits->threads : 0, 2ULL));
    SetMagickResourceLimit(ListLengthResource, 2000);
}

int mbim_initialize(const mbim_limits *limits) {
    if (limits && !mbim_has_requested_limits) {
        mbim_requested_limits = *limits;
        mbim_has_requested_limits = 1;
    }
    return pthread_once(&mbim_once, mbim_genesis) == 0 ? 0 : -1;
}

const char *mbim_version(void) {
    mbim_initialize(NULL);
    size_t number = 0;
    return GetMagickVersion(&number);
}

static char *dup_string(const char *value) {
    return value ? strdup(value) : NULL;
}

void mbim_free_string(char *value) { free(value); }

static void set_error(char **error_message, const char *prefix, MagickWand *wand) {
    if (!error_message) return;
    ExceptionType severity = UndefinedException;
    char *description = wand ? MagickGetException(wand, &severity) : NULL;
    size_t length = strlen(prefix) + (description ? strlen(description) : 0) + 4;
    char *message = malloc(length);
    if (message) snprintf(message, length, "%s%s%s", prefix, description && *description ? ": " : "", description ? description : "");
    if (description) MagickRelinquishMemory(description);
    *error_message = message;
}

char *mbim_formats(int writable) {
    mbim_initialize(NULL);
    ExceptionInfo *exception = AcquireExceptionInfo();
    size_t count = 0;
    const MagickInfo **list = GetMagickInfoList("*", &count, exception);
    size_t capacity = 4096, used = 0;
    char *result = calloc(capacity, 1);
    for (size_t i = 0; list && result && i < count; ++i) {
        const MagickInfo *info = list[i];
        int supported = writable ? GetImageEncoder(info) != NULL : GetImageDecoder(info) != NULL;
        if (!supported || !info->name) continue;
        size_t name_length = strlen(info->name);
        if (used + name_length + 2 >= capacity) {
            capacity = (capacity + name_length) * 2;
            char *grown = realloc(result, capacity);
            if (!grown) { free(result); result = NULL; break; }
            result = grown;
        }
        if (used) result[used++] = ',';
        for (size_t c = 0; c < name_length; ++c) result[used++] = (char)tolower((unsigned char)info->name[c]);
        result[used] = 0;
    }
    if (list) list = (const MagickInfo **)RelinquishMagickMemory((void *)list);
    DestroyExceptionInfo(exception);
    return result;
}

static int is_single_image_format(const char *format) {
    static const char *single[] = {"jpg", "jpeg", "bmp", "ppm", "pgm", "pbm", "pnm", "tga", "pcx", "xpm", "xbm",
                                   "sgi", "sun", "qoi", "jxl", "jp2", "j2k", "wbmp", "hdr", "dds", "png", NULL};
    for (int i = 0; single[i]; ++i) if (!strcasecmp(format, single[i])) return 1;
    return 0;
}

int mbim_convert(const char *input, const char *output, const char *format, int quality,
                 int flatten, const char *background, char **error_message) {
    if (error_message) *error_message = NULL;
    if (!input || !output) { if (error_message) *error_message = dup_string("Missing input or output path"); return -1; }
    mbim_initialize(NULL);
    MagickWand *wand = NewMagickWand();
    if (!wand) { if (error_message) *error_message = dup_string("Out of memory"); return -1; }
    if (MagickReadImage(wand, input) == MagickFalse) {
        set_error(error_message, "Couldn't read the image", wand);
        DestroyMagickWand(wand);
        return -1;
    }
    const char *target = format && *format ? format : strrchr(output, '.') ? strrchr(output, '.') + 1 : "png";
    MagickWand *result = wand;
    int needs_flatten = flatten || is_single_image_format(target);
    if (needs_flatten && MagickGetNumberImages(wand) > 1) {
        // Multi-page/layered input to a single-image format keeps the first image,
        // which for PSD is the merged composite.
        MagickSetFirstIterator(wand);
        result = MagickGetImage(wand);
        if (!result) result = wand;
    }
    if (flatten && background && *background) {
        PixelWand *color = NewPixelWand();
        if (PixelSetColor(color, background) == MagickTrue) {
            MagickSetImageBackgroundColor(result, color);
            MagickWand *merged = MagickMergeImageLayers(result, FlattenLayer);
            if (merged) {
                if (result != wand) DestroyMagickWand(result);
                result = merged;
            }
        }
        DestroyPixelWand(color);
    }
    char upper[32] = {0};
    for (size_t i = 0; i < sizeof(upper) - 1 && target[i]; ++i) upper[i] = (char)toupper((unsigned char)target[i]);
    MagickResetIterator(result);
    while (MagickNextImage(result) != MagickFalse) {
        MagickSetImageFormat(result, upper);
        if (quality > 0 && quality <= 100) MagickSetImageCompressionQuality(result, (size_t)quality);
    }
    MagickSetFormat(result, upper);
    if (quality > 0 && quality <= 100) MagickSetCompressionQuality(result, (size_t)quality);
    char destination[4096];
    snprintf(destination, sizeof(destination), "%s:%s", upper, output);
    MagickBooleanType written = MagickWriteImages(result, destination, needs_flatten ? MagickFalse : MagickTrue);
    if (written == MagickFalse) set_error(error_message, "Couldn't write the image", result);
    if (result != wand) DestroyMagickWand(result);
    DestroyMagickWand(wand);
    return written == MagickTrue ? 0 : -1;
}

char *mbim_identify(const char *input, char **error_message) {
    if (error_message) *error_message = NULL;
    mbim_initialize(NULL);
    MagickWand *wand = NewMagickWand();
    if (!wand) return NULL;
    // "Ping" reads attributes without decoding pixels.
    if (MagickPingImage(wand, input) == MagickFalse) {
        set_error(error_message, "Couldn't read the image", wand);
        DestroyMagickWand(wand);
        return NULL;
    }
    MagickSetFirstIterator(wand);
    char *format = MagickGetImageFormat(wand);
    char buffer[512];
    snprintf(buffer, sizeof(buffer), "{\"width\":%zu,\"height\":%zu,\"frames\":%zu,\"format\":\"%s\"}",
             MagickGetImageWidth(wand), MagickGetImageHeight(wand), MagickGetNumberImages(wand), format ? format : "");
    if (format) MagickRelinquishMemory(format);
    DestroyMagickWand(wand);
    return strdup(buffer);
}
