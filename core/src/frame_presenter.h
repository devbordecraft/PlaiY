#pragma once

#include "plaiy/types.h"
#include "plaiy/clock.h"
#include "plaiy/frame_queue.h"

#include <atomic>
#include <memory>
#include <mutex>

namespace py {

class FramePresenter {
public:
    FramePresenter(FrameQueue& video_frame_queue,
                   Clock& clock,
                   std::mutex& presented_frame_mutex,
                   std::unique_ptr<VideoFrame>& presented_frame,
                   std::atomic<bool>& waiting_for_first_frame,
                   std::atomic<int>& frames_rendered,
                   std::atomic<int>& frames_dropped);

    // Returns the frame to present, or nullptr if no frame is ready.
    // The returned pointer is valid until the next call.
    VideoFrame* acquire(int64_t target_pts_us);

    // No-op: frame is owned by presented_frame, released on next acquire.
    void release(VideoFrame* frame);

private:
    FrameQueue& video_frame_queue_;
    Clock& clock_;
    std::mutex& presented_frame_mutex_;
    std::unique_ptr<VideoFrame>& presented_frame_;
    std::atomic<bool>& waiting_for_first_frame_;
    std::atomic<int>& frames_rendered_;
    std::atomic<int>& frames_dropped_;
};

} // namespace py
