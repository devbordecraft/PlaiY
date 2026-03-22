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

    Error open_passthrough(int codec_id, int sample_rate, int channels) override;
    bool is_passthrough() const override;
    void set_bitstream_pull_callback(BitstreamPullCallback cb) override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
