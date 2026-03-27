#include "compressor_filter.h"
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

#include <cstdio>
#include <cstring>

static constexpr const char* TAG = "CompressorFilter";

namespace py {

CompressorFilter::CompressorFilter() = default;

CompressorFilter::~CompressorFilter() {
    close();
}

Error CompressorFilter::open_float(int sample_rate, int channels) {
    close();
    sample_rate_ = sample_rate;
    channels_ = channels;
    return Error::Ok();
}

void CompressorFilter::set_threshold(float db) { threshold_.store(db, std::memory_order_relaxed); params_changed_.store(true, std::memory_order_relaxed); }
void CompressorFilter::set_ratio(float r) { ratio_.store(r, std::memory_order_relaxed); params_changed_.store(true, std::memory_order_relaxed); }
void CompressorFilter::set_attack(float ms) { attack_.store(ms, std::memory_order_relaxed); params_changed_.store(true, std::memory_order_relaxed); }
void CompressorFilter::set_release(float ms) { release_.store(ms, std::memory_order_relaxed); params_changed_.store(true, std::memory_order_relaxed); }
void CompressorFilter::set_makeup(float db) { makeup_.store(db, std::memory_order_relaxed); params_changed_.store(true, std::memory_order_relaxed); }

Error CompressorFilter::rebuild_graph() {
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }

    graph_ = avfilter_graph_alloc();
    if (!graph_) return {ErrorCode::AudioOutputError, "Compressor: failed to alloc graph"};

    char src_args[256];
    AVChannelLayout ch_layout{};
    av_channel_layout_default(&ch_layout, channels_);
    char ch_layout_str[64];
    av_channel_layout_describe(&ch_layout, ch_layout_str, sizeof(ch_layout_str));
    av_channel_layout_uninit(&ch_layout);

    snprintf(src_args, sizeof(src_args),
             "time_base=1/%d:sample_rate=%d:sample_fmt=%s:channel_layout=%s",
             sample_rate_, sample_rate_,
             av_get_sample_fmt_name(AV_SAMPLE_FMT_FLT), ch_layout_str);

    const AVFilter* abuffer = avfilter_get_by_name("abuffer");
    const AVFilter* abuffersink = avfilter_get_by_name("abuffersink");

    int ret = avfilter_graph_create_filter(&src_ctx_, abuffer, "src", src_args, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Compressor: failed to create abuffer"}; }

    ret = avfilter_graph_create_filter(&sink_ctx_, abuffersink, "sink", nullptr, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Compressor: failed to create abuffersink"}; }

    AVSampleFormat fmt = AV_SAMPLE_FMT_FLT;
    av_opt_set_bin(sink_ctx_, "sample_fmts", reinterpret_cast<const uint8_t*>(&fmt),
                   sizeof(fmt), AV_OPT_SEARCH_CHILDREN);

    // Build acompressor filter
    char comp_args[256];
    snprintf(comp_args, sizeof(comp_args),
             "threshold=%.1fdB:ratio=%.1f:attack=%.1f:release=%.1f:makeup=%.1fdB",
             static_cast<double>(threshold_.load(std::memory_order_relaxed)),
             static_cast<double>(ratio_.load(std::memory_order_relaxed)),
             static_cast<double>(attack_.load(std::memory_order_relaxed)),
             static_cast<double>(release_.load(std::memory_order_relaxed)),
             static_cast<double>(makeup_.load(std::memory_order_relaxed)));

    const AVFilter* acompressor = avfilter_get_by_name("acompressor");
    AVFilterContext* comp_ctx = nullptr;
    ret = avfilter_graph_create_filter(&comp_ctx, acompressor, "comp", comp_args, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Compressor: failed to create acompressor"}; }

    ret = avfilter_link(src_ctx_, 0, comp_ctx, 0);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Compressor: failed to link src->comp"}; }

    ret = avfilter_link(comp_ctx, 0, sink_ctx_, 0);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Compressor: failed to link comp->sink"}; }

    ret = avfilter_graph_config(graph_, nullptr);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "Compressor: failed to configure graph"}; }

    PY_LOG_INFO(TAG, "Compressor graph built: threshold=%.0f dB ratio=%.1f",
                static_cast<double>(threshold_.load(std::memory_order_relaxed)),
                static_cast<double>(ratio_.load(std::memory_order_relaxed)));
    return Error::Ok();
}

void CompressorFilter::process(float* data, int num_samples, int channels) {
    if (sample_rate_ == 0 || channels_ == 0) return;

    if (params_changed_.exchange(false, std::memory_order_relaxed) || !graph_) {
        Error err = rebuild_graph();
        if (err) {
            PY_LOG_ERROR(TAG, "Compressor rebuild failed: %s", err.message.c_str());
            return;
        }
    }

    if (!src_ctx_ || !sink_ctx_) return;

    AVFrame* frame = av_frame_alloc();
    frame->format = AV_SAMPLE_FMT_FLT;
    frame->sample_rate = sample_rate_;
    frame->nb_samples = num_samples;
    av_channel_layout_default(&frame->ch_layout, channels);
    frame->data[0] = reinterpret_cast<uint8_t*>(data);
    frame->linesize[0] = num_samples * channels * static_cast<int>(sizeof(float));
    frame->extended_data = frame->data;

    int ret = av_buffersrc_add_frame(src_ctx_, frame);
    if (ret < 0) {
        frame->data[0] = nullptr;
        av_frame_free(&frame);
        return;
    }

    AVFrame* out = av_frame_alloc();
    ret = av_buffersink_get_frame(sink_ctx_, out);
    if (ret >= 0 && out->nb_samples == num_samples) {
        memcpy(data, out->data[0],
               static_cast<size_t>(num_samples) * static_cast<size_t>(channels) * sizeof(float));
    }

    av_frame_free(&out);
    frame->data[0] = nullptr;
    av_frame_free(&frame);
}

void CompressorFilter::close() {
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
