#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"

namespace py {

class IVideoDecoder {
public:
    virtual ~IVideoDecoder() = default;

    virtual Error open(const TrackInfo& track) = 0;
    virtual void close() = 0;
    virtual void flush() = 0;

    // Send a compressed packet to the decoder.
    virtual Error send_packet(const Packet& pkt) = 0;

    // Receive a decoded frame. Returns OutputNotReady if no frame available yet.
    virtual Error receive_frame(VideoFrame& out) = 0;
};

} // namespace py
