#include "frame_presenter.h"

namespace py {

FramePresenter::FramePresenter(FrameQueue& video_frame_queue,
                               Clock& clock,
                               std::mutex& presented_frame_mutex,
                               std::unique_ptr<VideoFrame>& presented_frame,
                               std::atomic<bool>& waiting_for_first_frame,
                               std::atomic<int>& frames_rendered,
                               std::atomic<int>& frames_dropped)
    : video_frame_queue_(video_frame_queue)
    , clock_(clock)
    , presented_frame_mutex_(presented_frame_mutex)
    , presented_frame_(presented_frame)
    , waiting_for_first_frame_(waiting_for_first_frame)
    , frames_rendered_(frames_rendered)
    , frames_dropped_(frames_dropped) {}

VideoFrame* FramePresenter::acquire(int64_t /*target_pts_us*/) {
    // Use peek_fields() to read PTS/duration under lock without holding a raw
    // pointer that could be invalidated by a concurrent pop().
    auto fields = video_frame_queue_.peek_fields();
    if (!fields.valid) {
        std::lock_guard lock(presented_frame_mutex_);
        return presented_frame_.get();
    }

    int64_t clock_us = clock_.now_us();

    // When waiting for the first frame after play/seek, always accept it
    // regardless of PTS — the clock may not match the stream's start PTS.
    bool force = waiting_for_first_frame_.load();

    // Pop when the frame's presentation time is within half a frame duration.
    // This adapts to the content's framerate and avoids presenting a full
    // vsync too early (which creates uneven frame cadence).
    int64_t tolerance_us = fields.duration_us > 0 ? fields.duration_us / 2 : 8000;

    if (!force && fields.pts_us > clock_us + tolerance_us) {
        std::lock_guard lock(presented_frame_mutex_);
        return presented_frame_.get();
    }

    std::lock_guard lock(presented_frame_mutex_);

    // Lazily create the presented frame storage once
    if (!presented_frame_) {
        presented_frame_ = std::make_unique<VideoFrame>();
    }

    // Pop directly into the existing frame (release old data via move-assign)
    if (!video_frame_queue_.try_pop(*presented_frame_)) {
        return presented_frame_.get();
    }

    frames_rendered_.fetch_add(1, std::memory_order_relaxed);

    // Video has a frame — release the audio gate and unfreeze the clock.
    // Audio and clock start together with video, ensuring A-V sync.
    // Use exchange() so only one thread unfreezes even under concurrent calls.
    if (waiting_for_first_frame_.exchange(false)) {
        clock_.unfreeze();
        clock_us = clock_.now_us();
    }

    // Skip frames that are already late (PTS behind the clock).
    // This catches up when the decoder falls behind without showing stale frames.
    VideoFrame skip_frame;
    while (true) {
        auto next = video_frame_queue_.peek_fields();
        if (!next.valid) break;
        int64_t late_tolerance_us = next.duration_us > 0 ? next.duration_us / 2 : 8000;
        if (next.pts_us + late_tolerance_us > clock_us) break;
        video_frame_queue_.try_pop(skip_frame);
        *presented_frame_ = std::move(skip_frame);
        frames_dropped_.fetch_add(1, std::memory_order_relaxed);
        clock_us = clock_.now_us();
    }

    return presented_frame_.get();
}

void FramePresenter::release(VideoFrame* frame) {
    // Frame is owned by presented_frame_, released when next frame is acquired
    (void)frame;
}

} // namespace py
