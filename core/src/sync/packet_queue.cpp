#include "plaiy/packet_queue.h"

namespace py {

PacketQueue::PacketQueue(size_t max_size, int64_t max_bytes)
    : max_size_(max_size), max_bytes_(max_bytes) {}

bool PacketQueue::push(Packet packet) {
    std::unique_lock lock(mutex_);
    not_full_.wait(lock, [this] {
        return aborted_ || (queue_.size() < max_size_ &&
               (max_bytes_ <= 0 || total_bytes_ < max_bytes_));
    });
    if (aborted_) return false;

    total_bytes_ += static_cast<int64_t>(packet.data.size());
    queue_.push_back(std::move(packet));
    not_empty_.notify_one();
    return true;
}

bool PacketQueue::pop(Packet& out) {
    std::unique_lock lock(mutex_);
    not_empty_.wait(lock, [this] { return aborted_ || !queue_.empty(); });
    if (queue_.empty()) return false;

    out = std::move(queue_.front());
    total_bytes_ -= static_cast<int64_t>(out.data.size());
    queue_.pop_front();
    not_full_.notify_one();
    return true;
}

void PacketQueue::flush() {
    std::lock_guard lock(mutex_);
    total_bytes_ = 0;
    queue_.clear();
    not_full_.notify_all();
}

void PacketQueue::abort() {
    std::lock_guard lock(mutex_);
    aborted_ = true;
    not_empty_.notify_all();
    not_full_.notify_all();
}

void PacketQueue::reset() {
    std::lock_guard lock(mutex_);
    queue_.clear();
    total_bytes_ = 0;
    aborted_ = false;
}

size_t PacketQueue::size() const {
    std::lock_guard lock(mutex_);
    return queue_.size();
}

bool PacketQueue::empty() const {
    std::lock_guard lock(mutex_);
    return queue_.empty();
}

int64_t PacketQueue::total_bytes() const {
    std::lock_guard lock(mutex_);
    return total_bytes_;
}

} // namespace py
