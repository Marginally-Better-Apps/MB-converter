// SPDX-License-Identifier: MIT
// Exercise color decisions and metadata handling without a hardware service.
#include "../MBFFmpegBridge.c"
#include <assert.h>

int main(void) {
    MBFJob job = {0};
    MBFStream stream = {.pipeline = 1};
    job.input = avformat_alloc_context();
    job.output = avformat_alloc_context();
    stream.input = avformat_new_stream(job.input, NULL);
    stream.output = avformat_new_stream(job.output, NULL);
    stream.encoder = avcodec_alloc_context3(avcodec_find_encoder_by_name("hevc_videotoolbox"));
    stream.first_frame = av_frame_alloc();
    AVFrame *frame = stream.first_frame;
    frame->format = AV_PIX_FMT_YUV420P10LE;
    frame->color_trc = AVCOL_TRC_SMPTE2084;
    frame->color_primaries = AVCOL_PRI_BT2020;
    frame->colorspace = AVCOL_SPC_BT2020_NCL;
    frame->color_range = AVCOL_RANGE_MPEG;
    AVMasteringDisplayMetadata *mastering = av_mastering_display_metadata_create_side_data(frame);
    mastering->has_luminance = 1;
    mastering->max_luminance = (AVRational){2000, 1};
    AVContentLightMetadata *light = av_content_light_metadata_create_side_data(frame);
    light->MaxCLL = 1000;
    assert(mbf_prepare_color(&job, &stream) == 0);
    assert(!stream.tonemap && stream.source_depth == 10 && stream.signal_peak == 10);
    assert(mbf_copy_hdr_to_output(&stream) == 0);
    assert(av_packet_side_data_get(stream.output->codecpar->coded_side_data,
        stream.output->codecpar->nb_coded_side_data, AV_PKT_DATA_MASTERING_DISPLAY_METADATA));
    stream.encoder->codec_id = AV_CODEC_ID_H264;
    assert(mbf_prepare_color(&job, &stream) == 0);
    assert(stream.tonemap && stream.encoder->color_trc == AVCOL_TRC_BT709);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_CONTENT_LIGHT_LEVEL);
    assert(mbf_prepare_color(&job, &stream) == 0 && stream.signal_peak == 20);
    av_frame_remove_side_data(frame, AV_FRAME_DATA_MASTERING_DISPLAY_METADATA);
    assert(mbf_prepare_color(&job, &stream) == 0 && stream.signal_peak == 100);
    frame->color_trc = AVCOL_TRC_ARIB_STD_B67;
    assert(mbf_prepare_color(&job, &stream) == 0 && stream.signal_peak == 10);
    // Compatible Dolby Vision 8.4 uses the HLG base. Profile 5 is rejected.
    size_t size;
    AVDOVIDecoderConfigurationRecord *dovi = av_dovi_alloc(&size);
    dovi->dv_profile = 8;
    dovi->bl_present_flag = 1;
    dovi->dv_bl_signal_compatibility_id = 4;
    assert(av_packet_side_data_add(&stream.input->codecpar->coded_side_data,
        &stream.input->codecpar->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF, (uint8_t *)dovi, size, 0));
    assert(mbf_prepare_color(&job, &stream) == 0);
    dovi->dv_profile = 5;
    dovi->dv_bl_signal_compatibility_id = 0;
    assert(mbf_prepare_color(&job, &stream) == AVERROR(ENOSYS));
    av_frame_new_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER, 8);
    av_frame_new_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS, 8);
    mbf_strip_hdr(frame, 1);
    assert(!av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER));
    assert(!av_frame_get_side_data(frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS));
    assert(frame->color_trc == AVCOL_TRC_BT709 && frame->color_range == AVCOL_RANGE_MPEG);
    char *filters = mbf_hardware_filters("transpose=clock,hflip,vflip,scale=640:360,");
    assert(filters && !strcmp(filters, "transpose_vt=dir=clock,transpose_vt=dir=hflip,transpose_vt=dir=vflip,scale_vt=w=640:h=360,"));
    av_free(filters);
    assert(!mbf_hardware_filters("crop=80:40,scale=40:20"));
    assert(!mbf_hardware_filters("scale=iw/2:ih/2"));
    // Supported hardware is not automatically qualified for every operation.
    stream.encoder->codec_id = AV_CODEC_ID_HEVC;
    stream.input->codecpar->codec_id = AV_CODEC_ID_H264;
    stream.input->codecpar->format = AV_PIX_FMT_YUV420P;
    stream.input->codecpar->color_trc = AVCOL_TRC_BT709;
    stream.input->codecpar->width = 3840;
    stream.input->codecpar->height = 2160;
    assert(mbf_qualified_mobile_video(&job, &stream, "iPhone19,2"));
    assert(!mbf_qualified_mobile_video(&job, &stream, "unqualified device"));
    job.options.filter = "transpose=clock";
    assert(mbf_qualified_mobile_video(&job, &stream, "iPhone19,2"));
    job.options.filter = "scale=1920:1080";
    assert(!mbf_qualified_mobile_video(&job, &stream, "iPhone19,2"));
    job.options.filter = NULL;
    stream.input->codecpar->width = 1920;
    assert(!mbf_qualified_mobile_video(&job, &stream, "iPhone19,2"));
    AVPacket *packet = av_packet_alloc();
    job.queued_bytes = 32 * 1024 * 1024;
    assert(mbf_queue_packet(&job, packet) == AVERROR(ENOBUFS));
    av_packet_free(&packet);
    av_frame_free(&stream.first_frame);
    avcodec_free_context(&stream.encoder);
    avformat_free_context(job.input);
    avformat_free_context(job.output);
    puts("PASS: HDR peak precedence, 10-bit policy, Dolby Vision compatibility, metadata removal, safe filter translation and priming bound");
}
