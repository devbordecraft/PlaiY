#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>

namespace tp {

// Audio-master presentation clock for A-V synchronization.
// The audio output callback sets the current audio PTS;
// the video renderer reads it to decide when to present frames.
class Clock {
public:
    Clock();

    // Set by the audio render callback
    void set_audio_pts(int64_t pts_us);
    int64_t audio_pts() const;

    // Get the estimated current playback time, accounting for
    // time elapsed since the last audio PTS update
    int64_t now_us() const;

    void set_paused(bool paused);
    bool paused() const;

    void set_rate(double rate);
    double rate() const;

    void reset();

private:
    mutable std::mutex mutex_;
    int64_t audio_pts_us_ = 0;
    std::chrono::steady_clock::time_point last_update_;
    bool paused_ = true;
    double rate_ = 1.0;
};

} // namespace tp
