#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <memory>
#include <string>

namespace py {

class SubtitleManager {
public:
    SubtitleManager();
    ~SubtitleManager();

    // Load an external subtitle file (.srt, .ass)
    Error load_external(const std::string& path);

    // Set an embedded subtitle track (from demuxer)
    Error set_embedded_track(const TrackInfo& track);

    // Feed a demuxed subtitle packet (for embedded tracks)
    void feed_packet(const Packet& pkt);

    // Get the subtitle frame to display at the given timestamp.
    // Returns an empty frame if no subtitle is active.
    SubtitleFrame get_frame_at(int64_t timestamp_us);

    // Set the video dimensions (needed for ASS/PGS positioning)
    void set_video_size(int width, int height);

    void set_ass_font_scale(double scale);

    void flush();
    void close();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
