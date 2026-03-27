#pragma once

#include "plaiy/error.h"
#include <atomic>

struct AVFrame;
struct AVCodecContext;

namespace py {

enum class AudioFilterStage {
    PreResample,   // Operates on AVFrame* (before resampler)
    PostResample,  // Operates on float32 interleaved (after resampler)
};

class IAudioFilter {
public:
    virtual ~IAudioFilter() = default;

    // Human-readable identifier (e.g. "tempo", "equalizer")
    virtual const char* name() const = 0;

    // Which stage this filter runs in
    virtual AudioFilterStage stage() const = 0;

    // --- PreResample interface (AVFrame* in/out) ---
    virtual Error open_avframe(AVCodecContext* /*codec_ctx*/) { return Error::Ok(); }
    virtual int send_frame(AVFrame* /*frame*/) { return -1; }
    virtual int receive_frame(AVFrame* /*frame*/) { return -1; }
    virtual void flush() {}

    // --- PostResample interface (float32 interleaved, in-place) ---
    virtual Error open_float(int /*sample_rate*/, int /*channels*/) { return Error::Ok(); }
    virtual void process(float* /*data*/, int /*num_samples*/, int /*channels*/) {}

    virtual void close() = 0;

    void set_enabled(bool e) { enabled_.store(e, std::memory_order_relaxed); }
    bool enabled() const { return enabled_.load(std::memory_order_relaxed); }

private:
    std::atomic<bool> enabled_{false};
};

} // namespace py
