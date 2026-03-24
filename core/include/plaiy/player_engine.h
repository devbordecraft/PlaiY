#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <functional>
#include <memory>
#include <string>

namespace py {

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
    const MediaInfo& media_info() const;

    void select_audio_track(int stream_index);
    void select_subtitle_track(int stream_index);

    int audio_track_count() const;
    int subtitle_track_count() const;
    int active_audio_stream() const;
    int active_subtitle_stream() const;

    void set_audio_passthrough(bool enabled);
    bool is_passthrough_active() const;

    // Probe which passthrough formats the current output device supports.
    struct PassthroughCapability {
        bool ac3 = false;
        bool eac3 = false;
        bool dts = false;
        bool dts_hd_ma = false;
        bool truehd = false;
    };
    PassthroughCapability query_passthrough_support() const;

    using DeviceChangeCallback = std::function<void()>;
    void set_device_change_callback(DeviceChangeCallback cb);

    void set_muted(bool muted);
    bool is_muted() const;

    void set_volume(float v);
    float volume() const;

    void set_playback_speed(double speed);
    double playback_speed() const;

    // Spatial audio
    void set_spatial_audio_mode(int mode);  // 0=Auto, 1=Off, 2=Force
    int spatial_audio_mode() const;
    bool is_spatial_active() const;
    void set_head_tracking_enabled(bool enabled);
    bool is_head_tracking_enabled() const;

    void set_hw_decode_preference(HWDecodePreference pref);
    void set_subtitle_font_scale(double scale);

    PlaybackStats get_playback_stats() const;

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
    void setup_audio_output(const TrackInfo& track);
    void restart_audio_pipeline();

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
