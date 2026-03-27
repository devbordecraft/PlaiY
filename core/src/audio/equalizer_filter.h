#pragma once

#include "audio_filter.h"
#include <atomic>
#include <array>

struct AVFilterGraph;
struct AVFilterContext;

namespace py {

// 10-band parametric EQ using FFmpeg's superequalizer filter.
// Operates post-resample on float32 interleaved audio.
class EqualizerFilter : public IAudioFilter {
public:
    static constexpr int NUM_BANDS = 10;

    // Center frequencies (Hz) for each band
    static constexpr std::array<float, NUM_BANDS> BAND_FREQUENCIES = {
        31.0f, 62.0f, 125.0f, 250.0f, 500.0f,
        1000.0f, 2000.0f, 4000.0f, 8000.0f, 16000.0f
    };

    EqualizerFilter();
    ~EqualizerFilter() override;

    const char* name() const override { return "equalizer"; }
    AudioFilterStage stage() const override { return AudioFilterStage::PostResample; }

    Error open_float(int sample_rate, int channels) override;
    void process(float* data, int num_samples, int channels) override;
    void close() override;

    // Per-band gain in dB (-20 to +20). Thread-safe.
    void set_band_gain(int band, float gain_db);
    float band_gain(int band) const;

    // Presets: 0=flat, 1=bass boost, 2=vocal, 3=cinema
    void set_preset(int preset);
    int preset() const { return preset_; }

private:
    Error rebuild_graph();

    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* src_ctx_ = nullptr;
    AVFilterContext* sink_ctx_ = nullptr;
    int sample_rate_ = 0;
    int channels_ = 0;

    std::array<std::atomic<float>, NUM_BANDS> band_gains_;
    std::atomic<bool> params_changed_{false};
    int preset_ = 0;
};

} // namespace py
