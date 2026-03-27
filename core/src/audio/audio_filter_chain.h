#pragma once

#include "audio_filter.h"
#include "audio_resampler.h"
#include <functional>
#include <memory>
#include <vector>

struct AVCodecContext;

namespace py {

// Two-stage audio filter chain:
//   Stage 1 (PreResample):  AVFrame* → enabled pre-resample filters → AVFrame*
//   Stage 2 (Resampler):    AVFrame* → float32 interleaved
//   Stage 3 (PostResample): float32 → enabled post-resample filters → float32
//
// Pre-resample filters (like tempo) may produce multiple output frames per input.
// Use send_frame() + drain() to handle this, mirroring the FFmpeg send/receive pattern.
class AudioFilterChain {
public:
    AudioFilterChain();
    ~AudioFilterChain();

    // Register a filter. Filters within each stage process in registration order.
    void add(std::unique_ptr<IAudioFilter> filter);

    // Lookup by name (for bridge-layer parameter setting).
    IAudioFilter* find(const char* name) const;

    // Open all filters + resampler for the given format.
    Error open(AVCodecContext* codec_ctx, int out_sample_rate, int out_channels);
    void close();
    bool is_open() const { return open_; }

    // Push an input AVFrame through pre-resample filters.
    // Call drain() afterwards to pull all output chunks.
    void send_frame(AVFrame* frame);

    // Pull one resampled + post-filtered output chunk.
    // Returns true if a chunk was produced (out_samples/out_num_samples filled).
    // Returns false when no more output is available (call send_frame with next input).
    bool drain(std::vector<float>& out_samples, int& out_num_samples);

    // Flush all pre-resample filters (on seek). Discards buffered data.
    void flush();

    int out_channels() const { return out_channels_; }
    int out_sample_rate() const { return out_sample_rate_; }

private:
    std::vector<std::unique_ptr<IAudioFilter>> pre_resample_;
    std::vector<std::unique_ptr<IAudioFilter>> post_resample_;
    AudioResampler resampler_;
    AVFrame* temp_frame_ = nullptr;
    int out_sample_rate_ = 0;
    int out_channels_ = 0;
    bool open_ = false;

    // State for drain loop
    bool has_pending_direct_ = false;  // true when direct frame (no pre-resample) is pending
    AVFrame* pending_direct_frame_ = nullptr;
    IAudioFilter* active_pre_filter_ = nullptr;  // the pre-resample filter to drain from
};

} // namespace py
