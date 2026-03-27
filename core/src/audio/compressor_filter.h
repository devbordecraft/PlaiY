#pragma once

#include "audio_filter.h"
#include <atomic>

struct AVFilterGraph;
struct AVFilterContext;

namespace py {

// Dynamic range compressor using FFmpeg's acompressor filter.
// Operates post-resample on float32 interleaved audio.
class CompressorFilter : public IAudioFilter {
public:
    CompressorFilter();
    ~CompressorFilter() override;

    const char* name() const override { return "compressor"; }
    AudioFilterStage stage() const override { return AudioFilterStage::PostResample; }

    Error open_float(int sample_rate, int channels) override;
    void process(float* data, int num_samples, int channels) override;
    void close() override;

    // Parameters (thread-safe via atomics)
    void set_threshold(float db);     // default: -24 dB
    void set_ratio(float ratio);      // default: 4.0
    void set_attack(float ms);        // default: 20 ms
    void set_release(float ms);       // default: 250 ms
    void set_makeup(float db);        // default: 0 dB

private:
    Error rebuild_graph();

    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* src_ctx_ = nullptr;
    AVFilterContext* sink_ctx_ = nullptr;
    int sample_rate_ = 0;
    int channels_ = 0;

    std::atomic<float> threshold_{-24.0f};
    std::atomic<float> ratio_{4.0f};
    std::atomic<float> attack_{20.0f};
    std::atomic<float> release_{250.0f};
    std::atomic<float> makeup_{0.0f};
    std::atomic<bool> params_changed_{false};
};

} // namespace py
