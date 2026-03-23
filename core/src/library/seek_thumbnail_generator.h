#pragma once

#include <string>
#include <vector>
#include <atomic>
#include <thread>
#include <mutex>
#include <cstdint>

namespace py {

class SeekThumbnailGenerator {
public:
    SeekThumbnailGenerator();
    ~SeekThumbnailGenerator();

    // Start async thumbnail generation. Non-blocking.
    // interval_seconds: one thumbnail every N seconds.
    // cache_dir: directory to write thumb_NNNN.jpg files.
    void start(const std::string& video_path,
               const std::string& cache_dir,
               int interval_seconds);

    // Cancel in-progress generation.
    void cancel();

    // Get a thumbnail for a timestamp. Returns true if available.
    // out_data points to BGRA pixels owned by this object (valid until next call).
    bool get_thumbnail(int64_t timestamp_us, int64_t duration_us,
                       const uint8_t** out_data, int* out_width, int* out_height);

    // Progress 0-100.
    int progress() const { return progress_.load(); }

private:
    void generate_loop(std::string video_path, std::string cache_dir,
                       int interval_seconds);

    std::atomic<bool> cancel_flag_{false};
    std::atomic<int> progress_{0};
    std::atomic<int> total_count_{0};
    std::atomic<int> generated_count_{0};
    int interval_seconds_ = 10;
    int thumb_width_ = 0;
    int thumb_height_ = 0;
    std::string cache_dir_;

    std::thread worker_;
    std::mutex data_mutex_;
    std::vector<uint8_t> last_bgra_data_;
    int last_index_{-1};
};

} // namespace py
