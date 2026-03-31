#include "metadata_reader.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include <algorithm>
#include <sys/stat.h>

namespace py {

namespace {

std::string fallback_title_for_path(const std::string& path) {
    auto slash = path.rfind('/');
    auto dot = path.rfind('.');
    if (slash != std::string::npos && dot != std::string::npos && dot > slash) {
        return path.substr(slash + 1, dot - slash - 1);
    }
    if (slash != std::string::npos) {
        return path.substr(slash + 1);
    }
    return path;
}

void populate_basic_metadata(const std::string& path, AVFormatContext* fmt, MediaItem& out) {
    out = {};
    out.file_path = path;
    out.container_format = fmt->iformat ? fmt->iformat->name : "unknown";
    out.duration_us = (fmt->duration != AV_NOPTS_VALUE)
                          ? av_rescale_q(fmt->duration, {1, AV_TIME_BASE}, {1, 1000000})
                          : 0;

    const AVDictionaryEntry* title = av_dict_get(fmt->metadata, "title", nullptr, 0);
    out.title = title ? title->value : fallback_title_for_path(path);

    struct stat st;
    if (stat(path.c_str(), &st) == 0) {
        out.file_size = st.st_size;
    }
}

void populate_stream_metadata(AVFormatContext* fmt, MediaItem& out) {
    out.video_width = 0;
    out.video_height = 0;
    out.video_codec.clear();
    out.audio_codec.clear();
    out.audio_channels = 0;
    out.audio_track_count = 0;
    out.subtitle_track_count = 0;
    out.hdr_type = HDRType::SDR;

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream* stream = fmt->streams[i];
        AVCodecParameters* par = stream->codecpar;
        if (!par) continue;

        const AVCodecDescriptor* desc = avcodec_descriptor_get(par->codec_id);

        switch (par->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
                if (out.video_width == 0) {
                    out.video_width = par->width;
                    out.video_height = par->height;
                    out.video_codec = desc ? desc->name : "unknown";

                    if (par->color_trc == AVCOL_TRC_SMPTE2084) {
                        out.hdr_type = HDRType::HDR10;
                    } else if (par->color_trc == AVCOL_TRC_ARIB_STD_B67) {
                        out.hdr_type = HDRType::HLG;
                    }

                    const AVPacketSideData* sd = av_packet_side_data_get(
                        par->coded_side_data, par->nb_coded_side_data,
                        AV_PKT_DATA_DOVI_CONF);
                    if (sd) {
                        out.hdr_type = HDRType::DolbyVision;
                    }
                }
                break;

            case AVMEDIA_TYPE_AUDIO:
                out.audio_track_count++;
                if (out.audio_codec.empty()) {
                    out.audio_codec = desc ? desc->name : "unknown";
                    out.audio_channels = par->ch_layout.nb_channels;
                }
                break;

            case AVMEDIA_TYPE_SUBTITLE:
                out.subtitle_track_count++;
                break;

            default:
                break;
        }
    }
}

} // namespace

bool MetadataReader::read(const std::string& path, MediaItem& out, ProbeMode mode) {
    AVFormatContext* fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
    if (ret < 0) return false;

    if (mode == ProbeMode::Full) {
        ret = avformat_find_stream_info(fmt, nullptr);
        if (ret < 0) {
            avformat_close_input(&fmt);
            return false;
        }
    }

    populate_basic_metadata(path, fmt, out);
    populate_stream_metadata(fmt, out);

    avformat_close_input(&fmt);
    return true;
}

bool MetadataReader::needs_full_probe(const MediaItem& item) {
    if (item.duration_us <= 0) return true;
    if (item.video_width > 0 && item.video_codec.empty()) return true;
    if (item.audio_track_count > 0 && item.audio_codec.empty()) return true;

    bool missing_stream_summary =
        item.video_width == 0 &&
        item.video_height == 0 &&
        item.audio_track_count == 0 &&
        item.subtitle_track_count == 0 &&
        item.audio_codec.empty() &&
        item.video_codec.empty();

    return missing_stream_summary;
}

} // namespace py
