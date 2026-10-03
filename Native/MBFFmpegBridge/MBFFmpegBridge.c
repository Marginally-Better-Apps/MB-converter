#include "MBFResourcePolicy.h"
#include <sys/sysctl.h>
#include <unistd.h>
static uint64_t mbf_physical_memory(void) {
    uint64_t bytes = 0;
    size_t size = sizeof(bytes);
    if (sysctlbyname("hw.memsize", &bytes, &size, NULL, 0) != 0) return 2ULL * 1024 * 1024 * 1024;
    return bytes;
}

// SPDX-License-Identifier: MIT
// Copyright (c) 2026 MB Converter contributors.
// Original, reentrant adapter over FFmpeg's public C APIs. No FFmpeg CLI or
// FFmpegKit source is included. See the repository LICENSE for this file's terms.

#include "MBFFmpegBridge.h"
#include <errno.h>
#include <inttypes.h>
#include <limits.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <TargetConditionals.h>

#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavformat/avformat.h>
#include <libavutil/avstring.h>
#include <libavutil/bprint.h>
#include <libavutil/channel_layout.h>
#include <libavutil/dict.h>
#include <libavutil/display.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/opt.h>
#include <libavutil/parseutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/time.h>
#include <libavutil/hwcontext.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/dovi_meta.h>
#include <VideoToolbox/VideoToolbox.h>

typedef struct MBFQueuedPacket {
    AVPacket *packet;
    struct MBFQueuedPacket *next;
} MBFQueuedPacket;

typedef struct MBFMetadata {
    int stream_index; // -1 is container metadata.
    int source_index;
    int clear;
    AVDictionary *tags;
    struct MBFMetadata *next;
} MBFMetadata;

typedef struct MBFOptions {
    const char *input, *output, *video_codec, *audio_codec;
    const char *filter, *audio_filter, *pixel_format, *muxer, *movflags, *pass_log, *video_tag;
    int overwrite, no_video, no_audio, pass, channels, sample_rate;
    int maps_present, map_video, map_audio, optional_video, optional_audio;
    int clear_metadata, clear_chapters;
    int64_t video_bitrate, audio_bitrate, seek_us, max_video_frames;
    AVRational fps;
    MBFMetadata *metadata;
    int video_pipeline, acceleration; // 0=off, 1=auto, 2=required
#ifdef MBF_TESTING
    const char *test_failure;
#endif
} MBFOptions;

typedef struct MBFStream {
    int input_index;
    AVStream *input, *output;
    AVCodecContext *decoder, *encoder;
    AVFilterGraph *graph;
    AVFilterContext *source, *sink;
    FILE *pass_file;
    int64_t frames, next_input_pts;
    int copy, eof;
    AVFrame *first_frame;
    int pipeline, hardware_decode, hardware_filter, tonemap, source_depth, hardware_negotiation_failed;
    enum AVPixelFormat source_format;
    double signal_peak;
} MBFStream;

typedef struct MBFJob {
    MBFOptions options;
    AVFormatContext *input, *output;
    MBFStream streams[2];
    int stream_count;
    int64_t origin_us, output_time_us, video_frames, bytes, last_progress_us;
    mbf_log_callback log;
    mbf_progress_callback progress;
    mbf_cancel_callback cancel;
    void *context;
    MBFQueuedPacket *queued_head, *queued_tail;
    size_t queued_bytes;
    int hardware_failure, output_opened, output_error;
    int64_t progress_floor_time, progress_floor_frames;
} MBFJob;

static void mbf_log(MBFJob *job, const char *format, ...) {
    if (!job->log) return;
    char message[2048];
    va_list args;
    va_start(args, format);
    vsnprintf(message, sizeof(message), format, args);
    va_end(args);
    job->log(job->context, message);
}

static int mbf_interrupted(void *opaque) {
    MBFJob *job = opaque;
    return job->cancel && job->cancel(job->context);
}

static int mbf_error(MBFJob *job, int error, const char *operation) {
    char description[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(error, description, sizeof(description));
    mbf_log(job, "%s: %s", operation, description);
    return error;
}

static MBFMetadata *mbf_metadata(MBFOptions *options, int index, int source_index) {
    MBFMetadata **item = &options->metadata;
    while (*item && ((*item)->stream_index != index || (*item)->source_index != source_index)) item = &(*item)->next;
    if (!*item) {
        *item = av_mallocz(sizeof(**item));
        if (*item) { (*item)->stream_index = index; (*item)->source_index = source_index; }
    }
    return *item;
}

static int mbf_integer(const char *value, int64_t minimum, int64_t maximum, int64_t *result) {
    char *end;
    errno = 0;
    long long number = strtoll(value, &end, 10);
    if (errno || !*value || *end || number < minimum || number > maximum) return AVERROR(EINVAL);
    *result = number;
    return 0;
}

static int mbf_bitrate(const char *value, int64_t *result) {
    char *end;
    errno = 0;
    double number = strtod(value, &end);
    if (end == value || errno || !isfinite(number)) return AVERROR(EINVAL);
    if ((*end == 'k' || *end == 'K') && !end[1]) number *= 1000;
    else if ((*end == 'm' || *end == 'M') && !end[1]) number *= 1000000;
    else if (*end) return AVERROR(EINVAL);
    if (number < 1 || number > INT_MAX) return AVERROR(EINVAL);
    *result = (int64_t)number;
    return 0;
}

static int mbf_parse(MBFJob *job, int argc, const char *const *argv) {
    MBFOptions *options = &job->options;
    options->max_video_frames = INT64_MAX;
    int start = argc > 0 && (!strcmp(argv[0], "ffmpeg") || !strcmp(argv[0], "mbffmpeg")) ? 1 : 0;
    for (int i = start; i < argc; ++i) {
        const char *argument = argv[i];
        if (!argument) return AVERROR(EINVAL);
        if (!strcmp(argument, "-y")) { options->overwrite = 1; continue; }
        if (!strcmp(argument, "-vn")) { options->no_video = 1; continue; }
        if (!strcmp(argument, "-an")) { options->no_audio = 1; continue; }
        if (!strcmp(argument, "-hide_banner") || !strcmp(argument, "-nostdin")) continue;
        if (*argument != '-') {
            if (options->output) return AVERROR(EINVAL);
            options->output = argument;
            continue;
        }
        if (i + 1 >= argc || !argv[i + 1]) return AVERROR(EINVAL);
        const char *value = argv[++i];
        int64_t number = 0;
        int error = 0;
        if (!strcmp(argument, "-i")) {
            if (options->input) return AVERROR(EINVAL);
            options->input = value;
        } else if (!strcmp(argument, "-c:v")) options->video_codec = value;
        else if (!strcmp(argument, "-mb-acceleration")) {
            options->video_pipeline = 1;
            if (!strcmp(value, "off")) options->acceleration = 0;
            else if (!strcmp(value, "auto")) options->acceleration = 1;
            else if (!strcmp(value, "required")) options->acceleration = 2;
            else error = AVERROR(EINVAL);
        }
#ifdef MBF_TESTING
        else if (!strcmp(argument, "-mb-test-failure")) options->test_failure = value;
#endif
        else if (!strcmp(argument, "-c:a")) options->audio_codec = value;
        else if (!strcmp(argument, "-c")) options->video_codec = options->audio_codec = value;
        else if (!strcmp(argument, "-vf")) options->filter = value;
        else if (!strcmp(argument, "-af")) options->audio_filter = value;
        else if (!strcmp(argument, "-pix_fmt")) options->pixel_format = value;
        else if (!strcmp(argument, "-f")) options->muxer = value;
        else if (!strcmp(argument, "-movflags")) options->movflags = value;
        else if (!strcmp(argument, "-passlogfile")) options->pass_log = value;
        else if (!strcmp(argument, "-tag:v")) {
            if (strlen(value) != 4) return AVERROR(EINVAL);
            options->video_tag = value;
        } else if (!strcmp(argument, "-b:v")) error = mbf_bitrate(value, &options->video_bitrate);
        else if (!strcmp(argument, "-b:a")) error = mbf_bitrate(value, &options->audio_bitrate);
        else if (!strcmp(argument, "-r")) {
            error = av_parse_video_rate(&options->fps, value);
            if (options->fps.num <= 0 || options->fps.den <= 0) error = AVERROR(EINVAL);
        } else if (!strcmp(argument, "-ss")) {
            error = av_parse_time(&options->seek_us, value, 1);
            if (options->seek_us < 0) error = AVERROR(EINVAL);
        } else if (!strcmp(argument, "-frames:v")) {
            error = mbf_integer(value, 1, INT64_MAX, &options->max_video_frames);
        } else if (!strcmp(argument, "-pass")) {
            error = mbf_integer(value, 1, 2, &number);
            options->pass = (int)number;
        } else if (!strcmp(argument, "-ac")) {
            error = mbf_integer(value, 1, 64, &number);
            options->channels = (int)number;
        } else if (!strcmp(argument, "-ar")) {
            error = mbf_integer(value, 1, 768000, &number);
            options->sample_rate = (int)number;
        } else if (!strcmp(argument, "-map")) {
            options->maps_present = 1;
            if (!strcmp(value, "0:a:0") || !strcmp(value, "0:a:0?")) {
                options->map_audio = 1;
                options->optional_audio = value[strlen(value) - 1] == '?';
            } else if (!strcmp(value, "0:v:0") || !strcmp(value, "0:v:0?")) {
                options->map_video = 1;
                options->optional_video = value[strlen(value) - 1] == '?';
            } else error = AVERROR(EINVAL);
        } else if (!strcmp(argument, "-map_metadata")) {
            if (!strcmp(value, "-1")) options->clear_metadata = 1;
            else if (strcmp(value, "0")) error = AVERROR(EINVAL);
        } else if (!strcmp(argument, "-map_chapters")) {
            if (!strcmp(value, "-1")) options->clear_chapters = 1;
            else error = AVERROR(EINVAL);
        } else if (!strncmp(argument, "-map_metadata:s:", 16) || !strncmp(argument, "-map_metadata_input:s:", 22)) {
            int source_index = !strncmp(argument, "-map_metadata_input:s:", 22);
            error = mbf_integer(argument + (source_index ? 22 : 16), 0, INT_MAX, &number);
            if (strcmp(value, "-1")) error = AVERROR(EINVAL);
            if (!error) {
                MBFMetadata *metadata = mbf_metadata(options, (int)number, source_index);
                if (!metadata) return AVERROR(ENOMEM);
                metadata->clear = 1;
            }
        } else if (!strcmp(argument, "-metadata") || !strncmp(argument, "-metadata:s:", 12) ||
                   !strncmp(argument, "-metadata_input:s:", 18)) {
            number = -1;
            int source_index = !strncmp(argument, "-metadata_input:s:", 18);
            if (strcmp(argument, "-metadata")) error = mbf_integer(argument + (source_index ? 18 : 12), 0, INT_MAX, &number);
            const char *equals = strchr(value, '=');
            if (!equals || equals == value) error = AVERROR(EINVAL);
            if (!error) {
                MBFMetadata *metadata = mbf_metadata(options, (int)number, source_index);
                char *key = av_strndup(value, equals - value);
                if (!metadata || !key) { av_free(key); return AVERROR(ENOMEM); }
                error = av_dict_set(&metadata->tags, key, equals + 1, 0);
                av_free(key);
            }
        } else {
            mbf_log(job, "Unsupported conversion option: %s", argument);
            return AVERROR(ENOSYS);
        }
        if (error < 0) {
            mbf_log(job, "Invalid value for %s: %s", argument, value);
            return error;
        }
    }
    if (!options->input || !*options->input || !options->output || !*options->output) return AVERROR(EINVAL);
    if (options->pass && !options->pass_log) return AVERROR(EINVAL);
    if (!strcmp(options->input, options->output)) return AVERROR(EINVAL);
    struct stat input_stat, output_stat;
    if (!stat(options->input, &input_stat) && !stat(options->output, &output_stat) &&
        input_stat.st_dev == output_stat.st_dev && input_stat.st_ino == output_stat.st_ino) return AVERROR(EINVAL);
    return 0;
}

static enum AVPixelFormat mbf_pixel_format(const AVCodec *codec, enum AVPixelFormat input,
                                         const char *requested) {
    const enum AVPixelFormat *formats = NULL;
    int count = 0;
    avcodec_get_supported_config(NULL, codec, AV_CODEC_CONFIG_PIX_FORMAT, 0, (const void **)&formats, &count);
    enum AVPixelFormat preferred = requested ? av_get_pix_fmt(requested) : input;
    if (requested && preferred == AV_PIX_FMT_NONE) return AV_PIX_FMT_NONE;
    if (!formats) return preferred;
    for (int i = 0; i < count; ++i) if (formats[i] == preferred) return preferred;
    if (requested) return AV_PIX_FMT_NONE;
    for (int i = 0; i < count; ++i) if (formats[i] == AV_PIX_FMT_YUV420P) return AV_PIX_FMT_YUV420P;
    for (int i = 0; i < count; ++i) {
        const AVPixFmtDescriptor *description = av_pix_fmt_desc_get(formats[i]);
        if (description && !(description->flags & AV_PIX_FMT_FLAG_HWACCEL)) return formats[i];
    }
    return AV_PIX_FMT_NONE;
}

static int mbf_audio_format(MBFJob *job, MBFStream *stream, const AVCodec *codec) {
    AVCodecContext *decoder = stream->decoder, *encoder = stream->encoder;
    const enum AVSampleFormat *formats = NULL;
    int count = 0;
    avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_FORMAT, 0, (const void **)&formats, &count);
    encoder->sample_fmt = formats && count > 0 ? formats[0] : decoder->sample_fmt;
    int best_score = INT_MIN;
    for (int i = 0; formats && i < count; ++i) {
        int source_bytes = av_get_bytes_per_sample(decoder->sample_fmt);
        int target_bytes = av_get_bytes_per_sample(formats[i]);
        int score = -abs(target_bytes - source_bytes);
        if (target_bytes < source_bytes) score -= 100;
        if (av_get_packed_sample_fmt(formats[i]) == av_get_packed_sample_fmt(decoder->sample_fmt)) score = 900;
        if (formats[i] == decoder->sample_fmt) score = 1000;
        if (score > best_score) { best_score = score; encoder->sample_fmt = formats[i]; }
    }
    encoder->bits_per_raw_sample = decoder->bits_per_raw_sample;
    if (codec->id == AV_CODEC_ID_FLAC && encoder->sample_fmt == AV_SAMPLE_FMT_S32) {
        enum AVSampleFormat packed = av_get_packed_sample_fmt(decoder->sample_fmt);
        if (packed != AV_SAMPLE_FMT_FLT && packed != AV_SAMPLE_FMT_DBL && decoder->bits_per_raw_sample > 24) {
            mbf_log(job, "This FLAC encoder supports up to 24-bit integer input; refusing to truncate %d-bit samples.", decoder->bits_per_raw_sample);
            return AVERROR(ENOSYS);
        }
        encoder->bits_per_raw_sample = 24;
    }
    const int *rates = NULL;
    int desired_rate = job->options.sample_rate ? job->options.sample_rate : decoder->sample_rate;
    avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_SAMPLE_RATE, 0, (const void **)&rates, &count);
    encoder->sample_rate = desired_rate;
    if (rates && count > 0) {
        encoder->sample_rate = rates[0];
        for (int i = 0; i < count; ++i) {
            if (abs(rates[i] - desired_rate) < abs(encoder->sample_rate - desired_rate)) encoder->sample_rate = rates[i];
        }
        if (job->options.sample_rate && encoder->sample_rate != desired_rate) return AVERROR(EINVAL);
    }
    if (job->options.channels) av_channel_layout_default(&encoder->ch_layout, job->options.channels);
    else if (av_channel_layout_copy(&encoder->ch_layout, &decoder->ch_layout) < 0) return AVERROR(ENOMEM);
    const AVChannelLayout *layouts = NULL;
    avcodec_get_supported_config(encoder, codec, AV_CODEC_CONFIG_CHANNEL_LAYOUT, 0, (const void **)&layouts, &count);
    if (layouts && count > 0) {
        int best = 0, supported = 0;
        for (int i = 0; i < count; ++i) {
            if (av_channel_layout_compare(&layouts[i], &encoder->ch_layout) == 0) { supported = 1; break; }
            if (abs(layouts[i].nb_channels - encoder->ch_layout.nb_channels) <
                abs(layouts[best].nb_channels - encoder->ch_layout.nb_channels)) best = i;
        }
        if (!supported) {
            if (job->options.channels && layouts[best].nb_channels != job->options.channels) return AVERROR(EINVAL);
            av_channel_layout_uninit(&encoder->ch_layout);
            if (av_channel_layout_copy(&encoder->ch_layout, &layouts[best]) < 0) return AVERROR(ENOMEM);
        }
    }
    encoder->time_base = (AVRational){1, encoder->sample_rate};
    return encoder->sample_fmt == AV_SAMPLE_FMT_NONE || encoder->sample_rate <= 0 ? AVERROR(EINVAL) : 0;
}

/* Display matrices describe presentation orientation, whereas decoder frames
 * contain stored pixels. Apply orientation before the app's crop/rotation.
 * The determinant distinguishes mirrored captures from pure rotations. */
static void mbf_orientation(AVBPrint *description, const AVStream *stream) {
    const AVPacketSideData *side = av_packet_side_data_get(stream->codecpar->coded_side_data,
        stream->codecpar->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (!side || side->size < 9 * sizeof(int32_t)) return;
    int32_t matrix[9];
    memcpy(matrix, side->data, sizeof(matrix));
    double determinant = (double)matrix[0] * matrix[4] - (double)matrix[1] * matrix[3];
    if (determinant < 0 && matrix[0] != INT32_MIN && matrix[1] != INT32_MIN) {
        av_bprintf(description, "hflip,");
        matrix[0] = -matrix[0];
        matrix[1] = -matrix[1];
    }
    double rotation = av_display_rotation_get(matrix);
    if (!isfinite(rotation)) return;
    int angle = ((int)lrint(rotation) % 360 + 360) % 360;
    if (angle == 90) av_bprintf(description, "transpose=cclock,");
    else if (angle == 180) av_bprintf(description, "hflip,vflip,");
    else if (angle == 270) av_bprintf(description, "transpose=clock,");
    else if (angle != 0) {
        double radians = -rotation * 0.017453292519943295;
        av_bprintf(description, "rotate=%.12f:ow=rotw(%.12f):oh=roth(%.12f),", radians, radians, radians);
    }
}

#include "MBFVideoPipeline.h"

static int mbf_filters(MBFJob *job, MBFStream *stream, enum AVPixelFormat pixel_format) {
    AVCodecContext *decoder = stream->decoder, *encoder = stream->encoder;
    int video = decoder->codec_type == AVMEDIA_TYPE_VIDEO;
    char args[1024];
    AVBPrint description;
    av_bprint_init(&description, 256, AV_BPRINT_SIZE_UNLIMITED);
    stream->graph = avfilter_graph_alloc();
    if (!stream->graph) { av_bprint_finalize(&description, NULL); return AVERROR(ENOMEM); }
    stream->graph->nb_threads = mbf_worker_count((int)sysconf(_SC_NPROCESSORS_ONLN), mbf_physical_memory(), stream->decoder->width, stream->decoder->height);
    if (video) {
        AVFrame *first = stream->first_frame;
        AVRational aspect = first ? first->sample_aspect_ratio : decoder->sample_aspect_ratio;
        if (!aspect.num || !aspect.den) aspect = (AVRational){1, 1};
        mbf_orientation(&description, stream->input);
        if (job->options.filter && *job->options.filter) av_bprintf(&description, "%s,", job->options.filter);
        char *hardware = stream->hardware_decode ? mbf_hardware_filters(description.str) : NULL;
        stream->hardware_filter = hardware && av_cmp_q(aspect, (AVRational){1, 1}) == 0 && !stream->tonemap &&
            strstr(encoder->codec->name, "videotoolbox") &&
            (stream->source_format == AV_PIX_FMT_NV12 ||
             (stream->source_format == AV_PIX_FMT_P010LE && encoder->codec_id == AV_CODEC_ID_HEVC)) &&
            !job->options.pixel_format;
        if (job->options.acceleration == 2 && !stream->hardware_filter) {
            av_free(hardware);
            av_bprint_finalize(&description, NULL);
            mbf_log(job, "Required hardware pipeline cannot execute this filter/color/encoder combination");
            return AVERROR(ENOSYS);
        }
        if (stream->hardware_filter) {
            av_bprint_clear(&description);
            av_bprintf(&description, "%s", hardware);
        }
        av_free(hardware);
        if (job->options.fps.num) av_bprintf(&description, "fps=fps=%d/%d,", job->options.fps.num, job->options.fps.den);
        if (stream->tonemap) {
            av_bprintf(&description, "zscale=transfer=linear:npl=100,format=gbrpf32le,"
                "zscale=primaries=bt709,tonemap=mobius:param=0.3:desat=2:peak=%.9g,"
                "zscale=transfer=bt709:matrix=bt709:range=limited:dither=error_diffusion,", stream->signal_peak);
        } else if (stream->pipeline && stream->source_depth > 8 && pixel_format == AV_PIX_FMT_YUV420P) {
            av_bprintf(&description, "zscale=dither=error_diffusion,");
        }
        av_bprintf(&description, "format=pix_fmts=%s", av_get_pix_fmt_name(
            stream->hardware_filter ? AV_PIX_FMT_VIDEOTOOLBOX : pixel_format));
        enum AVPixelFormat source_format = first ?
            (stream->hardware_filter ? AV_PIX_FMT_VIDEOTOOLBOX : stream->source_format) : decoder->pix_fmt;
        snprintf(args, sizeof(args), "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=%d/%d",
                 first ? first->width : decoder->width, first ? first->height : decoder->height, source_format,
                 stream->input->time_base.num, stream->input->time_base.den, aspect.num, aspect.den);
    } else {
        char input_layout[256], output_layout[256];
        av_channel_layout_describe(&decoder->ch_layout, input_layout, sizeof(input_layout));
        av_channel_layout_describe(&encoder->ch_layout, output_layout, sizeof(output_layout));
        snprintf(args, sizeof(args), "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
                 stream->input->time_base.num, stream->input->time_base.den, decoder->sample_rate,
                 av_get_sample_fmt_name(decoder->sample_fmt), input_layout);
        av_bprintf(&description, "%s,aformat=sample_fmts=%s:sample_rates=%d:channel_layouts=%s",
                   job->options.audio_filter ? job->options.audio_filter : "atrim=start=0",
                   av_get_sample_fmt_name(encoder->sample_fmt), encoder->sample_rate, output_layout);
    }
    stream->source = avfilter_graph_alloc_filter(stream->graph, avfilter_get_by_name(video ? "buffer" : "abuffer"), "input");
    int error = stream->source ? 0 : AVERROR(ENOMEM);
    if (error >= 0 && stream->pipeline) {
        AVBufferSrcParameters *parameters = av_buffersrc_parameters_alloc();
        if (!parameters) error = AVERROR(ENOMEM);
        else {
            parameters->color_space = stream->first_frame->colorspace;
            parameters->color_range = stream->first_frame->color_range;
            if (stream->hardware_filter) parameters->hw_frames_ctx = stream->first_frame->hw_frames_ctx;
            error = av_buffersrc_parameters_set(stream->source, parameters);
            av_free(parameters);
        }
    }
    if (error >= 0) error = avfilter_init_str(stream->source, args);
    if (error >= 0) error = avfilter_graph_create_filter(&stream->sink, avfilter_get_by_name(video ? "buffersink" : "abuffersink"),
                                                       "output", NULL, NULL, stream->graph);
    AVFilterInOut *inputs = avfilter_inout_alloc(), *outputs = avfilter_inout_alloc();
    if (!inputs || !outputs || !av_bprint_is_complete(&description)) error = AVERROR(ENOMEM);
    if (error >= 0) {
        inputs->name = av_strdup("out");
        inputs->filter_ctx = stream->sink;
        inputs->pad_idx = 0;
        outputs->name = av_strdup("in");
        outputs->filter_ctx = stream->source;
        outputs->pad_idx = 0;
        if (!inputs->name || !outputs->name) error = AVERROR(ENOMEM);
        else error = avfilter_graph_parse_ptr(stream->graph, description.str, &inputs, &outputs, NULL);
        if (error >= 0 && (inputs || outputs)) error = AVERROR(EINVAL);
        if (error >= 0) error = avfilter_graph_config(stream->graph, NULL);
    }
    if (stream->pipeline) mbf_log(job, "Video filters (%s): %s", stream->hardware_filter ? "VideoToolbox" : "CPU", description.str);
    avfilter_inout_free(&inputs);
    avfilter_inout_free(&outputs);
    av_bprint_finalize(&description, NULL);
    if (error < 0 && stream->hardware_filter) mbf_hardware_error(job, error);
    return error;
}

static int mbf_pass_options(MBFJob *job, MBFStream *stream) {
    if (!job->options.pass || stream->decoder->codec_type != AVMEDIA_TYPE_VIDEO) return 0;
    char *filename = av_asprintf("%s-0.log", job->options.pass_log);
    if (!filename) return AVERROR(ENOMEM);
    if (job->options.pass == 1) {
        stream->encoder->flags |= AV_CODEC_FLAG_PASS1;
        stream->pass_file = fopen(filename, "wb");
        av_free(filename);
        return stream->pass_file ? 0 : AVERROR(errno);
    }
    stream->encoder->flags |= AV_CODEC_FLAG_PASS2;
    FILE *file = fopen(filename, "rb");
    av_free(filename);
    if (!file) return AVERROR(errno);
    int error = 0;
    if (fseek(file, 0, SEEK_END) < 0) error = AVERROR(errno);
    long size = error ? -1 : ftell(file);
    if (size <= 0 || size > 128 * 1024 * 1024) error = AVERROR(EINVAL);
    if (!error && fseek(file, 0, SEEK_SET) < 0) error = AVERROR(errno);
    if (!error) {
        stream->encoder->stats_in = av_mallocz((size_t)size + 1);
        if (!stream->encoder->stats_in) error = AVERROR(ENOMEM);
        else if (fread(stream->encoder->stats_in, 1, (size_t)size, file) != (size_t)size) error = AVERROR(EIO);
    }
    fclose(file);
    return error;
}

static int mbf_initialize_stream(MBFJob *job, int index, const char *codec_name) {
    MBFStream *stream = &job->streams[job->stream_count++];
    stream->input_index = index;
    stream->input = job->input->streams[index];
    stream->output = avformat_new_stream(job->output, NULL);
    if (!stream->output) return AVERROR(ENOMEM);
    enum AVMediaType type = stream->input->codecpar->codec_type;
    stream->copy = codec_name && !strcmp(codec_name, "copy");
    if (stream->copy && type == AVMEDIA_TYPE_AUDIO && job->options.audio_filter) {
        mbf_log(job, "Audio filters require re-encoding; stream copy cannot apply edits");
        return AVERROR(EINVAL);
    }
    int error;
    if (stream->copy) {
        error = avcodec_parameters_copy(stream->output->codecpar, stream->input->codecpar);
        if (error < 0) return error;
        stream->output->codecpar->codec_tag = 0;
        stream->output->time_base = stream->input->time_base;
        stream->output->avg_frame_rate = stream->input->avg_frame_rate;
        stream->output->sample_aspect_ratio = stream->input->sample_aspect_ratio;
        // FFmpeg's MOV muxer otherwise suppresses the Dolby configuration box,
        // even when copying a valid stream whose RPU packets remain intact.
        if (type == AVMEDIA_TYPE_VIDEO && mbf_dovi(stream->input->codecpar))
            job->output->strict_std_compliance = FF_COMPLIANCE_UNOFFICIAL;
    } else {
        const AVCodec *decoder = stream->input->codecpar->codec_id == AV_CODEC_ID_AV1 ?
            avcodec_find_decoder_by_name("libdav1d") : NULL;
        if (!decoder) decoder = avcodec_find_decoder(stream->input->codecpar->codec_id);
        const AVCodec *encoder = codec_name ? avcodec_find_encoder_by_name(codec_name) :
            avcodec_find_encoder(type == AVMEDIA_TYPE_VIDEO ? job->output->oformat->video_codec : job->output->oformat->audio_codec);
        if (!decoder) return AVERROR_DECODER_NOT_FOUND;
        if (!encoder || encoder->type != type) return AVERROR_ENCODER_NOT_FOUND;
        stream->decoder = avcodec_alloc_context3(decoder);
        stream->encoder = avcodec_alloc_context3(encoder);
        if (!stream->decoder || !stream->encoder) return AVERROR(ENOMEM);
        if ((error = avcodec_parameters_to_context(stream->decoder, stream->input->codecpar)) < 0) return error;
        stream->decoder->pkt_timebase = stream->input->time_base;
        stream->decoder->thread_count = mbf_worker_count((int)sysconf(_SC_NPROCESSORS_ONLN), mbf_physical_memory(), stream->decoder->width, stream->decoder->height);
        stream->pipeline = type == AVMEDIA_TYPE_VIDEO && job->options.video_pipeline;
        if (stream->pipeline && (error = mbf_setup_hardware(job, stream)) < 0) return error;
        if ((error = avcodec_open2(stream->decoder, decoder, NULL)) < 0)
            return stream->hardware_decode ? mbf_hardware_error(job, error) : error;
        if (stream->pipeline) {
            if ((error = mbf_prime_video(job, stream)) < 0) return error;
            if ((error = mbf_prepare_color(job, stream)) < 0) return error;
        }
        if (type == AVMEDIA_TYPE_AUDIO && stream->decoder->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC) {
            int channels = stream->decoder->ch_layout.nb_channels;
            av_channel_layout_uninit(&stream->decoder->ch_layout);
            av_channel_layout_default(&stream->decoder->ch_layout, channels);
        }
        if (job->output->oformat->flags & AVFMT_GLOBALHEADER) stream->encoder->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        enum AVPixelFormat pixel_format = AV_PIX_FMT_NONE;
        if (type == AVMEDIA_TYPE_VIDEO) {
            enum AVPixelFormat preferred = stream->pipeline ? stream->source_format : stream->decoder->pix_fmt;
            if (stream->pipeline && encoder->id == AV_CODEC_ID_HEVC &&
                (stream->source_depth > 8 || mbf_is_hdr(stream->first_frame->color_trc))) preferred = AV_PIX_FMT_P010LE;
            if (stream->tonemap) preferred = AV_PIX_FMT_YUV420P;
            pixel_format = mbf_pixel_format(encoder, preferred, job->options.pixel_format);
            if (stream->pipeline && encoder->id == AV_CODEC_ID_HEVC && preferred == AV_PIX_FMT_P010LE && pixel_format != preferred) {
                mbf_log(job, "Video limitation: HEVC Main10 output is required; refusing an 8-bit downgrade");
                return AVERROR(ENOSYS);
            }
            if (pixel_format == AV_PIX_FMT_NONE) return AVERROR(EINVAL);
            stream->encoder->bit_rate = job->options.video_bitrate;
            if (!stream->pipeline) {
            stream->encoder->color_primaries = stream->decoder->color_primaries;
            stream->encoder->color_trc = stream->decoder->color_trc;
            stream->encoder->colorspace = stream->decoder->colorspace;
            stream->encoder->color_range = stream->decoder->color_range;
            stream->encoder->chroma_sample_location = stream->decoder->chroma_sample_location;
            }
        } else {
            stream->encoder->bit_rate = job->options.audio_bitrate;
            if ((error = mbf_audio_format(job, stream, encoder)) < 0) return error;
        }
        if ((error = mbf_filters(job, stream, pixel_format)) < 0) return error;
        if (type == AVMEDIA_TYPE_VIDEO) {
            stream->encoder->width = av_buffersink_get_w(stream->sink);
            stream->encoder->height = av_buffersink_get_h(stream->sink);
            stream->encoder->pix_fmt = av_buffersink_get_format(stream->sink);
            stream->encoder->sample_aspect_ratio = av_buffersink_get_sample_aspect_ratio(stream->sink);
            if (stream->hardware_filter) {
                stream->encoder->hw_frames_ctx = av_buffer_ref(av_buffersink_get_hw_frames_ctx(stream->sink));
                if (!stream->encoder->hw_frames_ctx) return AVERROR(ENOMEM);
                stream->encoder->sw_pix_fmt = ((AVHWFramesContext *)stream->encoder->hw_frames_ctx->data)->sw_format;
            }
            AVRational fps = job->options.fps.num ? job->options.fps : av_guess_frame_rate(job->input, stream->input, NULL);
            if (!fps.num || !fps.den) fps = (AVRational){25, 1};
            stream->encoder->framerate = fps;
            stream->encoder->time_base = job->options.fps.num ? av_inv_q(fps) : (AVRational){1, 60000};
            stream->encoder->gop_size = FFMAX(1, (int)lrint(av_q2d(fps) * 2));
            if (encoder->id == AV_CODEC_ID_MJPEG) stream->encoder->color_range = AVCOL_RANGE_JPEG;
        }
        stream->encoder->thread_count = mbf_worker_count((int)sysconf(_SC_NPROCESSORS_ONLN), mbf_physical_memory(), stream->encoder->width, stream->encoder->height);
        if ((error = mbf_pass_options(job, stream)) < 0) return error;
        AVDictionary *codec_options = NULL;
        int require_hardware_encoder = stream->pipeline && job->options.acceleration;
        if (strstr(encoder->name, "videotoolbox")) {
            av_dict_set(&codec_options, "allow_sw", require_hardware_encoder ? "0" : "1", 0);
            if (stream->pipeline && encoder->id == AV_CODEC_ID_HEVC && pixel_format == AV_PIX_FMT_P010LE)
                av_dict_set(&codec_options, "profile", "main10", 0);
        }
        if (!strcmp(encoder->name, "libvpx-vp9")) {
            av_dict_set(&codec_options, "deadline", "good", 0);
            av_dict_set(&codec_options, "cpu-used", "4", 0);
        }
        error = avcodec_open2(stream->encoder, encoder, &codec_options);
        av_dict_free(&codec_options);
        if (error < 0) {
            if (stream->pipeline && encoder->id == AV_CODEC_ID_HEVC && pixel_format == AV_PIX_FMT_P010LE)
                mbf_log(job, "Video limitation: HEVC Main10 encoder unavailable for this device or configuration");
            return require_hardware_encoder && strstr(encoder->name, "videotoolbox") ? mbf_hardware_error(job, error) : error;
        }
        if (type == AVMEDIA_TYPE_AUDIO && stream->encoder->frame_size > 0)
            av_buffersink_set_frame_size(stream->sink, stream->encoder->frame_size);
        if ((error = avcodec_parameters_from_context(stream->output->codecpar, stream->encoder)) < 0) return error;
        if ((error = mbf_copy_hdr_to_output(stream)) < 0) return error;
        stream->output->time_base = stream->encoder->time_base;
        stream->output->avg_frame_rate = stream->encoder->framerate;
        stream->output->sample_aspect_ratio = stream->encoder->sample_aspect_ratio;
        mbf_log(job, "Stream %d: %s -> %s", index, decoder->name, encoder->name);
        if (stream->pipeline) mbf_log(job,
            "Video pipeline: decode=%s filter=%s encoder=%s (%s) input=%s output=%s color=%s",
            stream->hardware_decode ? "VideoToolbox hardware required" : "CPU",
            stream->hardware_filter ? "VideoToolbox" : "CPU", encoder->name,
            strstr(encoder->name, "videotoolbox") ? (require_hardware_encoder ? "hardware required" : "software fallback permitted") : "CPU",
            av_get_pix_fmt_name(stream->source_format), av_get_pix_fmt_name(stream->encoder->pix_fmt),
            stream->tonemap ? "HDR to BT.709 SDR" : mbf_is_hdr(stream->first_frame->color_trc) ? "preserve HDR Main10" : "preserve SDR");
    }
    if (type == AVMEDIA_TYPE_VIDEO && job->options.video_tag) {
        const unsigned char *tag = (const unsigned char *)job->options.video_tag;
        stream->output->codecpar->codec_tag = (unsigned)tag[0] | (unsigned)tag[1] << 8 |
            (unsigned)tag[2] << 16 | (unsigned)tag[3] << 24;
    }
    stream->output->disposition = stream->input->disposition;
    if (!job->options.clear_metadata) {
        if ((error = av_dict_copy(&stream->output->metadata, stream->input->metadata, 0)) < 0) return error;
    }
    return 0;
}

static int mbf_select_stream(MBFJob *job, enum AVMediaType type, int explicit_map) {
    if (explicit_map) {
        for (unsigned int i = 0; i < job->input->nb_streams; ++i)
            if (job->input->streams[i]->codecpar->codec_type == type) return (int)i;
        return AVERROR_STREAM_NOT_FOUND;
    }
    int index = av_find_best_stream(job->input, type, -1, -1, NULL, 0);
    if (index >= 0 && type == AVMEDIA_TYPE_VIDEO &&
        (job->input->streams[index]->disposition & AV_DISPOSITION_ATTACHED_PIC)) return AVERROR_STREAM_NOT_FOUND;
    return index;
}

static int mbf_open(MBFJob *job) {
    job->input = avformat_alloc_context();
    if (!job->input) return AVERROR(ENOMEM);
    job->input->interrupt_callback = (AVIOInterruptCB){mbf_interrupted, job};
    int error = avformat_open_input(&job->input, job->options.input, NULL, NULL);
    if (error < 0) return mbf_error(job, error, "Opening input");
    if ((error = avformat_find_stream_info(job->input, NULL)) < 0) return mbf_error(job, error, "Reading input streams");
    job->origin_us = job->input->start_time == AV_NOPTS_VALUE ? 0 : job->input->start_time;
    if ((error = avformat_alloc_output_context2(&job->output, NULL, job->options.muxer, job->options.output)) < 0) return error;
    if (!job->output) return AVERROR(ENOMEM);
    job->output->interrupt_callback = (AVIOInterruptCB){mbf_interrupted, job};
    MBFOptions *options = &job->options;
    if (options->seek_us > 0) {
        int64_t seek = job->origin_us + options->seek_us;
        error = avformat_seek_file(job->input, -1, INT64_MIN, seek, seek, 0);
        if (error < 0) return mbf_error(job, error, "Seeking input");
        for (int i = 0; i < job->stream_count; ++i)
            if (job->streams[i].decoder) avcodec_flush_buffers(job->streams[i].decoder);
    }
    int want_video = !options->no_video && (options->maps_present ? options->map_video :
                    (options->video_codec || job->output->oformat->video_codec != AV_CODEC_ID_NONE));
    int want_audio = !options->no_audio && (options->maps_present ? options->map_audio :
                    (options->audio_codec || job->output->oformat->audio_codec != AV_CODEC_ID_NONE));
    if (want_video) {
        int index = mbf_select_stream(job, AVMEDIA_TYPE_VIDEO, options->maps_present);
        if (index >= 0) {
            if ((error = mbf_initialize_stream(job, index, options->video_codec)) < 0) return mbf_error(job, error, "Initializing video");
        } else if (options->maps_present && !options->optional_video) return index;
    }
    if (want_audio) {
        int index = mbf_select_stream(job, AVMEDIA_TYPE_AUDIO, options->maps_present);
        if (index >= 0) {
            if ((error = mbf_initialize_stream(job, index, options->audio_codec)) < 0) return mbf_error(job, error, "Initializing audio");
        } else if (options->maps_present && !options->optional_audio) return index;
    }
    if (!job->stream_count) return AVERROR_STREAM_NOT_FOUND;
    if (!options->clear_metadata && (error = av_dict_copy(&job->output->metadata, job->input->metadata, 0)) < 0) return error;
    for (MBFMetadata *item = options->metadata; item; item = item->next) {
        int index = item->stream_index;
        if (item->source_index) {
            index = -2;
            for (int i = 0; i < job->stream_count; ++i) {
                if (job->streams[i].input_index == item->stream_index) index = job->streams[i].output->index;
            }
        }
        AVDictionary **target = index == -1 ? &job->output->metadata :
            ((unsigned)index < job->output->nb_streams ? &job->output->streams[index]->metadata : NULL);
        if (!target) continue; // A removed source stream has no output metadata.
        if (item->clear) av_dict_free(target);
        AVDictionaryEntry *tag = NULL;
        while ((tag = av_dict_get(item->tags, "", tag, AV_DICT_IGNORE_SUFFIX))) {
            if ((error = av_dict_set(target, tag->key, *tag->value ? tag->value : NULL, 0)) < 0) return error;
        }
    }
    // Display orientation is now baked into re-encoded pixels. Older inputs
    // can also carry a rotate tag instead of (or alongside) a display matrix.
    for (int i = 0; i < job->stream_count; ++i) {
        MBFStream *stream = &job->streams[i];
        if (!stream->copy && stream->input->codecpar->codec_type == AVMEDIA_TYPE_VIDEO)
            av_dict_set(&stream->output->metadata, "rotate", NULL, 0);
    }
    if (!(job->output->oformat->flags & AVFMT_NOFILE)) {
        struct stat output_stat;
        if (!options->overwrite && !stat(options->output, &output_stat)) return AVERROR(EEXIST);
        error = avio_open2(&job->output->pb, options->output, AVIO_FLAG_WRITE, &job->output->interrupt_callback, NULL);
        if (error < 0) return mbf_error(job, error, "Opening output");
        job->output_opened = 1;
    }
    AVDictionary *muxer_options = NULL;
    if (options->movflags) av_dict_set(&muxer_options, "movflags", options->movflags, 0);
    if (!strcmp(job->output->oformat->name, "image2")) av_dict_set(&muxer_options, "update", "1", 0);
    error = avformat_write_header(job->output, &muxer_options);
    if (error >= 0 && av_dict_count(muxer_options)) error = AVERROR_OPTION_NOT_FOUND;
    av_dict_free(&muxer_options);
    return error < 0 ? mbf_error(job, error, "Writing output header") : 0;
}

static void mbf_progress(MBFJob *job, int force) {
    if (!job->progress || job->output_time_us < job->progress_floor_time ||
        job->video_frames < job->progress_floor_frames) return;
    int64_t now = av_gettime_relative();
    if (!force && now - job->last_progress_us < 100000) return;
    if (job->output && job->output->pb) job->bytes = FFMAX(job->bytes, avio_tell(job->output->pb));
    job->last_progress_us = now;
    job->progress(job->context, job->output_time_us, job->bytes, job->video_frames);
}

static int mbf_write_packet(MBFJob *job, MBFStream *stream, AVPacket *packet, AVRational time_base) {
    int64_t timestamp = packet->pts != AV_NOPTS_VALUE ? packet->pts : packet->dts;
    if (timestamp != AV_NOPTS_VALUE) {
        int64_t time_us = av_rescale_q(timestamp + FFMAX(0, packet->duration), time_base, AV_TIME_BASE_Q);
        job->output_time_us = FFMAX(job->output_time_us, time_us);
    }
    av_packet_rescale_ts(packet, time_base, stream->output->time_base);
    packet->stream_index = stream->output->index;
    packet->pos = -1;
    int error = av_interleaved_write_frame(job->output, packet);
    if (error < 0) job->output_error = 1;
    if (error < 0) return error;
    mbf_progress(job, 0);
    return 0;
}

static int mbf_encode(MBFJob *job, MBFStream *stream, AVFrame *frame) {
    if (mbf_interrupted(job)) return AVERROR_EXIT;
#ifdef MBF_TESTING
    if (stream->pipeline && frame && stream->frames == 3 && job->options.acceleration &&
        job->options.test_failure && !strcmp(job->options.test_failure, "mid")) {
        job->hardware_failure = 1;
        return AVERROR_EXTERNAL;
    }
#endif
    int error = avcodec_send_frame(stream->encoder, frame);
    if (error < 0) return stream->pipeline && job->options.acceleration &&
        strstr(stream->encoder->codec->name, "videotoolbox") ? mbf_hardware_error(job, error) : error;
    AVPacket *packet = av_packet_alloc();
    if (!packet) return AVERROR(ENOMEM);
    while ((error = avcodec_receive_packet(stream->encoder, packet)) >= 0) {
        if (stream->pass_file && stream->encoder->stats_out && fputs(stream->encoder->stats_out, stream->pass_file) < 0) {
            error = AVERROR(EIO);
            break;
        }
        error = mbf_write_packet(job, stream, packet, stream->encoder->time_base);
        av_packet_unref(packet);
        if (error < 0 || mbf_interrupted(job)) { if (error >= 0) error = AVERROR_EXIT; break; }
    }
    av_packet_free(&packet);
    if (error < 0 && !job->output_error && stream->pipeline && job->options.acceleration &&
        strstr(stream->encoder->codec->name, "videotoolbox")) mbf_hardware_error(job, error);
    return error == AVERROR(EAGAIN) || error == AVERROR_EOF ? 0 : error;
}

static int mbf_filter_output(MBFJob *job, MBFStream *stream) {
    AVFrame *frame = av_frame_alloc();
    if (!frame) return AVERROR(ENOMEM);
    int error;
    while ((error = av_buffersink_get_frame(stream->sink, frame)) >= 0) {
        int video = stream->encoder->codec_type == AVMEDIA_TYPE_VIDEO;
        if (video && stream->frames >= job->options.max_video_frames) { av_frame_unref(frame); continue; }
        AVRational time_base = av_buffersink_get_time_base(stream->sink);
        frame->pts = av_rescale_q(frame->pts, time_base, stream->encoder->time_base);
        frame->duration = av_rescale_q(frame->duration, time_base, stream->encoder->time_base);
        if (video) {
            frame->pict_type = AV_PICTURE_TYPE_NONE;
            frame->flags &= ~AV_FRAME_FLAG_KEY;
            av_frame_remove_side_data(frame, AV_FRAME_DATA_DISPLAYMATRIX);
            if (stream->pipeline) mbf_strip_hdr(frame, stream->tonemap);
            job->video_frames++;
        }
        stream->frames++;
        // First-pass encoders can emit no packets. Frame time still drives
        // cancellation UI and unknown-duration estimation during that pass.
        int64_t frame_duration = video ? frame->duration : frame->nb_samples;
        if (frame->pts != AV_NOPTS_VALUE) {
            int64_t end = av_rescale_q(frame->pts + FFMAX(1, frame_duration), stream->encoder->time_base, AV_TIME_BASE_Q);
            job->output_time_us = FFMAX(job->output_time_us, end);
        }
        error = mbf_encode(job, stream, frame);
        av_frame_unref(frame);
        mbf_progress(job, 0);
        if (error < 0) break;
    }
    av_frame_free(&frame);
    if (error == AVERROR_EOF) stream->eof = 1;
    if (error < 0 && stream->hardware_filter && !job->output_error) mbf_hardware_error(job, error);
    return error == AVERROR(EAGAIN) || error == AVERROR_EOF ? 0 : error;
}

static int mbf_process_frame(MBFJob *job, MBFStream *stream, AVFrame *frame) {
    if (mbf_interrupted(job)) return AVERROR_EXIT;
    if (stream->eof) return 0;
    if (stream->pipeline) {
        AVFrame *first = stream->first_frame;
        if (frame->width != first->width || frame->height != first->height || frame->format != first->format) {
            mbf_log(job, "Video limitation: Video format changed during conversion");
            return AVERROR_INPUT_CHANGED;
        }
        if (frame->color_primaries == AVCOL_PRI_UNSPECIFIED) frame->color_primaries = first->color_primaries;
        if (frame->color_trc == AVCOL_TRC_UNSPECIFIED) frame->color_trc = first->color_trc;
        if (frame->colorspace == AVCOL_SPC_UNSPECIFIED) frame->colorspace = first->colorspace;
        if (frame->color_range == AVCOL_RANGE_UNSPECIFIED) frame->color_range = first->color_range;
        if (frame->color_primaries != first->color_primaries || frame->color_trc != first->color_trc ||
            frame->colorspace != first->colorspace || frame->color_range != first->color_range) {
            mbf_log(job, "Video limitation: Video color characteristics changed during conversion");
            return AVERROR_INPUT_CHANGED;
        }
    }
    int64_t timestamp = frame->best_effort_timestamp;
    if (timestamp == AV_NOPTS_VALUE) timestamp = stream->next_input_pts;
    int64_t duration = frame->duration;
    if (duration <= 0) {
        duration = stream->decoder->codec_type == AVMEDIA_TYPE_AUDIO ?
            av_rescale_q(frame->nb_samples, (AVRational){1, stream->decoder->sample_rate}, stream->input->time_base) :
            av_rescale_q(1, av_inv_q(stream->encoder->framerate), stream->input->time_base);
    }
    stream->next_input_pts = timestamp + FFMAX(1, duration);
    frame->pts = timestamp - av_rescale_q(job->origin_us + job->options.seek_us, AV_TIME_BASE_Q, stream->input->time_base);
    frame->duration = duration;
    if (stream->decoder->codec_type == AVMEDIA_TYPE_VIDEO && frame->pts < 0) return 0;
    AVFrame *software = NULL;
    int error = 0;
    if (stream->hardware_decode && !stream->hardware_filter) {
        software = av_frame_alloc();
        if (!software) return AVERROR(ENOMEM);
        error = av_hwframe_transfer_data(software, frame, 0);
        if (error >= 0) error = av_frame_copy_props(software, frame);
        if (error < 0) { av_frame_free(&software); return mbf_hardware_error(job, error); }
    }
    error = av_buffersrc_add_frame_flags(stream->source, software ? software : frame, AV_BUFFERSRC_FLAG_KEEP_REF);
    av_frame_free(&software);
    if (error < 0 && stream->hardware_filter) return mbf_hardware_error(job, error);
    if (error >= 0) error = mbf_filter_output(job, stream);
    return error;
}

static int mbf_receive_frames(MBFJob *job, MBFStream *stream) {
    AVFrame *frame = av_frame_alloc();
    if (!frame) return AVERROR(ENOMEM);
    int error;
    while ((error = avcodec_receive_frame(stream->decoder, frame)) >= 0) {
        error = mbf_process_frame(job, stream, frame);
        av_frame_unref(frame);
        if (error < 0) break;
    }
    av_frame_free(&frame);
    if (error == AVERROR(EAGAIN) || error == AVERROR_EOF) return 0;
    if (stream->hardware_decode && !job->output_error) mbf_hardware_error(job, error);
    return error;
}

static int mbf_decode(MBFJob *job, MBFStream *stream, AVPacket *packet) {
    int error = avcodec_send_packet(stream->decoder, packet);
    if (error == AVERROR_EOF && !packet) return 0;
    if (error < 0) return stream->hardware_decode ? mbf_hardware_error(job, error) : error;
    return mbf_receive_frames(job, stream);
}

static int mbf_read_packet(MBFJob *job, AVPacket *packet) {
    if (!job->queued_head) return av_read_frame(job->input, packet);
    MBFQueuedPacket *head = job->queued_head;
    job->queued_head = head->next;
    if (!job->queued_head) job->queued_tail = NULL;
    av_packet_move_ref(packet, head->packet);
    av_packet_free(&head->packet);
    av_free(head);
    return 0;
}

static int mbf_convert(MBFJob *job) {
    for (int i = 0; i < job->stream_count; ++i) {
        MBFStream *stream = &job->streams[i];
        if (!stream->first_frame) continue;
        AVFrame *first = av_frame_clone(stream->first_frame);
        if (!first) return AVERROR(ENOMEM);
        int result = mbf_process_frame(job, stream, first);
        av_frame_free(&first);
        if (result >= 0) result = mbf_receive_frames(job, stream);
        if (result < 0) return result;
    }
    AVPacket *packet = av_packet_alloc();
    if (!packet) return AVERROR(ENOMEM);
    int error = 0, limit = 0;
    while (!limit && (error = mbf_read_packet(job, packet)) >= 0) {
        if (mbf_interrupted(job)) { error = AVERROR_EXIT; break; }
        for (int i = 0; i < job->stream_count; ++i) {
            MBFStream *stream = &job->streams[i];
            if (packet->stream_index != stream->input_index) continue;
            if (stream->copy) {
                int64_t offset = av_rescale_q(job->origin_us + job->options.seek_us, AV_TIME_BASE_Q, stream->input->time_base);
                if (packet->pts != AV_NOPTS_VALUE) packet->pts -= offset;
                if (packet->dts != AV_NOPTS_VALUE) packet->dts -= offset;
                stream->frames++;
                if (stream->input->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) job->video_frames++;
                error = mbf_write_packet(job, stream, packet, stream->input->time_base);
            } else error = mbf_decode(job, stream, packet);
            if (stream->input->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && stream->frames >= job->options.max_video_frames) limit = 1;
            break;
        }
        av_packet_unref(packet);
        if (error < 0) break;
        int all_finished = 1;
        for (int i = 0; i < job->stream_count; ++i) {
            if (!job->streams[i].eof) all_finished = 0;
        }
        if (all_finished) limit = 1;
    }
    av_packet_free(&packet);
    if (error < 0 && error != AVERROR_EOF) return error;
    for (int i = 0; i < job->stream_count; ++i) {
        MBFStream *stream = &job->streams[i];
        if (stream->copy) continue;
        if (!stream->eof) {
            if ((error = mbf_decode(job, stream, NULL)) < 0) return error;
            if ((error = av_buffersrc_add_frame_flags(stream->source, NULL, 0)) < 0) return error;
            if ((error = mbf_filter_output(job, stream)) < 0) return error;
        }
        if ((error = mbf_encode(job, stream, NULL)) < 0) return error;
        // Some two-pass encoders produce their statistics only after draining.
        if (stream->pass_file && ftell(stream->pass_file) == 0 && stream->encoder->stats_out &&
            fputs(stream->encoder->stats_out, stream->pass_file) < 0) return AVERROR(EIO);
        if (stream->pass_file && fflush(stream->pass_file) != 0) return AVERROR(errno);
    }
    if (mbf_interrupted(job)) return AVERROR_EXIT;
    int64_t total_frames = 0;
    for (int i = 0; i < job->stream_count; ++i) total_frames += job->streams[i].frames;
    if (!total_frames) return AVERROR_INVALIDDATA;
    error = av_write_trailer(job->output);
    mbf_progress(job, 1);
    return error;
}

static void mbf_cleanup(MBFJob *job) {
    for (int i = 0; i < job->stream_count; ++i) {
        MBFStream *stream = &job->streams[i];
        if (stream->pass_file) fclose(stream->pass_file);
        av_frame_free(&stream->first_frame);
        avfilter_graph_free(&stream->graph);
        avcodec_free_context(&stream->decoder);
        if (stream->encoder) av_freep(&stream->encoder->stats_in);
        avcodec_free_context(&stream->encoder);
    }
    while (job->queued_head) {
        MBFQueuedPacket *head = job->queued_head;
        job->queued_head = head->next;
        av_packet_free(&head->packet);
        av_free(head);
    }
    avformat_close_input(&job->input);
    if (job->output) {
        if (!(job->output->oformat->flags & AVFMT_NOFILE)) avio_closep(&job->output->pb);
        avformat_free_context(job->output);
    }
    MBFMetadata *item = job->options.metadata;
    while (item) {
        MBFMetadata *next = item->next;
        av_dict_free(&item->tags);
        av_free(item);
        item = next;
    }
}

int mbf_execute(int argc, const char *const *argv, mbf_log_callback log,
                mbf_progress_callback progress, mbf_cancel_callback cancel, void *context) {
    if (argc <= 0 || !argv || !argv[0]) return AVERROR(EINVAL);
    int64_t floor_time = 0, floor_frames = 0;
    int64_t started = av_gettime_relative();
    for (int attempt = 0; attempt < 2; ++attempt) {
        MBFJob job = {0};
        job.log = log;
        job.progress = progress;
        job.cancel = cancel;
        job.context = context;
        job.progress_floor_time = floor_time;
        job.progress_floor_frames = floor_frames;
        int error = mbf_parse(&job, argc, argv);
        if (attempt) job.options.acceleration = 0;
        if (error >= 0 && mbf_interrupted(&job)) error = AVERROR_EXIT;
        if (error >= 0) error = mbf_open(&job);
        if (error >= 0) error = mbf_convert(&job);
        int retry = error < 0 && !attempt && job.options.acceleration == 1 && job.hardware_failure &&
                    !job.output_error && error != AVERROR_EXIT &&
                    (error != AVERROR_INVALIDDATA || job.hardware_failure == 2) && !mbf_interrupted(&job);
        floor_time = job.output_time_us;
        floor_frames = job.video_frames;
        int remove_partial = error < 0 && job.output_opened;
        const char *output = job.options.output;
        if (retry) mbf_log(&job, "MBF_RETRY software decoding/filtering; hardware failure=%d; color policy unchanged", error);
        else {
            if (error < 0) mbf_error(&job, error, "Conversion failed");
            mbf_log(&job, "Conversion elapsed=%.3fs attempts=%d", (av_gettime_relative() - started) / 1000000.0, attempt + 1);
        }
        mbf_cleanup(&job);
        if (remove_partial && output) remove(output);
        if (!retry) return error;
    }
    return AVERROR_BUG;
}

static void mbf_json_string(AVBPrint *json, const char *value) {
    av_bprint_chars(json, '"', 1);
    for (const unsigned char *p = (const unsigned char *)(value ? value : ""); *p; ++p) {
        if (*p == '"' || *p == '\\') { av_bprint_chars(json, '\\', 1); av_bprint_chars(json, *p, 1); }
        else if (*p < 0x20) av_bprintf(json, "\\u%04x", *p);
        else av_bprint_chars(json, *p, 1);
    }
    av_bprint_chars(json, '"', 1);
}

static void mbf_json_tags(AVBPrint *json, AVDictionary *dictionary) {
    av_bprint_chars(json, '{', 1);
    AVDictionaryEntry *entry = NULL;
    int first = 1;
    while ((entry = av_dict_get(dictionary, "", entry, AV_DICT_IGNORE_SUFFIX))) {
        if (!first) av_bprint_chars(json, ',', 1);
        first = 0;
        mbf_json_string(json, entry->key);
        av_bprint_chars(json, ':', 1);
        mbf_json_string(json, entry->value);
    }
    av_bprint_chars(json, '}', 1);
}

static int mbf_probe_interrupted(void *opaque) {
    return av_gettime_relative() >= *(int64_t *)opaque;
}

char *mbf_probe_json(const char *path, int timeout_ms) {
    if (!path || !*path) return NULL;
    int64_t deadline = av_gettime_relative() + (int64_t)(timeout_ms > 0 ? timeout_ms : 10000) * 1000;
    AVFormatContext *format = avformat_alloc_context();
    if (!format) return NULL;
    format->interrupt_callback = (AVIOInterruptCB){mbf_probe_interrupted, &deadline};
    if (avformat_open_input(&format, path, NULL, NULL) < 0) return NULL;
    if (avformat_find_stream_info(format, NULL) < 0 || mbf_probe_interrupted(&deadline)) {
        avformat_close_input(&format);
        return NULL;
    }
    AVBPrint json;
    av_bprint_init(&json, 4096, AV_BPRINT_SIZE_UNLIMITED);
    av_bprintf(&json, "{\"format\":{\"format_name\":");
    mbf_json_string(&json, format->iformat->name);
    if (format->duration != AV_NOPTS_VALUE) av_bprintf(&json, ",\"duration\":\"%.6f\"", format->duration / (double)AV_TIME_BASE);
    if (format->bit_rate > 0) av_bprintf(&json, ",\"bit_rate\":\"%" PRId64 "\"", format->bit_rate);
    int64_t size = format->pb ? avio_size(format->pb) : -1;
    if (size >= 0) av_bprintf(&json, ",\"size\":\"%" PRId64 "\"", size);
    av_bprintf(&json, ",\"tags\":");
    mbf_json_tags(&json, format->metadata);
    av_bprintf(&json, "},\"streams\":[");
    for (unsigned int i = 0; i < format->nb_streams; ++i) {
        AVStream *stream = format->streams[i];
        AVCodecParameters *parameters = stream->codecpar;
        if (i) av_bprint_chars(&json, ',', 1);
        av_bprintf(&json, "{\"index\":%u,\"codec_type\":", i);
        mbf_json_string(&json, av_get_media_type_string(parameters->codec_type));
        av_bprintf(&json, ",\"codec_name\":");
        mbf_json_string(&json, avcodec_get_name(parameters->codec_id));
        if (parameters->width > 0) av_bprintf(&json, ",\"width\":%d,\"height\":%d", parameters->width, parameters->height);
        if (parameters->codec_type == AVMEDIA_TYPE_VIDEO) {
            const AVPixFmtDescriptor *pixel = av_pix_fmt_desc_get(parameters->format);
            av_bprintf(&json, ",\"pix_fmt\":"); mbf_json_string(&json, av_get_pix_fmt_name(parameters->format));
            if (pixel) av_bprintf(&json, ",\"bit_depth\":%d", pixel->comp[0].depth);
            av_bprintf(&json, ",\"color_primaries\":"); mbf_json_string(&json, av_color_primaries_name(parameters->color_primaries));
            av_bprintf(&json, ",\"color_transfer\":"); mbf_json_string(&json, av_color_transfer_name(parameters->color_trc));
            av_bprintf(&json, ",\"color_space\":"); mbf_json_string(&json, av_color_space_name(parameters->color_space));
            av_bprintf(&json, ",\"color_range\":"); mbf_json_string(&json, av_color_range_name(parameters->color_range));
            const AVDOVIDecoderConfigurationRecord *dovi = mbf_dovi(parameters);
            if (dovi) av_bprintf(&json, ",\"dovi_profile\":%u,\"dovi_compatibility_id\":%u", dovi->dv_profile, dovi->dv_bl_signal_compatibility_id);
        }
        av_bprintf(&json, ",\"avg_frame_rate\":\"%d/%d\",\"r_frame_rate\":\"%d/%d\"",
                   stream->avg_frame_rate.num, stream->avg_frame_rate.den, stream->r_frame_rate.num, stream->r_frame_rate.den);
        if (stream->nb_frames > 0) av_bprintf(&json, ",\"nb_frames\":\"%" PRId64 "\"", stream->nb_frames);
        if (stream->duration != AV_NOPTS_VALUE) av_bprintf(&json, ",\"duration\":\"%.6f\"", stream->duration * av_q2d(stream->time_base));
        if (parameters->bit_rate > 0) av_bprintf(&json, ",\"bit_rate\":\"%" PRId64 "\"", parameters->bit_rate);
        if (parameters->sample_rate > 0) av_bprintf(&json, ",\"sample_rate\":\"%d\",\"channels\":%d", parameters->sample_rate, parameters->ch_layout.nb_channels);
        av_bprintf(&json, ",\"tags\":");
        mbf_json_tags(&json, stream->metadata);
        av_bprint_chars(&json, '}', 1);
    }
    av_bprintf(&json, "]}");
    avformat_close_input(&format);
    if (!av_bprint_is_complete(&json)) { av_bprint_finalize(&json, NULL); return NULL; }
    char *temporary = NULL;
    if (av_bprint_finalize(&json, &temporary) < 0) return NULL;
    char *result = strdup(temporary);
    av_free(temporary);
    return result;
}

void mbf_free_string(char *value) { free(value); }
int mbf_has_encoder(const char *name) { return name && avcodec_find_encoder_by_name(name) != NULL; }
int mbf_has_decoder(const char *name) { return name && avcodec_find_decoder_by_name(name) != NULL; }
int mbf_has_muxer(const char *name) { return name && av_guess_format(name, NULL, NULL) != NULL; }
const char *mbf_version(void) { return av_version_info(); }
const char *mbf_license(void) { return avcodec_license(); }
const char *mbf_configuration(void) { return avcodec_configuration(); }
