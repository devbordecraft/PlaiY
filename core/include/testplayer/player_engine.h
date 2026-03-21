#pragma once

#include "testplayer/error.h"
#include "testplayer/types.h"
#include <functional>
#include <memory>
#include <string>

namespace tp {

class PlayerEngine {
public:
    PlayerEngine();
    ~PlayerEngine();

    Error open_file(const std::string& path);
    void play();
    void pause();
    void seek(int64_t timestamp_us);
    void stop();

    PlaybackState state() const;
    int64_t current_position_us() const;
    int64_t duration_us() const;
    MediaInfo media_info() const;

    void select_audio_track(int stream_index);
    void select_subtitle_track(int stream_index);

    int audio_track_count() const;
    int subtitle_track_count() const;

    // Video frame acquisition for the Metal renderer
    // Returns nullptr if no frame is ready
    VideoFrame* acquire_video_frame(int64_t target_pts_us);
    void release_video_frame(VideoFrame* frame);

    // Get current subtitle
    SubtitleFrame get_subtitle_frame(int64_t timestamp_us);

    // Callbacks
    using StateCallback = std::function<void(PlaybackState)>;
    using ErrorCallback = std::function<void(Error)>;
    void set_state_callback(StateCallback cb);
    void set_error_callback(ErrorCallback cb);

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace tp
