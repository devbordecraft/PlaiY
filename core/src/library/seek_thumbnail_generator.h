#pragma once

#include <string>
#include <vector>
#include <atomic>
#include <thread>
#include <mutex>
#include <list>
#include <unordered_map>
#include <cstdint>

#include "plaiy/types.h"

namespace py {

class SeekThumbnailGenerator {
public:
    enum class ThumbnailMode {
        LegacySwscale,
        CustomMetalP5,
    };

    SeekThumbnailGenerator();
    ~SeekThumbnailGenerator();

    // Start async thumbnail generation. Non-blocking.
    // interval_seconds: one thumbnail every N seconds.
    // cache_dir: directory to write thumb_NNNN.jpg files.
    void start(const std::string& video_path,
               const std::string& cache_dir,
               int interval_seconds,
               const TrackInfo* video_track = nullptr);

    // Cancel in-progress generation.
    void cancel();

    // Get a thumbnail for a timestamp. Returns true if available.
    // out_data points to BGRA pixels owned by this object (valid until next call).
    bool get_thumbnail(int64_t timestamp_us, int64_t duration_us,
                       const uint8_t** out_data, int* out_width, int* out_height);

    // Progress 0-100.
    int progress() const { return progress_.load(); }

    static ThumbnailMode select_mode(const TrackInfo& track);

private:
    struct DecodedThumbnail {
        int width = 0;
        int height = 0;
        std::vector<uint8_t> bgra;
    };

    struct DecodedThumbnailEntry {
        DecodedThumbnail thumbnail;
        std::list<int>::iterator lru_it;
    };

    void generate_loop(std::string video_path, std::string cache_dir,
                       int interval_seconds);
    bool try_get_cached_thumbnail(int index,
                                  const uint8_t** out_data,
                                  int* out_width,
                                  int* out_height);
    void store_decoded_thumbnail(int index, DecodedThumbnail thumbnail);
    bool generate_legacy_thumbnails(const std::string& video_path,
                                    const std::string& cache_dir,
                                    int interval_seconds);
    bool generate_custom_p5_thumbnails(const std::string& video_path,
                                       const std::string& cache_dir,
                                       int interval_seconds);

    std::atomic<bool> cancel_flag_{false};
    std::atomic<int> progress_{0};
    std::atomic<int> total_count_{0};
    std::atomic<int> generated_count_{0};
    int interval_seconds_ = 10;
    std::string cache_dir_;
    ThumbnailMode mode_{ThumbnailMode::LegacySwscale};

    std::thread worker_;
    std::mutex data_mutex_;
    int last_index_{-1};
    std::list<int> decoded_lru_;
    std::unordered_map<int, DecodedThumbnailEntry> decoded_cache_;

    static constexpr size_t DECODED_CACHE_CAPACITY = 8;
};

} // namespace py
