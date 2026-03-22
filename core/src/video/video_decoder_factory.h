#pragma once

#include "plaiy/video_decoder.h"
#include <memory>

namespace py {

class VideoDecoderFactory {
public:
    // Creates the best available decoder for the given track.
    // On Apple: tries VideoToolbox first, falls back to FFmpeg.
    // On other platforms: uses FFmpeg.
    static std::unique_ptr<IVideoDecoder> create(const TrackInfo& track);
};

} // namespace py
