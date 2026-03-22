#pragma once

#include "plaiy/types.h"
#include <condition_variable>
#include <deque>
#include <mutex>

namespace py {

class FrameQueue {
public:
    explicit FrameQueue(size_t max_size = 4);
    ~FrameQueue() = default;

    // Push a decoded frame. Blocks if queue is full, unless aborted.
    bool push(VideoFrame frame);

    // Non-blocking push. Returns false immediately if full.
    bool try_push(VideoFrame frame);

    // Peek at the front frame without removing it.
    // Returns nullptr if empty or aborted.
    VideoFrame* peek();

    // Remove the front frame.
    void pop();

    // Pop and return the front frame. Blocks if empty.
    bool pop(VideoFrame& out);

    // Non-blocking pop. Returns false immediately if empty.
    bool try_pop(VideoFrame& out);

    void flush();
    void abort();
    void reset();

    size_t size() const;
    bool empty() const;

private:
    mutable std::mutex mutex_;
    std::condition_variable not_empty_;
    std::condition_variable not_full_;
    std::deque<VideoFrame> queue_;
    size_t max_size_;
    bool aborted_ = false;
};

} // namespace py
