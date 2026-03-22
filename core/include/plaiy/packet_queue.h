#pragma once

#include "plaiy/types.h"
#include <condition_variable>
#include <deque>
#include <mutex>

namespace py {

class PacketQueue {
public:
    explicit PacketQueue(size_t max_size = 256);
    ~PacketQueue() = default;

    // Push a packet. Blocks if queue is full, unless aborted.
    // Returns false if aborted.
    bool push(Packet packet);

    // Pop a packet. Blocks if queue is empty, unless aborted.
    // Returns false if aborted and queue is empty.
    bool pop(Packet& out);

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
    int64_t total_bytes_ = 0;
    bool aborted_ = false;
};

} // namespace py
