#pragma once

#include "audio_filter.h"

struct AVFrame;
struct AVFilterGraph;
struct AVFilterContext;
struct AVCodecContext;

namespace py {

class AudioTempoFilter : public IAudioFilter {
public:
    AudioTempoFilter();
    ~AudioTempoFilter() override;

    // IAudioFilter interface
    const char* name() const override { return "tempo"; }
    AudioFilterStage stage() const override { return AudioFilterStage::PreResample; }

    Error open_avframe(AVCodecContext* codec_ctx) override;
    int send_frame(AVFrame* frame) override;
    int receive_frame(AVFrame* frame) override;
    void flush() override;
    void close() override;

    // Tempo-specific configuration
    void set_tempo(double tempo);
    double tempo() const { return tempo_; }

private:
    Error rebuild_graph();

    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* src_ctx_ = nullptr;
    AVFilterContext* sink_ctx_ = nullptr;
    AVCodecContext* codec_ctx_ = nullptr;  // borrowed, not owned
    double tempo_ = 1.0;
    double pending_tempo_ = 1.0;
};

} // namespace py
