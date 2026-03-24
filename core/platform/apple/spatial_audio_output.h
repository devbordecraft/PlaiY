#pragma once

#include "plaiy/audio_engine.h"

namespace py {

class SpatialAudioOutput : public IAudioOutput {
public:
    SpatialAudioOutput();
    ~SpatialAudioOutput() override;

    Error open(int sample_rate, int channels) override;
    void close() override;
    void start() override;
    void stop() override;
    void reset_position() override;

    void set_pull_callback(PullCallback cb) override;
    void set_pts_callback(PtsCallback cb) override;

    int sample_rate() const override;
    int channels() const override;
    int max_device_channels() const override;

    void set_muted(bool muted) override;
    bool is_muted() const override;

    void set_volume(float v) override;
    float volume() const override;

    void set_device_change_callback(DeviceChangeCallback cb) override;

    // Spatial-specific overrides
    void set_head_tracking_enabled(bool enabled) override;
    bool is_head_tracking_enabled() const override;
    bool is_spatial() const override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
