#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <functional>

namespace py {

class IAudioOutput {
public:
    virtual ~IAudioOutput() = default;

    // Configure the output for the given sample rate and channel count
    virtual Error open(int sample_rate, int channels) = 0;
    virtual void close() = 0;

    virtual void start() = 0;
    virtual void stop() = 0;

    // Set the callback that the audio output calls to pull PCM samples.
    // The callback fills the buffer and returns the number of frames written.
    // buffer: interleaved float32, frames * channels floats
    using PullCallback = std::function<int(float* buffer, int frames, int channels)>;
    virtual void set_pull_callback(PullCallback cb) = 0;

    // Callback to report the current audio PTS for A-V sync
    using PtsCallback = std::function<void(int64_t pts_us)>;
    virtual void set_pts_callback(PtsCallback cb) = 0;

    virtual int sample_rate() const = 0;
    virtual int channels() const = 0;
};

} // namespace py
