#pragma once

#include <string>

namespace py {

class ThumbnailGenerator {
public:
    // Generate a JPEG thumbnail from a video file.
    // Seeks to ~10% of duration, decodes one keyframe, scales to fit
    // within max_width x max_height (preserving aspect ratio), and writes JPEG.
    // Returns true on success.
    static bool generate(const std::string& video_path,
                         const std::string& output_path,
                         int max_width, int max_height);
};

} // namespace py
