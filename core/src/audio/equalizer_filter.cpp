#include "equalizer_filter.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/frame.h>
#include <libavutil/samplefmt.h>
}

#include <cmath>
#include <cstdio>

static constexpr const char* TAG = "EQFilter";

namespace py {

EqualizerFilter::EqualizerFilter() {
    for (auto& g : band_gains_) g.store(0.0f, std::memory_order_relaxed);
}

EqualizerFilter::~EqualizerFilter() {
    close();
}

Error EqualizerFilter::open_float(int sample_rate, int channels) {
    close();
    sample_rate_ = sample_rate;
    channels_ = channels;
    // Don't build graph until enabled and process() is called with non-zero gains
    return Error::Ok();
}

void EqualizerFilter::set_band_gain(int band, float gain_db) {
    if (band < 0 || band >= NUM_BANDS) return;
    gain_db = std::max(-20.0f, std::min(20.0f, gain_db));
    band_gains_[static_cast<size_t>(band)].store(gain_db, std::memory_order_relaxed);
    params_changed_.store(true, std::memory_order_relaxed);
}

float EqualizerFilter::band_gain(int band) const {
    if (band < 0 || band >= NUM_BANDS) return 0.0f;
    return band_gains_[static_cast<size_t>(band)].load(std::memory_order_relaxed);
}

void EqualizerFilter::set_preset(int preset) {
    // Preset EQ curves (gain in dB for each of the 10 bands)
    static const float presets[][NUM_BANDS] = {
        {0, 0, 0, 0, 0, 0, 0, 0, 0, 0},           // 0: Flat
        {6, 5, 4, 2, 0, 0, 0, 0, 1, 2},             // 1: Bass Boost
        {-2, -1, 0, 2, 4, 4, 3, 1, 0, -1},          // 2: Vocal
        {3, 2, 0, -1, 0, 1, 2, 3, 3, 2},            // 3: Cinema
    };

    if (preset < 0 || preset >= 4) return;
    preset_ = preset;
    for (int i = 0; i < NUM_BANDS; i++) {
        band_gains_[static_cast<size_t>(i)].store(presets[preset][i], std::memory_order_relaxed);
    }
    params_changed_.store(true, std::memory_order_relaxed);
}

Error EqualizerFilter::rebuild_graph() {
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }

    graph_ = avfilter_graph_alloc();
    if (!graph_) return {ErrorCode::AudioOutputError, "Failed to allocate EQ filter graph"};

    // Build abuffer source for float32 interleaved
    char src_args[256];
    AVChannelLayout ch_layout{};
    av_channel_layout_default(&ch_layout, channels_);
    char ch_layout_str[64];
    av_channel_layout_describe(&ch_layout, ch_layout_str, sizeof(ch_layout_str));
    av_channel_layout_uninit(&ch_layout);

    snprintf(src_args, sizeof(src_args),
             "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             sample_rate_, sample_rate_,
             av_get_sample_fmt_name(AV_SAMPLE_FMT_FLT),
             ch_layout_str);

    const AVFilter* abuffer = avfilter_get_by_name("abuffer");
    const AVFilter* abuffersink = avfilter_get_by_name("abuffersink");

    int ret = avfilter_graph_create_filter(&src_ctx_, abuffer, "src", src_args, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to create abuffer"}; }

    ret = avfilter_graph_create_filter(&sink_ctx_, abuffersink, "sink", nullptr, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to create abuffersink"}; }

    // Constrain sink to float32
    AVSampleFormat fmt = AV_SAMPLE_FMT_FLT;
    ret = av_opt_set_bin(sink_ctx_, "sample_fmts", reinterpret_cast<const uint8_t*>(&fmt),
                         sizeof(fmt), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to set sink format"}; }

    // Build superequalizer filter args: 18 band gains (we set the first 10, rest are 0)
    // The superequalizer has bands at: 65, 92, 131, 185, 262, 370, 523, 740, 1047,
    // 1480, 2093, 2960, 4186, 5920, 8372, 11840, 16744, 20000 Hz
    // We map our 10 bands to the closest superequalizer bands:
    // Band 0 (31 Hz)   -> 1b (closest to 65 Hz)
    // Band 1 (62 Hz)   -> 1b
    // Band 2 (125 Hz)  -> 2b
    // Band 3 (250 Hz)  -> 4b
    // Band 4 (500 Hz)  -> 6b
    // Band 5 (1000 Hz) -> 9b
    // Band 6 (2000 Hz) -> 11b
    // Band 7 (4000 Hz) -> 13b
    // Band 8 (8000 Hz) -> 15b
    // Band 9 (16000 Hz)-> 17b
    // For simplicity, use the superequalizer's band mapping directly.
    // superequalizer accepts gains as dB values for 18 bands.
    char eq_args[512];
    snprintf(eq_args, sizeof(eq_args),
             "1b=%.1f:2b=%.1f:3b=%.1f:4b=%.1f:5b=%.1f:6b=%.1f:7b=%.1f:8b=%.1f:9b=%.1f:"
             "10b=%.1f:11b=%.1f:12b=%.1f:13b=%.1f:14b=%.1f:15b=%.1f:16b=%.1f:17b=%.1f:18b=%.1f",
             band_gains_[0].load(std::memory_order_relaxed),  // ~65 Hz
             band_gains_[0].load(std::memory_order_relaxed),  // ~92 Hz
             band_gains_[1].load(std::memory_order_relaxed),  // ~131 Hz
             band_gains_[2].load(std::memory_order_relaxed),  // ~185 Hz
             band_gains_[2].load(std::memory_order_relaxed),  // ~262 Hz
             band_gains_[3].load(std::memory_order_relaxed),  // ~370 Hz
             band_gains_[4].load(std::memory_order_relaxed),  // ~523 Hz
             band_gains_[4].load(std::memory_order_relaxed),  // ~740 Hz
             band_gains_[5].load(std::memory_order_relaxed),  // ~1047 Hz
             band_gains_[5].load(std::memory_order_relaxed),  // ~1480 Hz
             band_gains_[6].load(std::memory_order_relaxed),  // ~2093 Hz
             band_gains_[6].load(std::memory_order_relaxed),  // ~2960 Hz
             band_gains_[7].load(std::memory_order_relaxed),  // ~4186 Hz
             band_gains_[7].load(std::memory_order_relaxed),  // ~5920 Hz
             band_gains_[8].load(std::memory_order_relaxed),  // ~8372 Hz
             band_gains_[8].load(std::memory_order_relaxed),  // ~11840 Hz
             band_gains_[9].load(std::memory_order_relaxed),  // ~16744 Hz
             band_gains_[9].load(std::memory_order_relaxed)); // ~20000 Hz

    const AVFilter* supereq = avfilter_get_by_name("superequalizer");
    AVFilterContext* eq_ctx = nullptr;
    ret = avfilter_graph_create_filter(&eq_ctx, supereq, "eq", eq_args, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to create superequalizer"}; }

    ret = avfilter_link(src_ctx_, 0, eq_ctx, 0);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to link src->eq"}; }

    ret = avfilter_link(eq_ctx, 0, sink_ctx_, 0);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to link eq->sink"}; }

    ret = avfilter_graph_config(graph_, nullptr);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "EQ: failed to configure graph"}; }

    PY_LOG_INFO(TAG, "EQ filter graph built");
    return Error::Ok();
}

void EqualizerFilter::process(float* data, int num_samples, int channels) {
    if (sample_rate_ == 0 || channels_ == 0) return;

    // Rebuild graph if parameters changed
    if (params_changed_.exchange(false, std::memory_order_relaxed) || !graph_) {
        Error err = rebuild_graph();
        if (err) {
            PY_LOG_ERROR(TAG, "EQ rebuild failed: %s", err.message.c_str());
            return;
        }
    }

    if (!src_ctx_ || !sink_ctx_) return;

    // Wrap float data in an AVFrame
    AVFrame* frame = av_frame_alloc();
    frame->format = AV_SAMPLE_FMT_FLT;
    frame->sample_rate = sample_rate_;
    frame->nb_samples = num_samples;
    av_channel_layout_default(&frame->ch_layout, channels);

    // Point directly at the data buffer (no copy)
    frame->data[0] = reinterpret_cast<uint8_t*>(data);
    frame->linesize[0] = num_samples * channels * static_cast<int>(sizeof(float));
    frame->extended_data = frame->data;

    int ret = av_buffersrc_add_frame(src_ctx_, frame);
    if (ret < 0) {
        // Don't free data — we don't own it
        frame->data[0] = nullptr;
        av_frame_free(&frame);
        return;
    }

    // Pull filtered output back
    AVFrame* out = av_frame_alloc();
    ret = av_buffersink_get_frame(sink_ctx_, out);
    if (ret >= 0 && out->nb_samples == num_samples) {
        // Copy filtered data back to the original buffer
        memcpy(data, out->data[0],
               static_cast<size_t>(num_samples) * static_cast<size_t>(channels) * sizeof(float));
    }

    av_frame_free(&out);
    frame->data[0] = nullptr;  // prevent freeing our external buffer
    av_frame_free(&frame);
}

void EqualizerFilter::close() {
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }
    sample_rate_ = 0;
    channels_ = 0;
}

} // namespace py
