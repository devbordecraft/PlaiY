#include "plaiy/clock.h"
#include <thread>

namespace py {

Clock::Clock() {
    state_.last_update = std::chrono::steady_clock::now();
}

// ---------------------------------------------------------------------------
// SeqLock helpers
// ---------------------------------------------------------------------------

void Clock::begin_write() {
    seq_.fetch_add(1, std::memory_order_release); // odd = writing
}

void Clock::end_write() {
    seq_.fetch_add(1, std::memory_order_release); // even = done
}

Clock::State Clock::read_state() const {
    State s;
    uint32_t seq0, seq1;
    int retries = 0;
    do {
        seq0 = seq_.load(std::memory_order_acquire);
        s.audio_pts_us = state_.audio_pts_us;
        s.last_update  = state_.last_update;
        s.paused       = state_.paused;
        s.frozen       = state_.frozen;
        s.rate         = state_.rate;
        std::atomic_thread_fence(std::memory_order_acquire);
        seq1 = seq_.load(std::memory_order_relaxed);
        if ((seq0 != seq1 || (seq0 & 1)) && ++retries > 2) {
            std::this_thread::yield();
        }
    } while (seq0 != seq1 || (seq0 & 1));
    return s;
}

int64_t Clock::compute_now(const State& s) {
    if (s.paused || s.frozen) return s.audio_pts_us;
    auto elapsed = std::chrono::steady_clock::now() - s.last_update;
    auto elapsed_us = std::chrono::duration_cast<std::chrono::microseconds>(elapsed).count();
    return s.audio_pts_us + static_cast<int64_t>(static_cast<double>(elapsed_us) * s.rate);
}

// ---------------------------------------------------------------------------
// Lock-free readers
// ---------------------------------------------------------------------------

int64_t Clock::now_us() const {
    return compute_now(read_state());
}

int64_t Clock::audio_pts() const {
    return read_state().audio_pts_us;
}

bool Clock::paused() const {
    return read_state().paused;
}

double Clock::rate() const {
    return read_state().rate;
}

// ---------------------------------------------------------------------------
// Writers (serialized via write_mutex_)
// ---------------------------------------------------------------------------

void Clock::set_audio_pts(int64_t pts_us) {
    std::lock_guard lock(write_mutex_);
    begin_write();
    state_.audio_pts_us = pts_us;
    state_.last_update = std::chrono::steady_clock::now();
    end_write();
}

void Clock::seek_to(int64_t pts_us) {
    std::lock_guard lock(write_mutex_);
    begin_write();
    state_.audio_pts_us = pts_us;
    state_.last_update = std::chrono::steady_clock::now();
    state_.frozen = true;
    end_write();
}

void Clock::unfreeze() {
    std::lock_guard lock(write_mutex_);
    if (state_.frozen) {
        begin_write();
        state_.last_update = std::chrono::steady_clock::now();
        state_.frozen = false;
        end_write();
    }
}

void Clock::set_paused(bool paused) {
    std::lock_guard lock(write_mutex_);
    begin_write();
    if (state_.paused && !paused) {
        // Resuming: reset the time reference
        state_.last_update = std::chrono::steady_clock::now();
    }
    state_.paused = paused;
    end_write();
}

void Clock::set_rate(double rate) {
    std::lock_guard lock(write_mutex_);
    begin_write();
    auto now = std::chrono::steady_clock::now();
    if (!state_.paused && !state_.frozen) {
        auto elapsed = std::chrono::duration_cast<std::chrono::microseconds>(now - state_.last_update).count();
        state_.audio_pts_us += static_cast<int64_t>(static_cast<double>(elapsed) * state_.rate);
    }
    state_.last_update = now;
    state_.rate = rate;
    end_write();
}

void Clock::reset() {
    std::lock_guard lock(write_mutex_);
    begin_write();
    state_.audio_pts_us = 0;
    state_.last_update = std::chrono::steady_clock::now();
    state_.paused = true;
    state_.frozen = false;
    state_.rate = 1.0;
    end_write();
}

} // namespace py
