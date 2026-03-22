#pragma once

#include "plaiy/video_decoder.h"
#include <deque>
#include <mutex>

namespace py {

class VTVideoDecoder : public IVideoDecoder {
public:
    VTVideoDecoder();
    ~VTVideoDecoder() override;

    Error open(const TrackInfo& track) override;
    void close() override;
    void flush() override;
    void drain() override;
    Error send_packet(const Packet& pkt) override;
    Error receive_frame(VideoFrame& out) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
