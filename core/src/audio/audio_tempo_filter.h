#pragma once

#include "plaiy/error.h"

struct AVFrame;
struct AVFilterGraph;
struct AVFilterContext;
struct AVCodecContext;

namespace py {

class AudioTempoFilter {
public:
    AudioTempoFilter();
    ~AudioTempoFilter();

    // Build the atempo filter graph for the given codec format and tempo.
    // tempo is the playback speed multiplier (e.g. 2.0 = double speed).
    Error open(AVCodecContext* codec_ctx, double tempo);
    void close();

    // Push a decoded AVFrame into the filter graph.
    // Returns 0 on success, AVERROR(EAGAIN) if need to drain first.
    int send_frame(AVFrame* frame);

    // Pull a tempo-adjusted AVFrame from the filter graph.
    // Returns 0 on success, AVERROR(EAGAIN) if need more input, AVERROR_EOF on end.
    int receive_frame(AVFrame* frame);

    // Flush internal buffers (call on seek or rate change).
    void flush();

    double tempo() const { return tempo_; }

private:
    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* src_ctx_ = nullptr;
    AVFilterContext* sink_ctx_ = nullptr;
    double tempo_ = 1.0;
};

} // namespace py
