#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"

struct AVCodecContext;
struct AVFrame;

namespace py {

class AudioDecoder {
public:
    AudioDecoder();
    ~AudioDecoder();

    Error open(const TrackInfo& track);
    void close();
    void flush();

    Error send_packet(const Packet& pkt);
    Error receive_frame(AudioFrame& out);

    int sample_rate() const;
    int channels() const;

private:
    AVCodecContext* codec_ctx_ = nullptr;
    AVFrame* av_frame_ = nullptr;
};

} // namespace py
