#pragma once

#include <atomic>
#include <cstdint>

namespace py {

class PlaybackGeneration {
public:
    uint64_t capture_for_read() const {
        return current_.load(std::memory_order_acquire);
    }

    uint64_t current() const {
        return current_.load(std::memory_order_acquire);
    }

    uint64_t advance() {
        return current_.fetch_add(1, std::memory_order_acq_rel) + 1;
    }

    bool matches(uint64_t generation) const {
        return generation == current();
    }

    void reset() {
        current_.store(1, std::memory_order_release);
    }

private:
    std::atomic<uint64_t> current_{1};
};

} // namespace py
