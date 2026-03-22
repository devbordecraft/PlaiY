#pragma once

#include "plaiy/video_decoder.h"

struct AVCodecContext;
struct AVFrame;

namespace py {

class FFVideoDecoder : public IVideoDecoder {
public:
    FFVideoDecoder();
    ~FFVideoDecoder() override;

    Error open(const TrackInfo& track) override;
    void close() override;
    void flush() override;
    Error send_packet(const Packet& pkt) override;
    Error receive_frame(VideoFrame& out) override;

private:
    void fill_frame(const AVFrame* av_frame, VideoFrame& out);

    AVCodecContext* codec_ctx_ = nullptr;
    AVFrame* av_frame_ = nullptr;
    AVPacket* reuse_pkt_ = nullptr;
    TrackInfo track_info_;
};

} // namespace py
