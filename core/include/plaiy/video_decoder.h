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

    // Wait for in-flight decodes and allow all buffered frames to be
    // retrieved via receive_frame (e.g. lower the reorder depth to 0).
    // Called at end-of-stream before the final drain.  Default: no-op.
    virtual void drain() {}

    // When true, receive_frame() returns frames with only pts_us populated,
    // skipping expensive fill_frame work (metadata extraction, CVPixelBuffer,
    // sws_scale). Used during seek skip-to-target. Default: no-op.
    virtual void set_skip_mode(bool /*skip*/) {}

    // Send a compressed packet to the decoder.
    virtual Error send_packet(const Packet& pkt) = 0;

    // Receive a decoded frame. Returns OutputNotReady if no frame available yet.
    virtual Error receive_frame(VideoFrame& out) = 0;
};

} // namespace py
