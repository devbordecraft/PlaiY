#pragma once

#include "plaiy/types.h"
#include <chrono>
#include <condition_variable>
#include <deque>
#include <mutex>

namespace py {

class PacketQueue {
public:
    explicit PacketQueue(size_t max_size = 256, int64_t max_bytes = 0);
    ~PacketQueue() = default;

    // Push a packet. Blocks if queue is full, unless aborted.
    // Returns false if aborted.
    bool push(Packet packet);

    // Pop a packet. Blocks if queue is empty, unless aborted.
    // Returns false if aborted and queue is empty.
    bool pop(Packet& out);

    // Pop with timeout. Returns false if timed out, aborted, or empty.
    template<typename Rep, typename Period>
    bool try_pop_for(Packet& out, std::chrono::duration<Rep, Period> timeout) {
        std::unique_lock lock(mutex_);
        if (!not_empty_.wait_for(lock, timeout, [this] { return aborted_ || !queue_.empty(); })) {
            return false; // timed out
        }
        if (queue_.empty()) return false;

        out = std::move(queue_.front());
        total_bytes_ -= static_cast<int64_t>(out.data.size());
        queue_.pop_front();
        not_full_.notify_one();
        return true;
    }

    void flush();
    void abort();
    void reset();

    size_t size() const;
    bool empty() const;

    int64_t total_bytes() const;

private:
    mutable std::mutex mutex_;
    std::condition_variable not_empty_;
    std::condition_variable not_full_;
    std::deque<Packet> queue_;
    size_t max_size_;
    int64_t max_bytes_ = 0;   // 0 = unlimited
    int64_t total_bytes_ = 0;
    bool aborted_ = false;
};

} // namespace py
