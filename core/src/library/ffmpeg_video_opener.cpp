#include "ffmpeg_video_opener.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}

static constexpr const char* TAG = "FFmpegOpen";

namespace py {

bool FFmpegVideoOpener::open(const std::string& path, int thread_count) {
    int ret = avformat_open_input(&fmt, path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        PY_LOG_ERROR(TAG, "failed to open: %s", path.c_str());
        return false;
    }

    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        avformat_close_input(&fmt);
        return false;
    }

    stream_index = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (stream_index < 0) {
        avformat_close_input(&fmt);
        return false;
    }

    AVCodecParameters* par = fmt->streams[stream_index]->codecpar;

    const AVCodec* codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        avformat_close_input(&fmt);
        stream_index = -1;
        return false;
    }

    dec = avcodec_alloc_context3(codec);
    if (!dec) {
        avformat_close_input(&fmt);
        stream_index = -1;
        return false;
    }

    avcodec_parameters_to_context(dec, par);
    dec->thread_count = thread_count;

    ret = avcodec_open2(dec, codec, nullptr);
    if (ret < 0) {
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        stream_index = -1;
        return false;
    }

    return true;
}

void FFmpegVideoOpener::close() {
    if (dec) {
        avcodec_free_context(&dec);
    }
    if (fmt) {
        avformat_close_input(&fmt);
    }
    stream_index = -1;
}

} // namespace py
