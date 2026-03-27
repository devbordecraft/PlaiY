#include "audio_tempo_filter.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
}

#include <cmath>
#include <cstdio>

static constexpr const char* TAG = "AudioTempo";

namespace py {

AudioTempoFilter::AudioTempoFilter() = default;

AudioTempoFilter::~AudioTempoFilter() {
    close();
}

Error AudioTempoFilter::open_avframe(AVCodecContext* codec_ctx) {
    close();
    codec_ctx_ = codec_ctx;
    // Don't build graph yet — it gets built on set_tempo() when tempo != 1.0.
    // This is called once when the chain opens; set_tempo() may be called later.
    return Error::Ok();
}

void AudioTempoFilter::set_tempo(double tempo) {
    pending_tempo_ = tempo;
    bool need_graph = std::abs(tempo - 1.0) > 0.001;
    bool had_graph = graph_ != nullptr;
    bool tempo_changed = std::abs(tempo - tempo_) > 0.001;

    if (!need_graph) {
        // 1.0x — tear down any existing graph
        if (had_graph) {
            avfilter_graph_free(&graph_);
            graph_ = nullptr;
            src_ctx_ = nullptr;
            sink_ctx_ = nullptr;
        }
        tempo_ = 1.0;
        return;
    }

    if (!tempo_changed && had_graph) return;  // No change needed

    // Rebuild graph with new tempo
    tempo_ = tempo;
    if (codec_ctx_) {
        Error err = rebuild_graph();
        if (err) {
            PY_LOG_ERROR(TAG, "Failed to rebuild tempo filter: %s", err.message.c_str());
        }
    }
}

Error AudioTempoFilter::rebuild_graph() {
    // Tear down old graph
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }

    static constexpr double kAtempoMin = 0.5;
    static constexpr double kAtempoMax = 2.0;
    static constexpr double kAtempoEpsilon = 0.001;

    if (std::abs(tempo_ - 1.0) < kAtempoEpsilon) {
        return Error::Ok(); // No filter needed at 1.0x
    }

    graph_ = avfilter_graph_alloc();
    if (!graph_) {
        return {ErrorCode::AudioOutputError, "Failed to allocate filter graph"};
    }

    // Build abuffer source args
    char src_args[256];
    char ch_layout_str[64];
    av_channel_layout_describe(&codec_ctx_->ch_layout, ch_layout_str, sizeof(ch_layout_str));

    snprintf(src_args, sizeof(src_args),
             "time_base=%d/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             codec_ctx_->pkt_timebase.num ? codec_ctx_->pkt_timebase.num : 1,
             codec_ctx_->pkt_timebase.den ? codec_ctx_->pkt_timebase.den : codec_ctx_->sample_rate,
             codec_ctx_->sample_rate,
             av_get_sample_fmt_name(codec_ctx_->sample_fmt),
             ch_layout_str);

    const AVFilter* abuffer = avfilter_get_by_name("abuffer");
    const AVFilter* abuffersink = avfilter_get_by_name("abuffersink");

    int ret = avfilter_graph_create_filter(&src_ctx_, abuffer, "src", src_args, nullptr, graph_);
    if (ret < 0) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to create abuffer filter"};
    }

    ret = avfilter_graph_create_filter(&sink_ctx_, abuffersink, "sink", nullptr, nullptr, graph_);
    if (ret < 0) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to create abuffersink filter"};
    }

    // Constrain sink output to match the codec's format
    ret = av_opt_set_bin(sink_ctx_, "sample_fmts",
                         reinterpret_cast<const uint8_t*>(&codec_ctx_->sample_fmt),
                         sizeof(codec_ctx_->sample_fmt), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to set sink sample format"}; }

    ret = av_opt_set_bin(sink_ctx_, "sample_rates",
                         reinterpret_cast<const uint8_t*>(&codec_ctx_->sample_rate),
                         sizeof(codec_ctx_->sample_rate), AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to set sink sample rate"}; }

    ret = av_opt_set(sink_ctx_, "ch_layouts", ch_layout_str, AV_OPT_SEARCH_CHILDREN);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to set sink channel layout"}; }

    // Build atempo chain. Each atempo instance handles 0.5-2.0 range.
    AVFilterContext* last = src_ctx_;
    double remaining = tempo_;
    int filter_idx = 0;

    while (remaining < kAtempoMin - kAtempoEpsilon || remaining > kAtempoMax + kAtempoEpsilon) {
        double this_tempo = (remaining < 1.0) ? kAtempoMin : kAtempoMax;
        char tempo_str[32];
        snprintf(tempo_str, sizeof(tempo_str), "%.4f", this_tempo);

        char fname[32];
        snprintf(fname, sizeof(fname), "atempo%d", filter_idx++);

        AVFilterContext* atempo_ctx = nullptr;
        const AVFilter* atempo = avfilter_get_by_name("atempo");
        ret = avfilter_graph_create_filter(&atempo_ctx, atempo, fname, tempo_str, nullptr, graph_);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to create atempo filter"}; }

        ret = avfilter_link(last, 0, atempo_ctx, 0);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to link atempo filter"}; }

        last = atempo_ctx;
        remaining /= this_tempo;
    }

    // Final atempo for the remaining value (0.5-2.0 range)
    {
        char tempo_str[32];
        snprintf(tempo_str, sizeof(tempo_str), "%.4f", remaining);

        char fname[32];
        snprintf(fname, sizeof(fname), "atempo%d", filter_idx);

        AVFilterContext* atempo_ctx = nullptr;
        const AVFilter* atempo = avfilter_get_by_name("atempo");
        ret = avfilter_graph_create_filter(&atempo_ctx, atempo, fname, tempo_str, nullptr, graph_);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to create final atempo filter"}; }

        ret = avfilter_link(last, 0, atempo_ctx, 0);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to link final atempo filter"}; }

        last = atempo_ctx;
    }

    // Link last atempo to sink
    ret = avfilter_link(last, 0, sink_ctx_, 0);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to link to abuffersink"}; }

    ret = avfilter_graph_config(graph_, nullptr);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Failed to configure filter graph"}; }

    PY_LOG_INFO(TAG, "Tempo filter initialized: %.2fx", tempo_);
    return Error::Ok();
}

int AudioTempoFilter::send_frame(AVFrame* frame) {
    if (!src_ctx_) return AVERROR(EAGAIN);
    return av_buffersrc_add_frame(src_ctx_, frame);
}

int AudioTempoFilter::receive_frame(AVFrame* frame) {
    if (!sink_ctx_) return AVERROR(EAGAIN);
    return av_buffersink_get_frame(sink_ctx_, frame);
}

void AudioTempoFilter::flush() {
    // Tear down graph; rebuild_graph() will be called on next set_tempo()
    // or the chain will call open_avframe() again.
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }
}

void AudioTempoFilter::close() {
    flush();
    codec_ctx_ = nullptr;
    tempo_ = 1.0;
    pending_tempo_ = 1.0;
}

} // namespace py
