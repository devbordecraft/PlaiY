#include "ff_video_decoder.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libavutil/hdr_dynamic_metadata.h>
#include <libavutil/dovi_meta.h>
#include <libswscale/swscale.h>
}

#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#endif

static constexpr const char* TAG = "FFVideoDecoder";

namespace py {

FFVideoDecoder::FFVideoDecoder() = default;

FFVideoDecoder::~FFVideoDecoder() {
    close();
}

Error FFVideoDecoder::open(const TrackInfo& track) {
    close();
    track_info_ = track;

    const AVCodec* codec = avcodec_find_decoder(static_cast<AVCodecID>(track.codec_id));
    if (!codec) {
        return {ErrorCode::UnsupportedCodec, "No FFmpeg decoder for codec: " + track.codec_name};
    }

    codec_ctx_ = avcodec_alloc_context3(codec);
    if (!codec_ctx_) {
        return {ErrorCode::OutOfMemory, "Failed to allocate codec context"};
    }

    codec_ctx_->width = track.width;
    codec_ctx_->height = track.height;
    codec_ctx_->pix_fmt = AV_PIX_FMT_NONE;

    // Set extradata
    if (!track.extradata.empty()) {
        codec_ctx_->extradata_size = static_cast<int>(track.extradata.size());
        codec_ctx_->extradata = static_cast<uint8_t*>(
            av_mallocz(track.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        if (codec_ctx_->extradata) {
            memcpy(codec_ctx_->extradata, track.extradata.data(), track.extradata.size());
        }
    }

    // Request multi-threaded decoding
    codec_ctx_->thread_count = 0; // auto
    codec_ctx_->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

    int ret = avcodec_open2(codec_ctx_, codec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        close();
        return {ErrorCode::DecoderInitFailed, std::string("Failed to open decoder: ") + errbuf};
    }

    av_frame_ = av_frame_alloc();
    if (!av_frame_) {
        close();
        return {ErrorCode::OutOfMemory, "Failed to allocate frame"};
    }

    PY_LOG_INFO(TAG, "Opened software decoder: %s (%dx%d)", codec->name, track.width, track.height);
    return Error::Ok();
}

void FFVideoDecoder::close() {
    if (reuse_pkt_) {
        av_packet_free(&reuse_pkt_);
        reuse_pkt_ = nullptr;
    }
    if (av_frame_) {
        av_frame_free(&av_frame_);
        av_frame_ = nullptr;
    }
    if (codec_ctx_) {
        avcodec_free_context(&codec_ctx_);
        codec_ctx_ = nullptr;
    }
    if (sws_ctx_) {
        sws_freeContext(sws_ctx_);
        sws_ctx_ = nullptr;
    }
#ifdef __APPLE__
    if (cv_pool_) {
        CVPixelBufferPoolRelease(static_cast<CVPixelBufferPoolRef>(cv_pool_));
        cv_pool_ = nullptr;
    }
#endif
}

void FFVideoDecoder::flush() {
    if (codec_ctx_) {
        avcodec_flush_buffers(codec_ctx_);
    }
    skip_mode_ = false;
    pts_only_output_ = false;
}

void FFVideoDecoder::set_pts_only_output(bool enabled) {
    pts_only_output_ = enabled;
}

void FFVideoDecoder::set_skip_mode(bool skip) {
    skip_mode_ = skip;
    if (codec_ctx_) {
        if (skip) {
            saved_skip_frame_ = codec_ctx_->skip_frame;
            codec_ctx_->skip_frame = AVDISCARD_NONREF;
        } else {
            codec_ctx_->skip_frame = static_cast<AVDiscard>(saved_skip_frame_);
        }
    }
}

Error FFVideoDecoder::send_packet(const Packet& pkt) {
    if (!codec_ctx_) return {ErrorCode::InvalidState, "Decoder not open"};

    // Set pkt_timebase from the first real packet so PTS conversion works
    if (codec_ctx_->pkt_timebase.den == 0 && !pkt.is_flush && pkt.time_base_den > 0) {
        codec_ctx_->pkt_timebase = AVRational{pkt.time_base_num, pkt.time_base_den};
    }

    if (!reuse_pkt_) {
        reuse_pkt_ = av_packet_alloc();
        if (!reuse_pkt_) return {ErrorCode::OutOfMemory};
    }
    av_packet_unref(reuse_pkt_);

    if (pkt.is_flush) {
        reuse_pkt_->data = nullptr;
        reuse_pkt_->size = 0;
    } else {
        reuse_pkt_->data = const_cast<uint8_t*>(pkt.data.data());
        reuse_pkt_->size = static_cast<int>(pkt.data.size());
        reuse_pkt_->pts = pkt.pts;
        reuse_pkt_->dts = pkt.dts;
        reuse_pkt_->duration = pkt.duration;
    }

    int ret = avcodec_send_packet(codec_ctx_, pkt.is_flush ? nullptr : reuse_pkt_);

    if (ret == AVERROR(EAGAIN)) return {ErrorCode::NeedMoreInput};
    if (ret == AVERROR_EOF) return {ErrorCode::EndOfFile};
    if (ret < 0) return {ErrorCode::DecoderError, "send_packet failed"};

    return Error::Ok();
}

Error FFVideoDecoder::receive_frame(VideoFrame& out) {
    if (!codec_ctx_ || !av_frame_) return {ErrorCode::InvalidState};

    int ret = avcodec_receive_frame(codec_ctx_, av_frame_);
    if (ret == AVERROR(EAGAIN)) return {ErrorCode::OutputNotReady};
    if (ret == AVERROR_EOF) return {ErrorCode::EndOfFile};
    if (ret < 0) return {ErrorCode::DecoderError, "receive_frame failed"};

    if (skip_mode_ || pts_only_output_) {
        // Skip mode: extract only PTS for skip-to-target comparison.
        // Avoids metadata extraction, CVPixelBuffer alloc, and sws_scale.
        out = VideoFrame{};
        out.pts_only = true;
        if (av_frame_->pts != AV_NOPTS_VALUE) {
            AVRational tb = codec_ctx_->time_base;
            if (codec_ctx_->pkt_timebase.den > 0) tb = codec_ctx_->pkt_timebase;
            out.pts_us = av_rescale_q(av_frame_->pts, tb, {1, 1000000});
        }
        av_frame_unref(av_frame_);
        return Error::Ok();
    }

    fill_frame(av_frame_, out);
    av_frame_unref(av_frame_);
    return Error::Ok();
}

void FFVideoDecoder::fill_frame(const AVFrame* av_frame, VideoFrame& out) {
    out.width = av_frame->width;
    out.height = av_frame->height;
    out.hardware_frame = false;
    out.color_space = av_frame->colorspace;
    out.color_primaries = av_frame->color_primaries;
    out.color_trc = av_frame->color_trc;
    out.color_range = av_frame->color_range;

    // PTS in microseconds
    if (av_frame->pts != AV_NOPTS_VALUE) {
        AVRational tb = codec_ctx_->time_base;
        if (codec_ctx_->pkt_timebase.den > 0) {
            tb = codec_ctx_->pkt_timebase;
        }
        out.pts_us = av_rescale_q(av_frame->pts, tb, {1, 1000000});
    }
    out.duration_us = av_frame->duration > 0
        ? av_rescale_q(av_frame->duration, codec_ctx_->pkt_timebase, {1, 1000000})
        : 0;

    // Copy metadata from track info
    out.hdr_metadata = track_info_.hdr_metadata;
    out.sar_num = track_info_.sar_num;
    out.sar_den = track_info_.sar_den;

    // Extract HDR10+ per-frame dynamic metadata
    {
        AVFrameSideData* sd = av_frame_get_side_data(
            av_frame, AV_FRAME_DATA_DYNAMIC_HDR_PLUS);
        if (sd && sd->size >= sizeof(AVDynamicHDRPlus)) {
            auto* hdr10p = reinterpret_cast<const AVDynamicHDRPlus*>(sd->data);
            out.hdr10plus.present = true;
            out.hdr10plus.targeted_max_luminance =
                static_cast<float>(av_q2d(hdr10p->targeted_system_display_maximum_luminance));

            if (hdr10p->num_windows >= 1) {
                const auto& p = hdr10p->params[0];
                for (int i = 0; i < 3; i++) {
                    out.hdr10plus.maxscl[i] =
                        static_cast<float>(av_q2d(p.maxscl[i]));
                }
                if (p.tone_mapping_flag) {
                    out.hdr10plus.knee_point_x = static_cast<float>(av_q2d(p.knee_point_x));
                    out.hdr10plus.knee_point_y = static_cast<float>(av_q2d(p.knee_point_y));
                    out.hdr10plus.num_bezier_anchors = p.num_bezier_curve_anchors;
                    for (int i = 0; i < p.num_bezier_curve_anchors && i < 15; i++) {
                        out.hdr10plus.bezier_anchors[i] =
                            static_cast<float>(av_q2d(p.bezier_curve_anchors[i]));
                    }
                }
            }
        }
    }

    // Extract Dolby Vision per-frame RPU metadata
    {
        AVFrameSideData* sd = av_frame_get_side_data(
            av_frame, AV_FRAME_DATA_DOVI_METADATA);
        if (sd && sd->data) {
            auto* dovi = reinterpret_cast<const AVDOVIMetadata*>(sd->data);
            const AVDOVIDataMapping* mapping = av_dovi_get_mapping(dovi);
            const AVDOVIColorMetadata* color = av_dovi_get_color(dovi);
            const AVDOVIRpuDataHeader* header = av_dovi_get_header(dovi);

            if (mapping && color && header) {
                out.dovi.present = true;
                out.dovi.source_max_pq = static_cast<float>(color->source_max_pq) / 4095.0f;
                out.dovi.source_min_pq = static_cast<float>(color->source_min_pq) / 4095.0f;

                float coef_scale = 1.0f / static_cast<float>(1 << header->coef_log2_denom);

                // Extract reshaping curves per component
                for (int c = 0; c < 3; c++) {
                    const AVDOVIReshapingCurve& src = mapping->curves[c];
                    auto& dst = out.dovi.curves[c];
                    dst.num_pivots = src.num_pivots;
                    for (int i = 0; i < src.num_pivots && i < 9; i++) {
                        dst.pivots[i] = static_cast<float>(src.pivots[i]) / 4095.0f;
                    }
                    for (int i = 0; i < src.num_pivots - 1 && i < 8; i++) {
                        if (src.mapping_idc[i] == AV_DOVI_MAPPING_POLYNOMIAL) {
                            dst.poly_order[i] = src.poly_order[i];
                            for (int j = 0; j <= src.poly_order[i] && j < 3; j++) {
                                dst.poly_coef[i][j] =
                                    static_cast<float>(src.poly_coef[i][j]) * coef_scale;
                            }
                        }
                    }
                }

                // DM Level 1: per-frame brightness
                AVDOVIDmData* l1 = av_dovi_find_level(dovi, 1);
                if (l1) {
                    out.dovi.min_pq = static_cast<float>(l1->l1.min_pq) / 4095.0f;
                    out.dovi.max_pq = static_cast<float>(l1->l1.max_pq) / 4095.0f;
                    out.dovi.avg_pq = static_cast<float>(l1->l1.avg_pq) / 4095.0f;
                }

                // DM Level 2: trim for target display
                AVDOVIDmData* l2 = av_dovi_find_level(dovi, 2);
                if (l2) {
                    out.dovi.trim_slope = static_cast<float>(l2->l2.trim_slope) / 4096.0f;
                    out.dovi.trim_offset = static_cast<float>(l2->l2.trim_offset) / 4096.0f;
                    out.dovi.trim_power = static_cast<float>(l2->l2.trim_power) / 4096.0f;
                    out.dovi.trim_chroma_weight = static_cast<float>(l2->l2.trim_chroma_weight) / 4096.0f;
                    out.dovi.trim_saturation_gain = static_cast<float>(l2->l2.trim_saturation_gain) / 4096.0f;
                }
            }
        }
    }

#ifdef __APPLE__
    // On Apple, wrap the decoded frame in a CVPixelBuffer so the Metal
    // renderer can create textures from it. The renderer only handles
    // CVPixelBuffer (biplanar NV12/P010), so we convert if needed.
    bool is_10bit = (av_frame->format == AV_PIX_FMT_YUV420P10LE ||
                     av_frame->format == AV_PIX_FMT_YUV420P10BE ||
                     av_frame->format == AV_PIX_FMT_P010LE ||
                     av_frame->format == AV_PIX_FMT_P010BE ||
                     av_frame->format == AV_PIX_FMT_YUV420P12LE ||
                     av_frame->format == AV_PIX_FMT_YUV420P12BE);

    OSType cv_pix_fmt = is_10bit
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    AVPixelFormat target_av_fmt = is_10bit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;

    out.pixel_format = is_10bit ? PixelFormat::P010 : PixelFormat::NV12;

    CVPixelBufferRef pixel_buffer = nullptr;

    // Lazily create or recreate the CVPixelBufferPool when format changes.
    // The pool reuses IOSurface-backed buffers, avoiding per-frame allocation.
    if (!cv_pool_ || pool_width_ != av_frame->width ||
        pool_height_ != av_frame->height || pool_format_ != cv_pix_fmt) {
        if (cv_pool_) CVPixelBufferPoolRelease(static_cast<CVPixelBufferPoolRef>(cv_pool_));

        CFDictionaryRef empty_dict = CFDictionaryCreate(
            kCFAllocatorDefault, nullptr, nullptr, 0,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        const void* px_keys[] = {
            kCVPixelBufferWidthKey,
            kCVPixelBufferHeightKey,
            kCVPixelBufferPixelFormatTypeKey,
            kCVPixelBufferIOSurfacePropertiesKey,
            kCVPixelBufferMetalCompatibilityKey,
        };
        int w = av_frame->width, h = av_frame->height;
        CFNumberRef cf_w = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &w);
        CFNumberRef cf_h = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &h);
        int fmt_int = static_cast<int>(cv_pix_fmt);
        CFNumberRef cf_fmt = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &fmt_int);
        const void* px_vals[] = { cf_w, cf_h, cf_fmt, empty_dict, kCFBooleanTrue };
        CFDictionaryRef px_attrs = CFDictionaryCreate(
            kCFAllocatorDefault, px_keys, px_vals, 5,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        CVPixelBufferPoolRef pool = nullptr;
        CVReturn ret = CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, px_attrs, &pool);

        CFRelease(px_attrs);
        CFRelease(cf_fmt);
        CFRelease(cf_h);
        CFRelease(cf_w);
        CFRelease(empty_dict);

        if (ret != kCVReturnSuccess || !pool) {
            PY_LOG_ERROR(TAG, "CVPixelBufferPoolCreate failed: %d", ret);
            cv_pool_ = nullptr;
            return;
        }
        cv_pool_ = pool;
        pool_width_ = av_frame->width;
        pool_height_ = av_frame->height;
        pool_format_ = cv_pix_fmt;
    }

    CVReturn cvret = CVPixelBufferPoolCreatePixelBuffer(
        kCFAllocatorDefault, static_cast<CVPixelBufferPoolRef>(cv_pool_), &pixel_buffer);

    if (cvret != kCVReturnSuccess || !pixel_buffer) {
        PY_LOG_ERROR(TAG, "CVPixelBufferPoolCreatePixelBuffer failed: %d", cvret);
        return;
    }

    CVPixelBufferLockBaseAddress(pixel_buffer, 0);

    // Convert from any FFmpeg format to NV12 or P010 using swscale.
    // Cache the SwsContext — only recreate when format/resolution changes.
    uint8_t* dst_data[2];
    int dst_linesize[2];
    dst_data[0] = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0));
    dst_data[1] = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1));
    dst_linesize[0] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0));
    dst_linesize[1] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1));

    int src_fmt = av_frame->format;
    int dst_fmt = static_cast<int>(target_av_fmt);
    if (!sws_ctx_ || sws_src_w_ != av_frame->width || sws_src_h_ != av_frame->height ||
        sws_src_fmt_ != src_fmt || sws_dst_fmt_ != dst_fmt) {
        if (sws_ctx_) sws_freeContext(sws_ctx_);
        sws_ctx_ = sws_getContext(
            av_frame->width, av_frame->height, static_cast<AVPixelFormat>(av_frame->format),
            av_frame->width, av_frame->height, target_av_fmt,
            SWS_BILINEAR, nullptr, nullptr, nullptr);
        sws_src_w_ = av_frame->width;
        sws_src_h_ = av_frame->height;
        sws_src_fmt_ = src_fmt;
        sws_dst_fmt_ = dst_fmt;
    }

    if (sws_ctx_) {
        int sws_ret = sws_scale(sws_ctx_, av_frame->data, av_frame->linesize, 0, av_frame->height,
                                dst_data, dst_linesize);
        if (sws_ret < 0) {
            CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
            CVPixelBufferRelease(pixel_buffer);
            PY_LOG_WARN(TAG, "sws_scale failed: %d", sws_ret);
            return;
        }
    }

    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

    out.native_buffer = pixel_buffer;
    out.owns_native_buffer = true;
    out.hardware_frame = true; // Treat as hardware frame for the renderer
#else
    // Non-Apple: keep raw plane data
    switch (av_frame->format) {
        case AV_PIX_FMT_NV12:         out.pixel_format = PixelFormat::NV12; break;
        case AV_PIX_FMT_P010LE:
        case AV_PIX_FMT_P010BE:       out.pixel_format = PixelFormat::P010; break;
        case AV_PIX_FMT_YUV420P:      out.pixel_format = PixelFormat::YUV420P; break;
        case AV_PIX_FMT_YUV420P10LE:
        case AV_PIX_FMT_YUV420P10BE:  out.pixel_format = PixelFormat::YUV420P10; break;
        default:                        out.pixel_format = PixelFormat::Unknown; break;
    }

    int num_planes = 0;
    int total_size = 0;
    for (int i = 0; i < 4 && av_frame->data[i]; i++) {
        num_planes = i + 1;
        int h = (i == 0) ? av_frame->height : (av_frame->height + 1) / 2;
        total_size += av_frame->linesize[i] * h;
    }

    out.plane_data = std::shared_ptr<uint8_t[]>(new uint8_t[total_size]);
    uint8_t* dst = out.plane_data.get();

    for (int i = 0; i < num_planes; i++) {
        int h = (i == 0) ? av_frame->height : (av_frame->height + 1) / 2;
        int plane_size = av_frame->linesize[i] * h;
        memcpy(dst, av_frame->data[i], plane_size);
        out.planes[i] = dst;
        out.strides[i] = av_frame->linesize[i];
        dst += plane_size;
    }
#endif
}

} // namespace py
