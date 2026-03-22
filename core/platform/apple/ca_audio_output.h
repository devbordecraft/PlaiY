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
    void set_pull_callback(PullCallback cb) override;
    void set_pts_callback(PtsCallback cb) override;
    int sample_rate() const override;
    int channels() const override;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
