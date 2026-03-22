#pragma once

#include <atomic>
#include <cstring>
#include <vector>

namespace py {

// Lock-free single-producer, single-consumer ring buffer.
// Producer: audio decode thread. Consumer: CoreAudio real-time thread.
// Uses acquire/release atomics for index synchronization.
template<typename T>
class SPSCRingBuffer {
public:
    SPSCRingBuffer() = default;

    void resize(size_t capacity) {
        buffer_.resize(capacity);
        capacity_ = capacity;
        read_idx_.store(0, std::memory_order_relaxed);
        write_idx_.store(0, std::memory_order_relaxed);
    }

    // Producer: write up to count items. Returns number actually written.
    size_t write(const T* data, size_t count) {
        size_t w = write_idx_.load(std::memory_order_relaxed);
        size_t r = read_idx_.load(std::memory_order_acquire);
        size_t avail = capacity_ - (w - r);
        size_t to_write = count < avail ? count : avail;
        if (to_write == 0) return 0;

        size_t pos = w % capacity_;
        size_t first = capacity_ - pos;
        if (first > to_write) first = to_write;

        std::memcpy(&buffer_[pos], data, first * sizeof(T));
        if (to_write > first) {
            std::memcpy(&buffer_[0], data + first, (to_write - first) * sizeof(T));
        }

        write_idx_.store(w + to_write, std::memory_order_release);
        return to_write;
    }

    // Consumer: read up to count items. Returns number actually read.
    size_t read(T* data, size_t count) {
        size_t r = read_idx_.load(std::memory_order_relaxed);
        size_t w = write_idx_.load(std::memory_order_acquire);
        size_t avail = w - r;
        size_t to_read = count < avail ? count : avail;
        if (to_read == 0) return 0;

        size_t pos = r % capacity_;
        size_t first = capacity_ - pos;
        if (first > to_read) first = to_read;

        std::memcpy(data, &buffer_[pos], first * sizeof(T));
        if (to_read > first) {
            std::memcpy(data + first, &buffer_[0], (to_read - first) * sizeof(T));
        }

        read_idx_.store(r + to_read, std::memory_order_release);
        return to_read;
    }

    size_t available_read() const {
        size_t w = write_idx_.load(std::memory_order_acquire);
        size_t r = read_idx_.load(std::memory_order_relaxed);
        return w - r;
    }

    size_t available_write() const {
        size_t w = write_idx_.load(std::memory_order_relaxed);
        size_t r = read_idx_.load(std::memory_order_acquire);
        return capacity_ - (w - r);
    }

    size_t capacity() const { return capacity_; }

    // Reset indices. Only safe when neither thread is reading/writing.
    void reset() {
        read_idx_.store(0, std::memory_order_relaxed);
        write_idx_.store(0, std::memory_order_relaxed);
    }

    void release() {
        reset();
        buffer_.clear();
        buffer_.shrink_to_fit();
        capacity_ = 0;
    }

private:
    std::vector<T> buffer_;
    size_t capacity_ = 0;
    // Monotonically increasing indices. Use modulo for buffer position.
    // Keeping them monotonic avoids ABA issues and simplifies size computation.
    std::atomic<size_t> read_idx_{0};
    std::atomic<size_t> write_idx_{0};
};

} // namespace py
