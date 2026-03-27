#include "deinterlace_filter.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavfilter/avfilter.h>
#include <libavfilter/buffersink.h>
#include <libavfilter/buffersrc.h>
#include <libavutil/opt.h>
#include <libavutil/pixdesc.h>
}

#include <cstdio>

static constexpr const char* TAG = "Deinterlace";

namespace py {

DeinterlaceFilter::DeinterlaceFilter() = default;

DeinterlaceFilter::~DeinterlaceFilter() {
    close();
}

Error DeinterlaceFilter::open(int width, int height, int pix_fmt,
                              int time_base_num, int time_base_den) {
    close();
    width_ = width;
    height_ = height;
    pix_fmt_ = pix_fmt;
    time_base_num_ = time_base_num;
    time_base_den_ = time_base_den;
    return rebuild_graph();
}

Error DeinterlaceFilter::rebuild_graph() {
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }

    graph_ = avfilter_graph_alloc();
    if (!graph_) return {ErrorCode::RendererError, "Deinterlace: failed to alloc graph"};

    char src_args[256];
    snprintf(src_args, sizeof(src_args),
             "video_size=%dx%d:pix_fmt=%d:time_base=%d/%d:pixel_aspect=1/1",
             width_, height_, pix_fmt_, time_base_num_, time_base_den_);

    const AVFilter* buffersrc = avfilter_get_by_name("buffer");
    const AVFilter* buffersink = avfilter_get_by_name("buffersink");

    int ret = avfilter_graph_create_filter(&src_ctx_, buffersrc, "src", src_args, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::RendererError, "Deinterlace: buffer failed"}; }

    ret = avfilter_graph_create_filter(&sink_ctx_, buffersink, "sink", nullptr, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::RendererError, "Deinterlace: buffersink failed"}; }

    // Create deinterlace filter (yadif or bwdif)
    const char* filter_name = (mode_ == Bwdif) ? "bwdif" : "yadif";
    // mode=0 = output one frame for each frame (send_field=0)
    // parity=-1 = auto-detect
    // deint=0 = deinterlace all frames (not just interlaced-flagged)
    const char* filter_args = "mode=0:parity=-1:deint=0";

    const AVFilter* deint = avfilter_get_by_name(filter_name);
    AVFilterContext* deint_ctx = nullptr;
    ret = avfilter_graph_create_filter(&deint_ctx, deint, "deint", filter_args, nullptr, graph_);
    if (ret < 0) { close(); return {ErrorCode::RendererError, "Deinterlace: filter creation failed"}; }

    ret = avfilter_link(src_ctx_, 0, deint_ctx, 0);
    if (ret < 0) { close(); return {ErrorCode::RendererError, "Deinterlace: link src failed"}; }

    ret = avfilter_link(deint_ctx, 0, sink_ctx_, 0);
    if (ret < 0) { close(); return {ErrorCode::RendererError, "Deinterlace: link sink failed"}; }

    ret = avfilter_graph_config(graph_, nullptr);
    if (ret < 0) { close(); return {ErrorCode::RendererError, "Deinterlace: graph config failed"}; }

    PY_LOG_INFO(TAG, "Deinterlace graph built: %s %dx%d", filter_name, width_, height_);
    return Error::Ok();
}

int DeinterlaceFilter::send_frame(AVFrame* frame) {
    if (!src_ctx_) return AVERROR(EAGAIN);
    return av_buffersrc_add_frame(src_ctx_, frame);
}

int DeinterlaceFilter::receive_frame(AVFrame* frame) {
    if (!sink_ctx_) return AVERROR(EAGAIN);
    return av_buffersink_get_frame(sink_ctx_, frame);
}

void DeinterlaceFilter::flush() {
    // Rebuild graph on next use
    close();
}

void DeinterlaceFilter::close() {
    if (graph_) {
        avfilter_graph_free(&graph_);
        graph_ = nullptr;
        src_ctx_ = nullptr;
        sink_ctx_ = nullptr;
    }
}

} // namespace py
