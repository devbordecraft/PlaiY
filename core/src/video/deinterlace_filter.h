#pragma once

#include "plaiy/error.h"
#include <atomic>

struct AVFrame;
struct AVFilterGraph;
struct AVFilterContext;

namespace py {

// Deinterlaces video frames using FFmpeg's yadif or bwdif filters.
// Operates on AVFrame* in the video decode thread (SW decode path only).
class DeinterlaceFilter {
public:
    enum Mode { Yadif = 0, Bwdif = 1 };

    DeinterlaceFilter();
    ~DeinterlaceFilter();

    Error open(int width, int height, int pix_fmt, int time_base_num, int time_base_den);
    void close();
    void flush();

    // Push/pull pattern (same as AudioTempoFilter).
    int send_frame(AVFrame* frame);
    int receive_frame(AVFrame* frame);

    void set_enabled(bool e) { enabled_.store(e, std::memory_order_relaxed); }
    bool enabled() const { return enabled_.load(std::memory_order_relaxed); }

    void set_mode(Mode m) { mode_ = m; }
    Mode mode() const { return mode_; }

private:
    Error rebuild_graph();

    AVFilterGraph* graph_ = nullptr;
    AVFilterContext* src_ctx_ = nullptr;
    AVFilterContext* sink_ctx_ = nullptr;
    int width_ = 0;
    int height_ = 0;
    int pix_fmt_ = 0;
    int time_base_num_ = 1;
    int time_base_den_ = 25;
    Mode mode_ = Yadif;
    std::atomic<bool> enabled_{false};
};

} // namespace py
