#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <string>

struct ass_library;
struct ass_renderer;
struct ass_track;
typedef struct ass_library ASS_Library;
typedef struct ass_renderer ASS_Renderer;
typedef struct ass_track ASS_Track;

namespace py {

class AssRenderer {
public:
    AssRenderer();
    ~AssRenderer();

    Error init();

    // Load from an external .ass/.ssa file
    Error load_file(const std::string& path);

    // Load from embedded track data (codec extradata = ASS header)
    Error load_embedded(const uint8_t* header, size_t header_size);

    // Feed an embedded subtitle packet (ASS dialogue line)
    void feed_packet(const Packet& pkt);

    // Render the subtitle at the given timestamp.
    // Returns bitmap regions to composite.
    SubtitleFrame render(int64_t timestamp_us);

    void set_video_size(int width, int height);
    void flush();
    void close();

private:
    ASS_Library* library_ = nullptr;
    ASS_Renderer* renderer_ = nullptr;
    ASS_Track* track_ = nullptr;
    int video_width_ = 1920;
    int video_height_ = 1080;

    // Cache last render to avoid redundant bitmap conversion
    SubtitleFrame cached_frame_;
    bool cache_valid_ = false;
};

} // namespace py
