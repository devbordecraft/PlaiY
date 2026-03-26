#pragma once

#include "plaiy/video_decoder.h"

struct AVCodecContext;
struct AVFrame;
struct SwsContext;

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
    void set_skip_mode(bool skip) override;
    void set_pts_only_output(bool enabled);

private:
    bool fill_frame(const AVFrame* av_frame, VideoFrame& out);

    AVCodecContext* codec_ctx_ = nullptr;
    AVFrame* av_frame_ = nullptr;
    AVPacket* reuse_pkt_ = nullptr;
    TrackInfo track_info_;
    bool skip_mode_ = false;
    bool pts_only_output_ = false;
    int saved_skip_frame_ = 0;  // AVDISCARD_DEFAULT

    // Cached swscale context — recreated only when format/resolution changes
    SwsContext* sws_ctx_ = nullptr;
    int sws_src_w_ = 0;
    int sws_src_h_ = 0;
    int sws_src_fmt_ = -1;
    int sws_dst_fmt_ = -1;

#ifdef __APPLE__
    // CVPixelBufferPool — reuses IOSurface-backed buffers across frames
    void* cv_pool_ = nullptr;  // CVPixelBufferPoolRef
    int pool_width_ = 0;
    int pool_height_ = 0;
    uint32_t pool_format_ = 0;
#endif
};

} // namespace py
