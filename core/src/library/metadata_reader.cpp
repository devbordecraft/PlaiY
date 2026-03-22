#include "metadata_reader.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}

#include <sys/stat.h>

static constexpr const char* TAG = "MetadataReader";

namespace py {

bool MetadataReader::read(const std::string& path, MediaItem& out) {
    AVFormatContext* fmt = nullptr;
    int ret = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
    if (ret < 0) return false;

    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        avformat_close_input(&fmt);
        return false;
    }

    out.file_path = path;
    out.container_format = fmt->iformat ? fmt->iformat->name : "unknown";
    out.duration_us = (fmt->duration != AV_NOPTS_VALUE)
                          ? av_rescale_q(fmt->duration, {1, AV_TIME_BASE}, {1, 1000000})
                          : 0;

    // Get title from metadata
    const AVDictionaryEntry* title = av_dict_get(fmt->metadata, "title", nullptr, 0);
    if (title) {
        out.title = title->value;
    } else {
        // Use filename as title
        auto slash = path.rfind('/');
        auto dot = path.rfind('.');
        if (slash != std::string::npos && dot != std::string::npos && dot > slash) {
            out.title = path.substr(slash + 1, dot - slash - 1);
        } else if (slash != std::string::npos) {
            out.title = path.substr(slash + 1);
        } else {
            out.title = path;
        }
    }

    // File size
    struct stat st;
    if (stat(path.c_str(), &st) == 0) {
        out.file_size = st.st_size;
    }

    // Scan tracks
    out.audio_track_count = 0;
    out.subtitle_track_count = 0;

    for (unsigned i = 0; i < fmt->nb_streams; i++) {
        AVStream* stream = fmt->streams[i];
        AVCodecParameters* par = stream->codecpar;
        const AVCodecDescriptor* desc = avcodec_descriptor_get(par->codec_id);

        switch (par->codec_type) {
            case AVMEDIA_TYPE_VIDEO:
                if (out.video_width == 0) { // first video track
                    out.video_width = par->width;
                    out.video_height = par->height;
                    out.video_codec = desc ? desc->name : "unknown";

                    if (par->color_trc == AVCOL_TRC_SMPTE2084) {
                        out.hdr_type = HDRType::HDR10;
                    } else if (par->color_trc == AVCOL_TRC_ARIB_STD_B67) {
                        out.hdr_type = HDRType::HLG;
                    }

                    // Check for Dolby Vision (FFmpeg 7+ API)
                    {
                        const AVPacketSideData* sd = av_packet_side_data_get(
                            par->coded_side_data, par->nb_coded_side_data,
                            AV_PKT_DATA_DOVI_CONF);
                        if (sd) {
                            out.hdr_type = HDRType::DolbyVision;
                        }
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

    avformat_close_input(&fmt);
    return true;
}

} // namespace py
