#pragma once

#include "audio_filter.h"
#include <atomic>

struct AVFilterGraph;
struct AVFilterContext;

namespace py {

// Boosts dialogue (center channel content) in stereo or surround audio.
// For stereo: extracts center via (L+R)/2, boosts, remixes.
// For surround: boosts the center channel directly.
// Uses FFmpeg's pan filter for matrix remixing.
class DialogueBoostFilter : public IAudioFilter {
public:
    DialogueBoostFilter();
    ~DialogueBoostFilter() override;

    const char* name() const override { return "dialogue_boost"; }
    AudioFilterStage stage() const override { return AudioFilterStage::PostResample; }

    Error open_float(int sample_rate, int channels) override;
    void process(float* data, int num_samples, int channels) override;
    void close() override;

    // Boost amount: 0.0 = off, 1.0 = full boost (~6 dB center).
    void set_amount(float amount);
    float amount() const { return amount_.load(std::memory_order_relaxed); }

private:
    Error rebuild_graph();

    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* src_ctx_ = nullptr;
    AVFilterContext* sink_ctx_ = nullptr;
    int sample_rate_ = 0;
    int channels_ = 0;

    std::atomic<float> amount_{0.5f};
    std::atomic<bool> params_changed_{false};
};

} // namespace py
