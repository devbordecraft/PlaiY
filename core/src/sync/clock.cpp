#include "plaiy/clock.h"

namespace py {

Clock::Clock()
    : last_update_(std::chrono::steady_clock::now()) {}

void Clock::set_audio_pts(int64_t pts_us) {
    std::lock_guard lock(mutex_);
    audio_pts_us_ = pts_us;
    last_update_ = std::chrono::steady_clock::now();
}

int64_t Clock::audio_pts() const {
    std::lock_guard lock(mutex_);
    return audio_pts_us_;
}

int64_t Clock::now_us() const {
    std::lock_guard lock(mutex_);
    if (paused_) return audio_pts_us_;

    auto elapsed = std::chrono::steady_clock::now() - last_update_;
    auto elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count();
    return audio_pts_us_ + static_cast<int64_t>(elapsed_us * rate_);
}

void Clock::set_paused(bool paused) {
    std::lock_guard lock(mutex_);
    if (paused_ && !paused) {
        // Resuming: reset the time reference
        last_update_ = std::chrono::steady_clock::now();
    }
    paused_ = paused;
}

bool Clock::paused() const {
    std::lock_guard lock(mutex_);
    return paused_;
}

void Clock::set_rate(double rate) {
    std::lock_guard lock(mutex_);
    // Snap current time before changing rate
    auto now = std::chrono::steady_clock::now();
    auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(now - last_update_).count();
    audio_pts_us_ += static_cast<int64_t>(elapsed * rate_);
    last_update_ = now;
    rate_ = rate;
}

double Clock::rate() const {
    std::lock_guard lock(mutex_);
    return rate_;
}

void Clock::reset() {
    std::lock_guard lock(mutex_);
    audio_pts_us_ = 0;
    last_update_ = std::chrono::steady_clock::now();
    paused_ = true;
    rate_ = 1.0;
}

} // namespace py
