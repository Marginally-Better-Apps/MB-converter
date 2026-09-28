// SPDX-License-Identifier: MIT
// Private helpers for the app's opt-in video pipeline; public libav APIs only.

static int mbf_is_hdr(enum AVColorTransferCharacteristic transfer) {
    return transfer == AVCOL_TRC_SMPTE2084 || transfer == AVCOL_TRC_ARIB_STD_B67;
}

static const AVDOVIDecoderConfigurationRecord *mbf_dovi(const AVCodecParameters *parameters) {
    const AVPacketSideData *side = av_packet_side_data_get(parameters->coded_side_data,
        parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    return side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord) ? (const void *)side->data : NULL;
}

static int mbf_hardware_error(MBFJob *job, int error) {
    if (error == AVERROR_EXTERNAL || error == AVERROR(ENOSYS) || error == AVERROR(ENOTSUP) ||
        error == AVERROR(EIO) || error == AVERROR(EINVAL)) job->hardware_failure = 1;
    return error;
}

static enum AVPixelFormat mbf_hardware_format(AVCodecContext *decoder, const enum AVPixelFormat *formats) {
    for (; *formats != AV_PIX_FMT_NONE; ++formats)
        if (*formats == AV_PIX_FMT_VIDEOTOOLBOX) return *formats;
    ((MBFStream *)decoder->opaque)->hardware_negotiation_failed = 1;
    return AV_PIX_FMT_NONE;
}

// Keep qualification separate from capability: a supported hardware path can
// still be slower. Expand this allowlist only with recorded device benchmarks.
// See docs/VIDEO_ACCELERATION_VALIDATION.md for the measured acceptance matrix.
static int mbf_qualified_mobile_video(MBFJob *job, MBFStream *stream, const char *model) {
    const AVCodecParameters *input = stream->input->codecpar;
    if (strcmp(model, "iPhone19,2") || stream->encoder->codec_id != AV_CODEC_ID_HEVC ||
        job->options.fps.num || job->options.pixel_format ||
        !((input->width == 3840 && input->height == 2160) ||
          (input->width == 2160 && input->height == 3840))) return 0;
    const AVPixFmtDescriptor *format = av_pix_fmt_desc_get(input->format);
    if (!format) return 0;
    AVBPrint filters;
    av_bprint_init(&filters, 128, AV_BPRINT_SIZE_UNLIMITED);
    mbf_orientation(&filters, stream->input);
    if (job->options.filter && *job->options.filter) av_bprintf(&filters, "%s,", job->options.filter);
    int plain = !filters.len;
    int quarter_turn = !strcmp(filters.str, "transpose=clock,") || !strcmp(filters.str, "transpose=cclock,");
    int allowed = av_bprint_is_complete(&filters) &&
        ((input->codec_id == AV_CODEC_ID_H264 && format->comp[0].depth == 8 &&
          input->color_trc == AVCOL_TRC_BT709 && (plain || quarter_turn)) ||
         (input->codec_id == AV_CODEC_ID_HEVC && format->comp[0].depth == 10 &&
          input->color_trc == AVCOL_TRC_ARIB_STD_B67 && plain));
    av_bprint_finalize(&filters, NULL);
    return allowed;
}

static int mbf_setup_hardware(MBFJob *job, MBFStream *stream) {
    if (!job->options.acceleration) return 0;
#if TARGET_OS_IPHONE
    struct utsname device;
    if (job->options.acceleration == 1 &&
        (uname(&device) || !mbf_qualified_mobile_video(job, stream, device.machine))) {
        mbf_log(job, "Video acceleration policy: CPU decoding/filtering; device/path not performance-qualified");
        return 0;
    }
#else
    (void)mbf_qualified_mobile_video; // Host tests exercise the mobile policy directly.
#endif
#ifdef MBF_TESTING
    if (job->options.test_failure && !strcmp(job->options.test_failure, "init")) {
        job->hardware_failure = 1;
        return AVERROR_EXTERNAL;
    }
#endif
    enum AVCodecID id = stream->decoder->codec_id;
    CMVideoCodecType codec = id == AV_CODEC_ID_H264 ? kCMVideoCodecType_H264 :
                            id == AV_CODEC_ID_HEVC ? kCMVideoCodecType_HEVC : 0;
    if (!codec || !VTIsHardwareDecodeSupported(codec)) {
        if (job->options.acceleration == 2) {
            mbf_log(job, "Required VideoToolbox decoder is unavailable for this codec/device");
            return AVERROR(ENOSYS);
        }
        return 0;
    }
    int error = av_hwdevice_ctx_create(&stream->decoder->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                       NULL, NULL, 0);
    if (error < 0) return mbf_hardware_error(job, error);
    stream->hardware_decode = 1;
    stream->decoder->opaque = stream;
    stream->decoder->get_format = mbf_hardware_format;
    return 0;
}

static int mbf_queue_packet(MBFJob *job, AVPacket *packet) {
    size_t size = sizeof(MBFQueuedPacket) + sizeof(AVPacket) + (size_t)packet->size;
    for (int i = 0; i < packet->side_data_elems; ++i) size += packet->side_data[i].size;
    if (size > 32 * 1024 * 1024 || job->queued_bytes > 32 * 1024 * 1024 - size) return AVERROR(ENOBUFS);
    MBFQueuedPacket *node = av_mallocz(sizeof(*node));
    if (!node) return AVERROR(ENOMEM);
    node->packet = av_packet_clone(packet);
    if (!node->packet) { av_free(node); return AVERROR(ENOMEM); }
    if (job->queued_tail) job->queued_tail->next = node;
    else job->queued_head = node;
    job->queued_tail = node;
    job->queued_bytes += size;
    return 0;
}

// Decode exactly the first video frame before opening the output. Other packets
// are retained, not discarded, so delayed video cannot erase leading audio.
static int mbf_prime_video(MBFJob *job, MBFStream *stream) {
    AVPacket *packet = av_packet_alloc();
    stream->first_frame = av_frame_alloc();
    if (!packet || !stream->first_frame) { av_packet_free(&packet); return AVERROR(ENOMEM); }
    int error;
    while ((error = avcodec_receive_frame(stream->decoder, stream->first_frame)) == AVERROR(EAGAIN)) {
        if (mbf_interrupted(job)) { error = AVERROR_EXIT; break; }
        error = av_read_frame(job->input, packet);
        if (error == AVERROR_EOF) {
            error = avcodec_send_packet(stream->decoder, NULL);
            if (error >= 0) error = avcodec_receive_frame(stream->decoder, stream->first_frame);
            break;
        }
        if (error < 0) break;
        if (packet->stream_index == stream->input_index) error = avcodec_send_packet(stream->decoder, packet);
        else error = mbf_queue_packet(job, packet);
        av_packet_unref(packet);
        if (error < 0) break;
    }
    av_packet_free(&packet);
    if (error == AVERROR(ENOBUFS) && stream->hardware_decode) job->hardware_failure = 1;
    if (error < 0 && stream->hardware_decode) mbf_hardware_error(job, error);
    if (error < 0 && stream->hardware_negotiation_failed) job->hardware_failure = 2;
    return error == AVERROR_EOF ? AVERROR_INVALIDDATA : error;
}

static const struct {
    enum AVPacketSideDataType packet;
    enum AVFrameSideDataType frame;
} mbf_static_hdr[] = {
    {AV_PKT_DATA_MASTERING_DISPLAY_METADATA, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA},
    {AV_PKT_DATA_CONTENT_LIGHT_LEVEL, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL},
    {AV_PKT_DATA_AMBIENT_VIEWING_ENVIRONMENT, AV_FRAME_DATA_AMBIENT_VIEWING_ENVIRONMENT},
};

static int mbf_prepare_color(MBFJob *job, MBFStream *stream) {
    AVFrame *frame = stream->first_frame;
    const AVCodecParameters *input = stream->input->codecpar;
    if (frame->color_primaries == AVCOL_PRI_UNSPECIFIED) frame->color_primaries = input->color_primaries;
    if (frame->color_trc == AVCOL_TRC_UNSPECIFIED) frame->color_trc = input->color_trc;
    if (frame->colorspace == AVCOL_SPC_UNSPECIFIED) frame->colorspace = input->color_space;
    if (frame->color_range == AVCOL_RANGE_UNSPECIFIED) frame->color_range = input->color_range;
    const AVDOVIDecoderConfigurationRecord *dovi = mbf_dovi(input);
    if (dovi) {
        if (!dovi->bl_present_flag || (dovi->dv_bl_signal_compatibility_id != 1 &&
            dovi->dv_bl_signal_compatibility_id != 2 && dovi->dv_bl_signal_compatibility_id != 4)) {
            mbf_log(job, "Video limitation: Unsupported Dolby Vision-only color representation; stream copy is still available");
            return AVERROR(ENOSYS);
        }
        if (frame->color_trc == AVCOL_TRC_UNSPECIFIED)
            frame->color_trc = dovi->dv_bl_signal_compatibility_id == 4 ? AVCOL_TRC_ARIB_STD_B67 :
                              dovi->dv_bl_signal_compatibility_id == 1 ? AVCOL_TRC_SMPTE2084 : AVCOL_TRC_BT709;
        mbf_log(job, "Dolby Vision: using compatible base layer; dynamic metadata is not re-encoded");
    }
    for (unsigned i = 0; i < sizeof(mbf_static_hdr) / sizeof(*mbf_static_hdr); ++i) {
        const AVPacketSideData *side = av_packet_side_data_get(input->coded_side_data,
            input->nb_coded_side_data, mbf_static_hdr[i].packet);
        if (side && !av_frame_get_side_data(frame, mbf_static_hdr[i].frame)) {
            AVFrameSideData *copy = av_frame_new_side_data(frame, mbf_static_hdr[i].frame, side->size);
            if (!copy) return AVERROR(ENOMEM);
            memcpy(copy->data, side->data, side->size);
        }
    }
    stream->source_format = frame->format;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->hw_frames_ctx)
        stream->source_format = ((AVHWFramesContext *)frame->hw_frames_ctx->data)->sw_format;
    const AVPixFmtDescriptor *desc = av_pix_fmt_desc_get(stream->source_format);
    if (!desc) return AVERROR(EINVAL);
    stream->source_depth = desc->comp[0].depth;
    int hdr = mbf_is_hdr(frame->color_trc);
    stream->tonemap = hdr && stream->encoder->codec_id != AV_CODEC_ID_HEVC;
    // HDR with missing matrix/primaries uses its standard BT.2020 encoding.
    // Unspecified SDR metadata is left alone.
    if (hdr) {
        if (frame->color_primaries == AVCOL_PRI_UNSPECIFIED) frame->color_primaries = AVCOL_PRI_BT2020;
        if (frame->colorspace == AVCOL_SPC_UNSPECIFIED) frame->colorspace = AVCOL_SPC_BT2020_NCL;
        if (frame->color_range == AVCOL_RANGE_UNSPECIFIED) frame->color_range = AVCOL_RANGE_MPEG;
    }
    stream->signal_peak = frame->color_trc == AVCOL_TRC_SMPTE2084 ? 100 : 10;
    AVFrameSideData *light = av_frame_get_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    AVFrameSideData *mastering = av_frame_get_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    if (mastering && mastering->size >= sizeof(AVMasteringDisplayMetadata)) {
        const AVMasteringDisplayMetadata *m = (const void *)mastering->data;
        if (m->has_luminance && av_q2d(m->max_luminance) > 0) stream->signal_peak = av_q2d(m->max_luminance) / 100;
    }
    if (light && light->size >= sizeof(AVContentLightMetadata)) {
        const AVContentLightMetadata *m = (const void *)light->data;
        if (m->MaxCLL) stream->signal_peak = m->MaxCLL / 100.0;
    }
    stream->signal_peak = FFMAX(1.0, stream->signal_peak);
    stream->encoder->color_primaries = stream->tonemap ? AVCOL_PRI_BT709 : frame->color_primaries;
    stream->encoder->color_trc = stream->tonemap ? AVCOL_TRC_BT709 : frame->color_trc;
    stream->encoder->colorspace = stream->tonemap ? AVCOL_SPC_BT709 : frame->colorspace;
    stream->encoder->color_range = stream->tonemap ? AVCOL_RANGE_MPEG : frame->color_range;
    stream->encoder->chroma_sample_location = frame->chroma_location;
    return 0;
}

// Only transform the app's simple, literal filter subset. No partial rewriting
// of arbitrary expressions or escaped filter graphs is safe.
static char *mbf_hardware_filters(const char *description) {
    if (strstr(description, ",,") || *description == ',') return NULL;
    if (*description && (!avfilter_get_by_name("scale_vt") || !avfilter_get_by_name("transpose_vt"))) return NULL;
    AVBPrint output;
    av_bprint_init(&output, 128, AV_BPRINT_SIZE_UNLIMITED);
    char *copy = av_strdup(description), *save = NULL;
    if (!copy) return NULL;
    for (char *token = av_strtok(copy, ",", &save); token; token = av_strtok(NULL, ",", &save)) {
        if (!strcmp(token, "transpose=clock")) av_bprintf(&output, "transpose_vt=dir=clock,");
        else if (!strcmp(token, "transpose=cclock")) av_bprintf(&output, "transpose_vt=dir=cclock,");
        else if (!strcmp(token, "hflip")) av_bprintf(&output, "transpose_vt=dir=hflip,");
        else if (!strcmp(token, "vflip")) av_bprintf(&output, "transpose_vt=dir=vflip,");
        else {
            int w, h, end = 0;
            if (sscanf(token, "scale=%d:%d%n", &w, &h, &end) == 2 && !token[end] && w > 0 && h > 0)
                av_bprintf(&output, "scale_vt=w=%d:h=%d,", w, h);
            else { av_free(copy); av_bprint_finalize(&output, NULL); return NULL; }
        }
    }
    av_free(copy);
    char *result = NULL;
    if (av_bprint_finalize(&output, &result) < 0) return NULL;
    return result;
}

static void mbf_strip_hdr(AVFrame *frame, int sdr) {
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DOVI_METADATA);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_VIVID);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_SMPTE_2094_APP5);
    if (sdr) {
        for (unsigned i = 0; i < sizeof(mbf_static_hdr) / sizeof(*mbf_static_hdr); ++i)
            av_frame_remove_side_data(frame, mbf_static_hdr[i].frame);
        frame->color_primaries = AVCOL_PRI_BT709;
        frame->color_trc = AVCOL_TRC_BT709;
        frame->colorspace = AVCOL_SPC_BT709;
        frame->color_range = AVCOL_RANGE_MPEG;
    }
}

static int mbf_copy_hdr_to_output(MBFStream *stream) {
    if (!stream->pipeline || stream->tonemap || !mbf_is_hdr(stream->first_frame->color_trc)) return 0;
    AVCodecParameters *parameters = stream->output->codecpar;
    for (unsigned i = 0; i < sizeof(mbf_static_hdr) / sizeof(*mbf_static_hdr); ++i) {
        AVFrameSideData *side = av_frame_get_side_data(stream->first_frame, mbf_static_hdr[i].frame);
        if (!side) continue;
        AVPacketSideData *copy = av_packet_side_data_new(&parameters->coded_side_data,
            &parameters->nb_coded_side_data, mbf_static_hdr[i].packet, side->size, 0);
        if (!copy) return AVERROR(ENOMEM);
        memcpy(copy->data, side->data, side->size);
    }
    return 0;
}
