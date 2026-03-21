#pragma once

#include "testplayer/demuxer.h"

struct AVFormatContext;

namespace tp {

class FFDemuxer : public IDemuxer {
public:
    FFDemuxer();
    ~FFDemuxer() override;

    Error open(const std::string& path) override;
    void close() override;
    MediaInfo media_info() const override;
    Error read_packet(Packet& out) override;
    Error seek(int64_t timestamp_us) override;

private:
    void populate_media_info();
    static PixelFormat convert_pixel_format(int ff_format);
    static SubtitleFormat detect_subtitle_format(int codec_id);

    AVFormatContext* fmt_ctx_ = nullptr;
    MediaInfo info_;
};

} // namespace tp
