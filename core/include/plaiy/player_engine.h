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
    void set_remote_source_kind(RemoteSourceKind kind);
    void set_remote_buffer_mode(RemoteBufferMode mode);
    void set_remote_buffer_profile(RemoteBufferProfile profile);

    // Audio filters
    // Note: Audio filters are created per decode loop. These methods set
    // desired values that will be applied when the decode thread starts/restarts.
    // EQ
    void set_eq_enabled(bool enabled);
    bool is_eq_enabled() const;
    void set_eq_band(int band, float gain_db);
    float eq_band(int band) const;
    void set_eq_preset(int preset);
    int eq_preset() const;
    // Compressor
    void set_compressor_enabled(bool enabled);
    bool is_compressor_enabled() const;
    void set_compressor_threshold(float db);
    void set_compressor_ratio(float ratio);
    void set_compressor_attack(float ms);
    void set_compressor_release(float ms);
    void set_compressor_makeup(float db);
    // Dialogue boost
    void set_dialogue_boost_enabled(bool enabled);
    bool is_dialogue_boost_enabled() const;
    void set_dialogue_boost_amount(float amount);
    float dialogue_boost_amount() const;

    // Deinterlace (CPU, SW decode path only)
    void set_deinterlace_enabled(bool enabled);
    bool is_deinterlace_enabled() const;
    void set_deinterlace_mode(int mode); // 0=yadif, 1=bwdif
    int deinterlace_mode() const;

    // Video filters (GPU — brightness/contrast/saturation/sharpness/deband/upscaling)
    void set_deband_enabled(bool enabled);
    bool is_deband_enabled() const;
    void set_lanczos_upscaling(bool enabled);
    bool lanczos_upscaling() const;
    void set_film_grain_enabled(bool enabled);
    bool film_grain_enabled() const;
    void set_brightness(float v);
    float brightness() const;
    void set_contrast(float v);
    float contrast() const;
    void set_saturation(float v);
    float saturation() const;
    void set_sharpness(float v);
    float sharpness() const;
    void reset_video_adjustments();

    PlaybackStats get_playback_stats() const;

    // Dolby Vision: set the AVSampleBufferDisplayLayer for DV output.
    // Must be called after open_file() and before play().
    void set_dv_display_layer(void* layer);
    bool is_dolby_vision() const;

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
