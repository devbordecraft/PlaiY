#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct AVPacket;
struct AVFrame;

namespace py {

enum class PlaybackState {
    Idle,
    Opening,
    Ready,
    Playing,
    Paused,
    Stopped,
};

enum class MediaType {
    Unknown,
    Video,
    Audio,
    Subtitle,
};

enum class HDRType {
    SDR = 0,
    HDR10,
    HDR10Plus,
    HLG,
    DolbyVision,
};

enum class SubtitleFormat {
    Unknown,
    SRT,
    ASS,
    PGS,
    VobSub,
};

enum class PixelFormat {
    Unknown,
    NV12,      // 8-bit 4:2:0 biplanar
    P010,      // 10-bit 4:2:0 biplanar
    YUV420P,   // 8-bit 4:2:0 planar
    YUV420P10, // 10-bit 4:2:0 planar
    BGRA,
};

struct HDRMetadata {
    HDRType type = HDRType::SDR;

    // Mastering display color primaries (CIE 1931 xy, scaled by 50000)
    uint16_t display_primaries_x[3] = {};
    uint16_t display_primaries_y[3] = {};
    uint16_t white_point_x = 0;
    uint16_t white_point_y = 0;

    // Mastering display luminance (in 0.0001 cd/m2 units)
    uint32_t max_luminance = 0;
    uint32_t min_luminance = 0;

    // Content light level
    uint16_t max_content_light_level = 0;
    uint16_t max_frame_average_light_level = 0;
};

struct TrackInfo {
    int stream_index = -1;
    MediaType type = MediaType::Unknown;
    std::string codec_name;
    int codec_id = 0;
    std::string language;
    std::string title;
    bool is_default = false;

    // Video-specific
    int width = 0;
    int height = 0;
    double frame_rate = 0.0;
    PixelFormat pixel_format = PixelFormat::Unknown;
    HDRMetadata hdr_metadata;
    int color_space = 0;
    int color_primaries = 0;
    int color_trc = 0;

    // Audio-specific
    int sample_rate = 0;
    int channels = 0;
    uint64_t channel_layout = 0;
    int bits_per_sample = 0;

    // Subtitle-specific
    SubtitleFormat subtitle_format = SubtitleFormat::Unknown;

    // Codec extradata (needed for decoder init)
    std::vector<uint8_t> extradata;
};

struct MediaInfo {
    std::string file_path;
    std::string container_format;
    int64_t duration_us = 0;
    int64_t bit_rate = 0;

    std::vector<TrackInfo> tracks;

    int best_video_index = -1;
    int best_audio_index = -1;
    int best_subtitle_index = -1;
};

// Wraps a demuxed compressed packet
struct Packet {
    int stream_index = -1;
    int64_t pts = 0;       // in stream time_base units
    int64_t dts = 0;
    int64_t duration = 0;
    std::vector<uint8_t> data;
    bool is_keyframe = false;
    bool is_flush = false;  // sentinel to signal decoder flush

    // Time base numerator/denominator for this packet's stream
    int time_base_num = 1;
    int time_base_den = 90000;

    // Convert PTS to microseconds
    int64_t pts_us() const {
        if (pts < 0) return -1;
        return pts * 1000000LL * time_base_num / time_base_den;
    }
};

// Wraps a decoded video frame
struct VideoFrame {
    int width = 0;
    int height = 0;
    int64_t pts_us = 0;     // presentation timestamp in microseconds
    int64_t duration_us = 0;
    PixelFormat pixel_format = PixelFormat::Unknown;
    HDRMetadata hdr_metadata;

    // Color space info
    int color_space = 0;
    int color_primaries = 0;
    int color_trc = 0;

    // Software decoded frame: plane pointers and strides
    uint8_t* planes[4] = {};
    int strides[4] = {};

    // Platform-specific: on Apple, this holds the CVPixelBufferRef
    // Stored as void* for platform independence in the header
    void* native_buffer = nullptr;
    bool owns_native_buffer = false;

    // If true, the frame is from hardware decoder (zero-copy)
    bool hardware_frame = false;

    // For software frames: the backing memory
    std::shared_ptr<uint8_t[]> plane_data;

    ~VideoFrame();
    VideoFrame() = default;
    VideoFrame(VideoFrame&& other) noexcept;
    VideoFrame& operator=(VideoFrame&& other) noexcept;
    VideoFrame(const VideoFrame&) = delete;
    VideoFrame& operator=(const VideoFrame&) = delete;

    void release();
};

// Wraps a decoded audio frame
struct AudioFrame {
    int64_t pts_us = 0;
    int sample_rate = 0;
    int channels = 0;
    int num_samples = 0;

    // Interleaved float32 PCM data
    std::vector<float> data;
};

// Subtitle output
struct SubtitleFrame {
    int64_t start_us = 0;
    int64_t end_us = 0;

    // For text subtitles (SRT)
    std::string text;
    bool is_text = false;

    // For bitmap subtitles (ASS rendered, PGS)
    std::vector<uint8_t> rgba_data;
    int bitmap_width = 0;
    int bitmap_height = 0;
    int x = 0;
    int y = 0;

    // Multiple bitmap regions (ASS can produce multiple images)
    struct BitmapRegion {
        std::vector<uint8_t> rgba_data;
        int width = 0;
        int height = 0;
        int x = 0;
        int y = 0;
    };
    std::vector<BitmapRegion> regions;
};

// Media library item
struct MediaItem {
    std::string file_path;
    std::string title;
    std::string container_format;
    int64_t duration_us = 0;
    int video_width = 0;
    int video_height = 0;
    std::string video_codec;
    std::string audio_codec;
    int audio_channels = 0;
    HDRType hdr_type = HDRType::SDR;
    int64_t file_size = 0;

    int audio_track_count = 0;
    int subtitle_track_count = 0;
};

} // namespace py
