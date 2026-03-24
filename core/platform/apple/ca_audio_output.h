#pragma once

#include "plaiy/audio_engine.h"

namespace py {

class CAAudioOutput : public IAudioOutput {
public:
    CAAudioOutput();
    ~CAAudioOutput() override;

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

    Error open_passthrough(int codec_id, int codec_profile, int sample_rate, int channels) override;
    bool is_passthrough() const override;
    void set_bitstream_pull_callback(BitstreamPullCallback cb) override;

    PassthroughCapability query_passthrough_support() const override;
    void set_device_change_callback(DeviceChangeCallback cb) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
