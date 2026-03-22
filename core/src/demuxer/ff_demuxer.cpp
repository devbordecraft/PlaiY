#include "ff_demuxer.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/pixdesc.h>
#include <libavutil/mastering_display_metadata.h>
#include <libavutil/dovi_meta.h>
}

static constexpr const char* TAG = "FFDemuxer";

namespace py {

FFDemuxer::FFDemuxer() = default;

FFDemuxer::~FFDemuxer() {
    close();
}

Error FFDemuxer::open(const std::string& path) {
    close();

    int ret = avformat_open_input(&fmt_ctx_, path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        return {ErrorCode::FileNotFound, std::string("Cannot open file: ") + errbuf};
    }

    ret = avformat_find_stream_info(fmt_ctx_, nullptr);
    if (ret < 0) {
        close();
        return {ErrorCode::DemuxerError, "Failed to find stream info"};
    }

    populate_media_info();
    PY_LOG_INFO(TAG, "Opened: %s (%s), duration=%.2fs, %zu tracks",
                path.c_str(), info_.container_format.c_str(),
                info_.duration_us / 1e6, info_.tracks.size());

    return Error::Ok();
}

void FFDemuxer::close() {
    if (reuse_pkt_) {
        av_packet_free(&reuse_pkt_);
        reuse_pkt_ = nullptr;
    }
    if (fmt_ctx_) {
        avformat_close_input(&fmt_ctx_);
        fmt_ctx_ = nullptr;
    }
    info_ = {};
}

const MediaInfo& FFDemuxer::media_info() const {
    return info_;
}

Error FFDemuxer::read_packet(Packet& out) {
    if (!fmt_ctx_) return {ErrorCode::InvalidState, "Demuxer not open"};

    if (!reuse_pkt_) {
        reuse_pkt_ = av_packet_alloc();
        if (!reuse_pkt_) return {ErrorCode::OutOfMemory, "Failed to allocate packet"};
    }

    av_packet_unref(reuse_pkt_);
    int ret = av_read_frame(fmt_ctx_, reuse_pkt_);
    if (ret < 0) {
        if (ret == AVERROR_EOF) return {ErrorCode::EndOfFile};
        return {ErrorCode::DemuxerError, "Error reading packet"};
    }

    out.stream_index = reuse_pkt_->stream_index;
    out.pts = reuse_pkt_->pts;
    out.dts = reuse_pkt_->dts;
    out.duration = reuse_pkt_->duration;
    out.is_keyframe = (reuse_pkt_->flags & AV_PKT_FLAG_KEY) != 0;
    out.is_flush = false;

    if (reuse_pkt_->data && reuse_pkt_->size > 0) {
        size_t new_size = static_cast<size_t>(reuse_pkt_->size);
        out.data.resize(new_size);
        memcpy(out.data.data(), reuse_pkt_->data, new_size);
    } else {
        out.data.clear();
    }

    // Store the time base for this stream
    if (reuse_pkt_->stream_index >= 0 && reuse_pkt_->stream_index < static_cast<int>(fmt_ctx_->nb_streams)) {
        AVRational tb = fmt_ctx_->streams[reuse_pkt_->stream_index]->time_base;
        out.time_base_num = tb.num;
        out.time_base_den = tb.den;
    }

    return Error::Ok();
}

Error FFDemuxer::seek(int64_t timestamp_us) {
    if (!fmt_ctx_) return {ErrorCode::InvalidState, "Demuxer not open"};

    int64_t ts = av_rescale_q(timestamp_us,
                               {1, 1000000},
                               {1, AV_TIME_BASE});

    int ret = avformat_seek_file(fmt_ctx_, -1,
                                  INT64_MIN, ts, INT64_MAX,
                                  0);
    if (ret < 0) {
        return {ErrorCode::DemuxerError, "Seek failed"};
    }

    return Error::Ok();
}

void FFDemuxer::populate_media_info() {
    if (!fmt_ctx_) return;

    info_.file_path = fmt_ctx_->url ? fmt_ctx_->url : "";
    info_.container_format = fmt_ctx_->iformat ? fmt_ctx_->iformat->name : "unknown";
    info_.duration_us = (fmt_ctx_->duration != AV_NOPTS_VALUE)
                            ? av_rescale_q(fmt_ctx_->duration, {1, AV_TIME_BASE}, {1, 1000000})
                            : 0;
    info_.bit_rate = fmt_ctx_->bit_rate;

    int best_video = av_find_best_stream(fmt_ctx_, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    int best_audio = av_find_best_stream(fmt_ctx_, AVMEDIA_TYPE_AUDIO, -1, -1, nullptr, 0);
    int best_sub = av_find_best_stream(fmt_ctx_, AVMEDIA_TYPE_SUBTITLE, -1, -1, nullptr, 0);

    info_.best_video_index = best_video;
    info_.best_audio_index = best_audio;
    info_.best_subtitle_index = best_sub;

    for (unsigned i = 0; i < fmt_ctx_->nb_streams; i++) {
        AVStream* stream = fmt_ctx_->streams[i];
        AVCodecParameters* par = stream->codecpar;

        TrackInfo track;
        track.stream_index = static_cast<int>(i);
        track.codec_id = par->codec_id;

        const AVCodecDescriptor* desc = avcodec_descriptor_get(par->codec_id);
        track.codec_name = desc ? desc->name : "unknown";

        // Language
        const AVDictionaryEntry* lang = av_dict_get(stream->metadata, "language", nullptr, 0);
        if (lang) track.language = lang->value;

        // Title
        const AVDictionaryEntry* title = av_dict_get(stream->metadata, "title", nullptr, 0);
        if (title) track.title = title->value;

        track.is_default = (stream->disposition & AV_DISPOSITION_DEFAULT) != 0;

        // Extradata
        if (par->extradata && par->extradata_size > 0) {
            track.extradata.assign(par->extradata, par->extradata + par->extradata_size);
        }

        switch (par->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
                track.type = MediaType::Video;
                track.width = par->width;
                track.height = par->height;
                track.pixel_format = convert_pixel_format(par->format);
                track.color_space = par->color_space;
                track.color_primaries = par->color_primaries;
                track.color_trc = par->color_trc;
                track.color_range = par->color_range;

                if (stream->avg_frame_rate.den > 0) {
                    track.frame_rate = av_q2d(stream->avg_frame_rate);
                }

                // Sample Aspect Ratio — needed for correct display aspect ratio.
                // Try codec parameters first, then stream-level SAR.
                {
                    AVRational sar = par->sample_aspect_ratio;
                    if (sar.num <= 0 || sar.den <= 0) {
                        sar = stream->sample_aspect_ratio;
                    }
                    if (sar.num > 0 && sar.den > 0) {
                        track.sar_num = sar.num;
                        track.sar_den = sar.den;
                    }
                }

                // HDR metadata detection
                if (par->color_trc == AVCOL_TRC_SMPTE2084) {
                    track.hdr_metadata.type = HDRType::HDR10;
                } else if (par->color_trc == AVCOL_TRC_ARIB_STD_B67) {
                    track.hdr_metadata.type = HDRType::HLG;
                }

                // Check for Dolby Vision side data (FFmpeg 7+ API)
                {
                    const AVPacketSideData* sd = av_packet_side_data_get(
                        stream->codecpar->coded_side_data,
                        stream->codecpar->nb_coded_side_data,
                        AV_PKT_DATA_DOVI_CONF);
                    if (sd && sd->size >= sizeof(AVDOVIDecoderConfigurationRecord)) {
                        auto* dovi = reinterpret_cast<const AVDOVIDecoderConfigurationRecord*>(sd->data);
                        track.dv_profile = dovi->dv_profile;
                        track.dv_level = dovi->dv_level;
                        track.dv_bl_signal_compatibility_id = dovi->dv_bl_signal_compatibility_id;
                        track.hdr_metadata.type = HDRType::DolbyVision;
                        PY_LOG_INFO(TAG, "Stream %d: Dolby Vision profile %d.%d, compat_id=%d",
                                    i, dovi->dv_profile, dovi->dv_level,
                                    dovi->dv_bl_signal_compatibility_id);

                        // Profile 8 with bl_signal_compatibility_id 1 or 2:
                        // Base layer is HDR10-compatible, use HDR10 rendering path
                        if (dovi->dv_profile == 8 &&
                            (dovi->dv_bl_signal_compatibility_id == 1 ||
                             dovi->dv_bl_signal_compatibility_id == 2)) {
                            PY_LOG_INFO(TAG, "  -> BL compatible with HDR10, using HDR10 rendering path");
                        }
                    }
                }

                // Check for HDR10+ dynamic metadata
                {
                    const AVPacketSideData* sd = av_packet_side_data_get(
                        stream->codecpar->coded_side_data,
                        stream->codecpar->nb_coded_side_data,
                        AV_PKT_DATA_DYNAMIC_HDR10_PLUS);
                    if (sd && track.hdr_metadata.type != HDRType::DolbyVision) {
                        if (par->color_trc == AVCOL_TRC_SMPTE2084) {
                            track.hdr_metadata.type = HDRType::HDR10Plus;
                            PY_LOG_INFO(TAG, "Stream %d: HDR10+ dynamic metadata present", i);
                        }
                    }
                }

                // Mastering display metadata
                {
                    const AVPacketSideData* sd = av_packet_side_data_get(
                        stream->codecpar->coded_side_data,
                        stream->codecpar->nb_coded_side_data,
                        AV_PKT_DATA_MASTERING_DISPLAY_METADATA);
                    if (sd && sd->size >= sizeof(AVMasteringDisplayMetadata)) {
                        auto* mdm = reinterpret_cast<const AVMasteringDisplayMetadata*>(sd->data);
                        if (mdm->has_primaries) {
                            for (int j = 0; j < 3; j++) {
                                track.hdr_metadata.display_primaries_x[j] =
                                    static_cast<uint16_t>(av_q2d(mdm->display_primaries[j][0]) * 50000.0);
                                track.hdr_metadata.display_primaries_y[j] =
                                    static_cast<uint16_t>(av_q2d(mdm->display_primaries[j][1]) * 50000.0);
                            }
                            track.hdr_metadata.white_point_x =
                                static_cast<uint16_t>(av_q2d(mdm->white_point[0]) * 50000.0);
                            track.hdr_metadata.white_point_y =
                                static_cast<uint16_t>(av_q2d(mdm->white_point[1]) * 50000.0);
                        }
                        if (mdm->has_luminance) {
                            track.hdr_metadata.max_luminance =
                                static_cast<uint32_t>(av_q2d(mdm->max_luminance) * 10000.0);
                            track.hdr_metadata.min_luminance =
                                static_cast<uint32_t>(av_q2d(mdm->min_luminance) * 10000.0);
                        }
                        PY_LOG_INFO(TAG, "Stream %d mastering display: max_lum=%.0f cd/m2, min_lum=%.4f cd/m2",
                                    i, av_q2d(mdm->max_luminance), av_q2d(mdm->min_luminance));
                    }

                    sd = av_packet_side_data_get(
                        stream->codecpar->coded_side_data,
                        stream->codecpar->nb_coded_side_data,
                        AV_PKT_DATA_CONTENT_LIGHT_LEVEL);
                    if (sd && sd->size >= sizeof(AVContentLightMetadata)) {
                        auto* cll = reinterpret_cast<const AVContentLightMetadata*>(sd->data);
                        track.hdr_metadata.max_content_light_level = static_cast<uint16_t>(cll->MaxCLL);
                        track.hdr_metadata.max_frame_average_light_level = static_cast<uint16_t>(cll->MaxFALL);
                        PY_LOG_INFO(TAG, "Stream %d content light: MaxCLL=%u, MaxFALL=%u",
                                    i, cll->MaxCLL, cll->MaxFALL);
                    }
                }
                break;

            case AVMEDIA_TYPE_AUDIO:
                track.type = MediaType::Audio;
                track.sample_rate = par->sample_rate;
                track.channels = par->ch_layout.nb_channels;
                track.channel_layout = par->ch_layout.u.mask;
                track.bits_per_sample = par->bits_per_raw_sample;
                break;

            case AVMEDIA_TYPE_SUBTITLE:
                track.type = MediaType::Subtitle;
                track.subtitle_format = detect_subtitle_format(par->codec_id);
                break;

            default:
                track.type = MediaType::Unknown;
                break;
        }

        info_.tracks.push_back(std::move(track));
    }
}

PixelFormat FFDemuxer::convert_pixel_format(int ff_format) {
    switch (ff_format) {
        case AV_PIX_FMT_NV12:     return PixelFormat::NV12;
        case AV_PIX_FMT_P010LE:
        case AV_PIX_FMT_P010BE:   return PixelFormat::P010;
        case AV_PIX_FMT_YUV420P:  return PixelFormat::YUV420P;
        case AV_PIX_FMT_YUV420P10LE:
        case AV_PIX_FMT_YUV420P10BE: return PixelFormat::YUV420P10;
        case AV_PIX_FMT_BGRA:     return PixelFormat::BGRA;
        default:                   return PixelFormat::Unknown;
    }
}

SubtitleFormat FFDemuxer::detect_subtitle_format(int codec_id) {
    switch (codec_id) {
        case AV_CODEC_ID_SUBRIP:
        case AV_CODEC_ID_SRT:
            return SubtitleFormat::SRT;
        case AV_CODEC_ID_ASS:
        case AV_CODEC_ID_SSA:
            return SubtitleFormat::ASS;
        case AV_CODEC_ID_HDMV_PGS_SUBTITLE:
            return SubtitleFormat::PGS;
        case AV_CODEC_ID_DVD_SUBTITLE:
            return SubtitleFormat::VobSub;
        default:
            return SubtitleFormat::Unknown;
    }
}

} // namespace py
