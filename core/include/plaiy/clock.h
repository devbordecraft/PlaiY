#pragma once

#include <atomic>
#include <chrono>
#include <cstdint>
#include <mutex>

namespace py {

// Audio-master presentation clock for A-V synchronization.
// The audio output callback sets the current audio PTS;
// the video renderer reads it to decide when to present frames.
//
// Uses a SeqLock for lock-free reads: now_us(), paused(), rate(),
// and audio_pts() never block. Writers serialize via write_mutex_.
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
    // time elapsed since the last audio PTS update.
    // Lock-free: never blocks, never contends with writers.
    int64_t now_us() const;

    void set_paused(bool paused);
    bool paused() const;

    void set_rate(double rate);
    double rate() const;

    void reset();

private:
    // Snapshot of clock state — read/written as a unit via SeqLock.
    struct State {
        int64_t audio_pts_us = 0;
        std::chrono::steady_clock::time_point last_update;
        bool paused = true;
        bool frozen = false;
        double rate = 1.0;
    };

    // SeqLock: odd count = write in progress, even = consistent.
    // Readers spin-read until they see two matching even values.
    mutable std::atomic<uint32_t> seq_{0};
    State state_;

    // Serializes writers against each other (audio callback + main thread).
    // Readers never acquire this.
    std::mutex write_mutex_;

    // Read a consistent snapshot of state_ (lock-free, may retry on writer overlap).
    State read_state() const;

    // Compute now_us from a consistent state snapshot.
    static int64_t compute_now(const State& s);

    // Begin/end a write — bumps seq_ odd then even.
    void begin_write();
    void end_write();
};

} // namespace py
