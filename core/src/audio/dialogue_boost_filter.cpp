#include "dialogue_boost_filter.h"
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

static constexpr const char* TAG = "DialogueBoost";

namespace py {

DialogueBoostFilter::DialogueBoostFilter() = default;

DialogueBoostFilter::~DialogueBoostFilter() {
    close();
}

Error DialogueBoostFilter::open_float(int sample_rate, int channels) {
    close();
    sample_rate_ = sample_rate;
    channels_ = channels;
    return Error::Ok();
}

void DialogueBoostFilter::set_amount(float amount) {
    amount = std::max(0.0f, std::min(1.0f, amount));
    amount_.store(amount, std::memory_order_relaxed);
    params_changed_.store(true, std::memory_order_relaxed);
}

Error DialogueBoostFilter::rebuild_graph() {
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }

    float amt = amount_.load(std::memory_order_relaxed);
    if (amt < 0.01f) return Error::Ok(); // No boost needed

    graph_ = avfilter_graph_alloc();
    if (!graph_) return {ErrorCode::AudioOutputError, "DialogueBoost: failed to alloc graph"};

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
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: abuffer failed"}; }

    ret = avfilter_graph_create_filter(&sink_ctx_, abuffersink, "sink", nullptr, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: abuffersink failed"}; }

    AVSampleFormat fmt = AV_SAMPLE_FMT_FLT;
    av_opt_set_bin(sink_ctx_, "sample_fmts", reinterpret_cast<const uint8_t*>(&fmt),
                   sizeof(fmt), AV_OPT_SEARCH_CHILDREN);

    AVFilterContext* last = src_ctx_;

    if (channels_ == 2) {
        // Stereo dialogue boost: use stereotools to boost the mid (center) channel.
        // Mid = (L+R)/2, Side = (L-R)/2.
        // Boosting mlev increases the center content.
        // mlev range: 0-2, default 1.0. We map amount 0-1 to mlev 1.0-2.0.
        float mlev = 1.0f + amt;  // 1.0 = neutral, 2.0 = full center boost

        char st_args[128];
        snprintf(st_args, sizeof(st_args), "mlev=%.2f", static_cast<double>(mlev));

        const AVFilter* stereotools = avfilter_get_by_name("stereotools");
        AVFilterContext* st_ctx = nullptr;
        ret = avfilter_graph_create_filter(&st_ctx, stereotools, "st", st_args, nullptr, graph_);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: stereotools failed"}; }

        ret = avfilter_link(last, 0, st_ctx, 0);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: link failed"}; }
        last = st_ctx;
    } else if (channels_ >= 6) {
        // Surround: boost the center channel using volume filter on the center channel.
        // Use a pan filter that copies all channels but boosts the center (channel 2, FC).
        float center_gain = 1.0f + amt * 1.5f;  // up to +6 dB at amount=1.0

        // For 5.1 (FL+FR+FC+LFE+BL+BR), boost FC:
        char pan_args[256];
        snprintf(pan_args, sizeof(pan_args),
                 "%s|FL=FL|FR=FR|FC=%.2f*FC|LFE=LFE|BL=BL|BR=BR",
                 ch_layout_str, static_cast<double>(center_gain));

        const AVFilter* pan = avfilter_get_by_name("pan");
        AVFilterContext* pan_ctx = nullptr;
        ret = avfilter_graph_create_filter(&pan_ctx, pan, "pan", pan_args, nullptr, graph_);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: pan failed"}; }

        ret = avfilter_link(last, 0, pan_ctx, 0);
        if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: link pan failed"}; }
        last = pan_ctx;
    }
    // For mono or other channel counts, no dialogue boost is possible

    ret = avfilter_link(last, 0, sink_ctx_, 0);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: link to sink failed"}; }

    ret = avfilter_graph_config(graph_, nullptr);
    if (ret < 0) { close(); return {ErrorCode::AudioOutputError, "DialogueBoost: graph config failed"}; }

    PY_LOG_INFO(TAG, "Dialogue boost graph built: amount=%.2f channels=%d",
                static_cast<double>(amt), channels_);
    return Error::Ok();
}

void DialogueBoostFilter::process(float* data, int num_samples, int channels) {
    if (sample_rate_ == 0 || channels_ == 0) return;

    float amt = amount_.load(std::memory_order_relaxed);
    if (amt < 0.01f) return; // Bypass when off

    if (params_changed_.exchange(false, std::memory_order_relaxed) || !graph_) {
        Error err = rebuild_graph();
        if (err) {
            PY_LOG_ERROR(TAG, "DialogueBoost rebuild failed: %s", err.message.c_str());
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

void DialogueBoostFilter::close() {
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
