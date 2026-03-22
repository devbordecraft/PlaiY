#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>

namespace py {

// Audio-master presentation clock for A-V synchronization.
// The audio output callback sets the current audio PTS;
// the video renderer reads it to decide when to present frames.
class Clock {
public:
    Clock();

    // Set by the audio render callback. Updates PTS but does NOT
    // unfreeze a frozen clock — call unfreeze() explicitly.
    void set_audio_pts(int64_t pts_us);
    int64_t audio_pts() const;

    // Set PTS and freeze the clock at that position.
    // now_us() returns exactly audio_pts_us_ (no extrapolation) while frozen.
    void seek_to(int64_t pts_us);

    // Unfreeze the clock (call when video presents its first post-seek frame).
    void unfreeze();

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
    bool frozen_ = false;
    double rate_ = 1.0;
};

} // namespace py
