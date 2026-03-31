#include "ff_video_decoder.h"
#include "plaiy/logger.h"

#include <algorithm>
#include <cmath>

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

    // Initialize codec context from AVCodecParameters when available.
    // This properly copies coded_side_data (including AV_PKT_DATA_DOVI_CONF)
    // which is essential for DV RPU parsing with frame-level threading.
    if (track.codec_parameters) {
        avcodec_parameters_to_context(
            codec_ctx_, static_cast<const AVCodecParameters*>(track.codec_parameters));
    } else {
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

        // Manual DOVI config fallback when codec_parameters is not available
        if (!track.dv_config_raw.empty()) {
            AVPacketSideData* sd = av_packet_side_data_new(
                &codec_ctx_->coded_side_data,
                &codec_ctx_->nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF,
                track.dv_config_raw.size(), 0);
            if (sd) {
                memcpy(sd->data, track.dv_config_raw.data(), track.dv_config_raw.size());
            }
        }
    }

    // Request multi-threaded decoding (frame + slice parallelism)
    codec_ctx_->thread_count = 0; // auto
    codec_ctx_->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

    // Film grain: FFmpeg applies grain synthesis by default for AV1/H.266.
    // If film_grain_synthesis_ is false, export raw params instead of applying.
    if (!film_grain_synthesis_) {
        codec_ctx_->export_side_data |= AV_CODEC_EXPORT_DATA_FILM_GRAIN;
    }

    if (track.dv_profile > 0) {
        PY_LOG_INFO(TAG, "DV Profile %d: codec_parameters=%s, nb_coded_side_data=%d",
                    track.dv_profile,
                    track.codec_parameters ? "from demuxer" : "manual",
                    codec_ctx_->nb_coded_side_data);
    }

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
        codec_ctx_->skip_loop_filter = AVDISCARD_DEFAULT;
        codec_ctx_->skip_idct = AVDISCARD_DEFAULT;
    }
    skip_mode_ = false;
    pts_only_output_ = false;
}

void FFVideoDecoder::set_pts_only_output(bool enabled) {
    pts_only_output_ = enabled;
}

void FFVideoDecoder::set_film_grain_synthesis(bool enabled) {
    film_grain_synthesis_ = enabled;
    // Note: this takes effect on next open(), not mid-stream, since
    // the codec context flag must be set before avcodec_open2().
}

void FFVideoDecoder::set_fast_replay_mode(bool enabled) {
    if (!codec_ctx_) return;
    if (enabled) {
        codec_ctx_->skip_loop_filter = AVDISCARD_ALL;
        codec_ctx_->skip_idct = AVDISCARD_NONREF;
    } else {
        codec_ctx_->skip_loop_filter = AVDISCARD_DEFAULT;
        codec_ctx_->skip_idct = AVDISCARD_DEFAULT;
    }
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

    // Set pkt_timebase from the first real packet so PTS conversion works.
    // Check both num==0 and den==0: FFmpeg may pre-init to {0,1} which is
    // effectively unset but has den>0.
    if ((codec_ctx_->pkt_timebase.num == 0 || codec_ctx_->pkt_timebase.den == 0)
        && !pkt.is_flush && pkt.time_base_den > 0) {
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

    if (!fill_frame(av_frame_, out)) {
        out = VideoFrame{};
        av_frame_unref(av_frame_);
        return {ErrorCode::DecoderError, "fill_frame failed"};
    }
    av_frame_unref(av_frame_);
    return Error::Ok();
}

bool FFVideoDecoder::fill_frame(const AVFrame* av_frame, VideoFrame& out) {
    out.width = av_frame->width;
    out.height = av_frame->height;
    out.hardware_frame = false;
    out.color_space = av_frame->colorspace;
    out.color_primaries = av_frame->color_primaries;
    out.color_trc = av_frame->color_trc;
    out.color_range = av_frame->color_range;

    // DV Profile 5: base layer is IPTPQc2 (NOT BT.2020 YCbCr).
    // Set color_space to unspecified so the uniform builder routes to the
    // IPTPQc2 shader path. Force PQ transfer function and full range.
    if (track_info_.dv_profile == 5) {
        out.color_space = 2;   // AVCOL_SPC_UNSPECIFIED → triggers IPTPQc2 in uniform builder
        out.color_trc = 16;    // AVCOL_TRC_SMPTE2084 (PQ)
        out.color_range = 2;   // AVCOL_RANGE_JPEG (full range for IPTPQc2)
    }

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

    // Extract per-frame dynamic metadata (HDR10+ / Dolby Vision).
    // Skip entirely for SDR content — the side data calls are wasted work.
    if (track_info_.hdr_metadata.type != HDRType::SDR) {

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
        if (!sd && track_info_.dv_profile > 0) {
            static bool warned = false;
            if (!warned) {
                warned = true;
                PY_LOG_WARN(TAG, "DV Profile %d: no AV_FRAME_DATA_DOVI_METADATA in frame (RPU not available)",
                            track_info_.dv_profile);
            }
        }
        if (sd) {
            auto* dovi = reinterpret_cast<const AVDOVIMetadata*>(sd->data);
            auto* header = av_dovi_get_header(dovi);
            auto* mapping = av_dovi_get_mapping(dovi);
            auto* color = av_dovi_get_color(dovi);

            // Color matrices: ycc_to_rgb and rgb_to_lms
            out.dovi_color.present = true;
            static bool logged = false;
            if (!logged) {
                PY_LOG_INFO(TAG, "DV RPU: ycc_to_rgb[0..2] = %.4f, %.4f, %.4f  offset = %.4f, %.4f, %.4f",
                            av_q2d(color->ycc_to_rgb_matrix[0]), av_q2d(color->ycc_to_rgb_matrix[1]),
                            av_q2d(color->ycc_to_rgb_matrix[2]),
                            av_q2d(color->ycc_to_rgb_offset[0]), av_q2d(color->ycc_to_rgb_offset[1]),
                            av_q2d(color->ycc_to_rgb_offset[2]));
                const AVDOVIDmData* l1_blk = av_dovi_find_level(dovi, 1);
                if (l1_blk) {
                    PY_LOG_INFO(TAG, "DV RPU L1: min=%d max=%d avg=%d",
                                l1_blk->l1.min_pq, l1_blk->l1.max_pq, l1_blk->l1.avg_pq);
                }
                PY_LOG_INFO(TAG, "DV RPU: coef_log2_denom=%d, bl_bit_depth=%d, reshaping pivots: Y=%d Cb=%d Cr=%d",
                            header->coef_log2_denom, header->bl_bit_depth,
                            mapping->curves[0].num_pivots, mapping->curves[1].num_pivots,
                            mapping->curves[2].num_pivots);
                logged = true;
            }
            for (int i = 0; i < 9; i++) {
                out.dovi_color.ycc_to_rgb_matrix[i] =
                    static_cast<float>(av_q2d(color->ycc_to_rgb_matrix[i]));
                out.dovi_color.rgb_to_lms_matrix[i] =
                    static_cast<float>(av_q2d(color->rgb_to_lms_matrix[i]));
            }
            for (int i = 0; i < 3; i++) {
                out.dovi_color.ycc_to_rgb_offset[i] =
                    static_cast<float>(av_q2d(color->ycc_to_rgb_offset[i]));
            }

            // Compose: HPE LMS-to-BT.2020 * rgb_to_lms (matching libplacebo).
            // The RPU's rgb_to_lms converts the reshaped signal into HPE LMS space.
            // The hardcoded HPE matrix converts HPE LMS to BT.2020 linear RGB.
            // Composing them gives a single matrix for the linear-light step.
            {
                // Hardcoded HPE D65 LMS → BT.2020 RGB (from libplacebo dovi_lms2rgb)
                static const float hpe[9] = {
                     3.06441879f, -2.16597676f,  0.10155818f,
                    -0.65612108f,  1.78554118f, -0.12943749f,
                     0.01736321f, -0.04725154f,  1.03004253f,
                };
                const float* B = out.dovi_color.rgb_to_lms_matrix; // row-major
                float* C = out.dovi_color.lms_to_rgb_matrix;       // result: HPE * B
                // Row-major 3x3 multiply: C = hpe * B
                for (int r = 0; r < 3; r++) {
                    for (int c = 0; c < 3; c++) {
                        C[r * 3 + c] = hpe[r * 3 + 0] * B[0 * 3 + c]
                                      + hpe[r * 3 + 1] * B[1 * 3 + c]
                                      + hpe[r * 3 + 2] * B[2 * 3 + c];
                    }
                }
            }

            // L1 metadata: per-scene brightness (min/max/avg PQ)
            const AVDOVIDmData* l1_block = av_dovi_find_level(dovi, 1);
            if (l1_block) {
                out.dovi_color.has_l1 = true;
                out.dovi_color.l1_min_pq = l1_block->l1.min_pq;
                out.dovi_color.l1_max_pq = l1_block->l1.max_pq;
                out.dovi_color.l1_avg_pq = l1_block->l1.avg_pq;
            }

            // L2 metadata: display trim (slope/offset/power/chroma/saturation)
            const AVDOVIDmData* l2_block = av_dovi_find_level(dovi, 2);
            if (l2_block) {
                out.dovi_color.has_l2 = true;
                out.dovi_color.l2_trim_slope = l2_block->l2.trim_slope;
                out.dovi_color.l2_trim_offset = l2_block->l2.trim_offset;
                out.dovi_color.l2_trim_power = l2_block->l2.trim_power;
                out.dovi_color.l2_trim_chroma_weight = l2_block->l2.trim_chroma_weight;
                out.dovi_color.l2_trim_saturation_gain = l2_block->l2.trim_saturation_gain;
                out.dovi_color.l2_ms_weight = l2_block->l2.ms_weight;
            }

            // Reshaping curves: evaluate into 1024-entry LUTs per component
            float coef_scale = 1.0f / static_cast<float>(1 << header->coef_log2_denom);
            bool any_reshaping = false;
            for (int c = 0; c < 3; c++) {
                const auto& curve = mapping->curves[c];
                if (curve.num_pivots < 2) continue;
                any_reshaping = true;

                // Pivot values are in [0, (1<<bl_bit_depth)-1].
                float bl_max = static_cast<float>((1 << header->bl_bit_depth) - 1);

                for (int s = 0; s < 1024; s++) {
                    float x = static_cast<float>(s) / 1023.0f; // input [0,1]
                    float x_raw = x * bl_max;                   // back to raw range

                    // Find the piece this input falls into
                    int piece = static_cast<int>(curve.num_pivots) - 2;
                    for (int p = 0; p < static_cast<int>(curve.num_pivots) - 1; p++) {
                        if (x_raw < static_cast<float>(curve.pivots[p + 1])) {
                            piece = p;
                            break;
                        }
                    }

                    float y;
                    if (curve.mapping_idc[piece] == AV_DOVI_MAPPING_POLYNOMIAL) {
                        float c0 = static_cast<float>(curve.poly_coef[piece][0]) * coef_scale;
                        float c1 = static_cast<float>(curve.poly_coef[piece][1]) * coef_scale;
                        float c2 = (curve.poly_order[piece] >= 2)
                            ? static_cast<float>(curve.poly_coef[piece][2]) * coef_scale
                            : 0.0f;
                        y = c0 + c1 * x + c2 * x * x;
                    } else {
                        // MMR: Multi-variate Model with Residuals.
                        // Full formula uses all 3 input channels; since this is a 1D LUT
                        // indexed by this component's value, use the diagonal approximation
                        // (s0 = s1 = s2 = x) which captures cross-term powers of x.
                        float R = static_cast<float>(curve.mmr_constant[piece]) * coef_scale;
                        int order = std::min(static_cast<int>(curve.mmr_order[piece]), 3);
                        float sp = 1.0f; // x^(o+1) accumulator
                        for (int o = 0; o < order; o++) {
                            sp *= x;
                            // 7 coefficients per order: s0, s1, s2, s0*s1, s0*s2, s1*s2, s0*s1*s2
                            // With diagonal approximation: s0=s1=s2=x, so s0^k = x^k, s0*s1 = x^2, etc.
                            float sp2 = sp * sp;    // x^(2*(o+1))
                            float sp3 = sp2 * sp;   // x^(3*(o+1))
                            R += static_cast<float>(curve.mmr_coef[piece][o][0]) * coef_scale * sp;
                            R += static_cast<float>(curve.mmr_coef[piece][o][1]) * coef_scale * sp;
                            R += static_cast<float>(curve.mmr_coef[piece][o][2]) * coef_scale * sp;
                            R += static_cast<float>(curve.mmr_coef[piece][o][3]) * coef_scale * sp2;
                            R += static_cast<float>(curve.mmr_coef[piece][o][4]) * coef_scale * sp2;
                            R += static_cast<float>(curve.mmr_coef[piece][o][5]) * coef_scale * sp2;
                            R += static_cast<float>(curve.mmr_coef[piece][o][6]) * coef_scale * sp3;
                        }
                        y = R;
                    }
                    out.dovi_color.reshape_lut[c][s] = std::clamp(y, 0.0f, 1.0f);
                }
            }
            out.dovi_color.has_reshaping = any_reshaping;
        }
    }

    } // HDR metadata extraction

#ifdef __APPLE__
    // On Apple, wrap the decoded frame in a CVPixelBuffer so the Metal
    // renderer can create textures from it. Supports 4:2:0 and 4:2:2 biplanar
    // formats. 4:4:4 is converted to 4:2:2 (no biplanar CVPixelBuffer format).
    bool is_10bit = (av_frame->format == AV_PIX_FMT_YUV420P10LE ||
                     av_frame->format == AV_PIX_FMT_YUV420P10BE ||
                     av_frame->format == AV_PIX_FMT_P010LE ||
                     av_frame->format == AV_PIX_FMT_P010BE ||
                     av_frame->format == AV_PIX_FMT_YUV420P12LE ||
                     av_frame->format == AV_PIX_FMT_YUV420P12BE ||
                     av_frame->format == AV_PIX_FMT_YUV422P10LE ||
                     av_frame->format == AV_PIX_FMT_YUV422P10BE ||
                     av_frame->format == AV_PIX_FMT_YUV444P10LE ||
                     av_frame->format == AV_PIX_FMT_YUV444P10BE);

    // Detect 4:2:2 or 4:4:4 source (4:4:4 will be downconverted to 4:2:2)
    bool is_422_or_444 = (av_frame->format == AV_PIX_FMT_YUV422P ||
                          av_frame->format == AV_PIX_FMT_YUV422P10LE ||
                          av_frame->format == AV_PIX_FMT_YUV422P10BE ||
                          av_frame->format == AV_PIX_FMT_YUV444P ||
                          av_frame->format == AV_PIX_FMT_YUV444P10LE ||
                          av_frame->format == AV_PIX_FMT_YUV444P10BE);

    OSType cv_pix_fmt;
    AVPixelFormat target_av_fmt;
    if (is_422_or_444) {
        // 4:2:2 biplanar preserves horizontal chroma resolution
        if (is_10bit) {
            cv_pix_fmt = kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange;
            target_av_fmt = AV_PIX_FMT_P210LE;
            out.pixel_format = PixelFormat::P210;
        } else {
            cv_pix_fmt = kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange;
            target_av_fmt = AV_PIX_FMT_NV16;
            out.pixel_format = PixelFormat::NV16;
        }
        out.chroma_format = ChromaFormat::Chroma422;
    } else {
        if (is_10bit) {
            cv_pix_fmt = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange;
            target_av_fmt = AV_PIX_FMT_P010LE;
            out.pixel_format = PixelFormat::P010;
        } else {
            cv_pix_fmt = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
            target_av_fmt = AV_PIX_FMT_NV12;
            out.pixel_format = PixelFormat::NV12;
        }
        out.chroma_format = ChromaFormat::Chroma420;
    }

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
            return false;
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
        return false;
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
            SWS_LANCZOS | SWS_ACCURATE_RND, nullptr, nullptr, nullptr);
        if (!sws_ctx_) {
            const char* src_name = av_get_pix_fmt_name(static_cast<AVPixelFormat>(av_frame->format));
            const char* dst_name = av_get_pix_fmt_name(target_av_fmt);
            PY_LOG_ERROR(TAG, "sws_getContext failed: %s -> %s (%dx%d)",
                         src_name ? src_name : "unknown", dst_name ? dst_name : "unknown",
                         av_frame->width, av_frame->height);
            CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
            CVPixelBufferRelease(pixel_buffer);
            return false;
        }
        sws_src_w_ = av_frame->width;
        sws_src_h_ = av_frame->height;
        sws_src_fmt_ = src_fmt;
        sws_dst_fmt_ = dst_fmt;

        // Set correct color space for the scaler to avoid wrong chroma coefficients.
        // For DV Profile 5 (IPTPQc2), the data is NOT BT.2020 YCbCr — it's ICtCp.
        // Use full-range identity to pass through chroma values without conversion.
        if (sws_ctx_) {
            int cs;
            int full_range;
            if (track_info_.dv_profile == 5) {
                // IPTPQc2: pass through chroma unchanged
                cs = SWS_CS_DEFAULT;
                full_range = 1;
            } else {
                cs = (av_frame->colorspace == AVCOL_SPC_BT2020_NCL ||
                      av_frame->colorspace == AVCOL_SPC_BT2020_CL)
                    ? SWS_CS_BT2020 : SWS_CS_ITU709;
                full_range = (av_frame->color_range == AVCOL_RANGE_JPEG) ? 1 : 0;
            }
            const int* coefs = sws_getCoefficients(cs);
            sws_setColorspaceDetails(sws_ctx_, coefs, full_range,
                                     coefs, full_range, 0, 1 << 16, 1 << 16);
        }
    }

    // DV Profile 5: bypass swscale. swscale applies color matrix coefficients
    // even for planar→biplanar, corrupting IPTPQc2 chroma values.
    if (track_info_.dv_profile == 5 &&
        av_frame->format == AV_PIX_FMT_YUV420P10LE) {
        int w = av_frame->width;
        int h = av_frame->height;
        for (int row = 0; row < h; row++) {
            auto* dst_y = reinterpret_cast<uint16_t*>(dst_data[0] + row * dst_linesize[0]);
            auto* src_y = reinterpret_cast<const uint16_t*>(
                av_frame->data[0] + row * av_frame->linesize[0]);
            for (int col = 0; col < w; col++) {
                dst_y[col] = static_cast<uint16_t>(src_y[col] << 6);
            }
        }
        int hw = w / 2, hh = h / 2;
        for (int row = 0; row < hh; row++) {
            auto* dst = reinterpret_cast<uint16_t*>(dst_data[1] + row * dst_linesize[1]);
            auto* src_u = reinterpret_cast<const uint16_t*>(
                av_frame->data[1] + row * av_frame->linesize[1]);
            auto* src_v = reinterpret_cast<const uint16_t*>(
                av_frame->data[2] + row * av_frame->linesize[2]);
            for (int col = 0; col < hw; col++) {
                dst[col * 2]     = static_cast<uint16_t>(src_u[col] << 6);
                dst[col * 2 + 1] = static_cast<uint16_t>(src_v[col] << 6);
            }
        }
    } else if (sws_ctx_) {
        int sws_ret = sws_scale(sws_ctx_, av_frame->data, av_frame->linesize, 0, av_frame->height,
                                dst_data, dst_linesize);
        if (sws_ret < 0) {
            CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);
            CVPixelBufferRelease(pixel_buffer);
            PY_LOG_WARN(TAG, "sws_scale failed: %d", sws_ret);
            return false;
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
    return true;
}

} // namespace py
