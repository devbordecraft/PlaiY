#include "plaiy/frame_queue.h"

namespace py {

FrameQueue::FrameQueue(size_t max_size) : max_size_(max_size) {}

bool FrameQueue::push(VideoFrame frame) {
    std::unique_lock lock(mutex_);
    not_full_.wait(lock, [this] { return aborted_ || queue_.size() < max_size_; });
    if (aborted_) return false;

    queue_.push_back(std::move(frame));
    not_empty_.notify_one();
    return true;
}

bool FrameQueue::try_push(VideoFrame frame) {
    std::lock_guard lock(mutex_);
    if (aborted_ || queue_.size() >= max_size_) return false;

    queue_.push_back(std::move(frame));
    not_empty_.notify_one();
    return true;
}

VideoFrame* FrameQueue::peek() {
    std::lock_guard lock(mutex_);
    if (queue_.empty()) return nullptr;
    return &queue_.front();
}

FrameQueue::FrameFields FrameQueue::peek_fields() const {
    std::lock_guard lock(mutex_);
    if (queue_.empty()) return {};
    return {queue_.front().pts_us, queue_.front().duration_us, true};
}

void FrameQueue::pop() {
    std::lock_guard lock(mutex_);
    if (!queue_.empty()) {
        queue_.pop_front();
        not_full_.notify_one();
    }
}

bool FrameQueue::pop(VideoFrame& out) {
    std::unique_lock lock(mutex_);
    not_empty_.wait(lock, [this] { return aborted_ || !queue_.empty(); });
    if (queue_.empty()) return false;

    out = std::move(queue_.front());
    queue_.pop_front();
    not_full_.notify_one();
    return true;
}

bool FrameQueue::try_pop(VideoFrame& out) {
    std::lock_guard lock(mutex_);
    if (queue_.empty()) return false;

    out = std::move(queue_.front());
    queue_.pop_front();
    not_full_.notify_one();
    return true;
}

void FrameQueue::flush() {
    std::lock_guard lock(mutex_);
    queue_.clear();
    not_full_.notify_all();
}

void FrameQueue::abort() {
    std::lock_guard lock(mutex_);
    aborted_ = true;
    not_empty_.notify_all();
    not_full_.notify_all();
}

void FrameQueue::reset() {
    std::lock_guard lock(mutex_);
    queue_.clear();
    aborted_ = false;
}

size_t FrameQueue::size() const {
    std::lock_guard lock(mutex_);
    return queue_.size();
}

bool FrameQueue::empty() const {
    std::lock_guard lock(mutex_);
    return queue_.empty();
}

} // namespace py
