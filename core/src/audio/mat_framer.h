#pragma once

#include "plaiy/error.h"
#include <cstdint>
#include <memory>
#include <vector>

namespace py {

// Encapsulates raw TrueHD access units into MAT (Metadata-enhanced Audio
// Transmission) frames suitable for IEC 61937 transport over HDMI.
// Uses FFmpeg's spdif muxer internally.
class MATFramer {
public:
    MATFramer();
    ~MATFramer();

    Error open(int codec_id, int sample_rate, int channels);
    void close();

    // Feed a raw TrueHD packet and produce MAT-framed output.
    // Output may be empty if the muxer is buffering access units.
    Error frame_packet(const uint8_t* data, size_t size, int64_t pts,
                       std::vector<uint8_t>& out);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
