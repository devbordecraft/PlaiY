#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"

#include <memory>
#include <vector>

namespace py {

class SeekThumbnailRenderer {
public:
    SeekThumbnailRenderer();
    ~SeekThumbnailRenderer();

    bool is_available() const;
    Error render_frame(const VideoFrame& frame, int dst_width, int dst_height,
                       std::vector<uint8_t>& out_bgra);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
