#include <catch2/catch_test_macros.hpp>
#include "frame_presenter.h"

using namespace py;

struct PresenterFixture {
    FrameQueue video_frame_queue{8};
    Clock clock;
    std::mutex presented_frame_mutex;
    std::unique_ptr<VideoFrame> presented_frame;
    std::atomic<bool> waiting_for_first_frame{false};
    std::atomic<int> frames_rendered{0};
    std::atomic<int> frames_dropped{0};

    std::unique_ptr<FramePresenter> make_presenter() {
        return std::make_unique<FramePresenter>(
            video_frame_queue, clock,
            presented_frame_mutex, presented_frame,
            waiting_for_first_frame,
            frames_rendered, frames_dropped);
    }

    void push_frame(int64_t pts_us, int64_t duration_us = 41708) {
        VideoFrame f;
        f.pts_us = pts_us;
        f.duration_us = duration_us;
        video_frame_queue.try_push(std::move(f));
    }
};

TEST_CASE("FramePresenter returns nullptr on empty queue with no presented frame") {
    PresenterFixture f;
    auto p = f.make_presenter();

    auto* frame = p->acquire(0);
    REQUIRE(frame == nullptr);
}

TEST_CASE("FramePresenter returns presented_frame when queue is empty") {
    PresenterFixture f;
    f.presented_frame = std::make_unique<VideoFrame>();
    f.presented_frame->pts_us = 100000;
    auto p = f.make_presenter();

    auto* frame = p->acquire(0);
    REQUIRE(frame != nullptr);
    REQUIRE(frame->pts_us == 100000);
}

TEST_CASE("FramePresenter pops frame when waiting_for_first_frame is set") {
    PresenterFixture f;
    f.waiting_for_first_frame.store(true);
    f.clock.seek_to(0); // freeze clock at 0
    f.push_frame(5000000); // frame at 5s — way ahead of clock

    auto p = f.make_presenter();
    auto* frame = p->acquire(0);

    REQUIRE(frame != nullptr);
    REQUIRE(frame->pts_us == 5000000);
    REQUIRE(f.frames_rendered.load() == 1);
    // waiting_for_first_frame should be cleared
    REQUIRE(f.waiting_for_first_frame.load() == false);
}

TEST_CASE("FramePresenter does not pop frame too far in the future") {
    PresenterFixture f;
    f.clock.set_audio_pts(0);
    f.clock.set_paused(false);
    // Frame at 1s, clock at 0 — should not pop
    f.push_frame(1000000, 41708);

    auto p = f.make_presenter();
    auto* frame = p->acquire(0);

    // No presented frame exists, so nullptr
    REQUIRE(frame == nullptr);
    REQUIRE(f.frames_rendered.load() == 0);
}

TEST_CASE("FramePresenter pops frame within tolerance of clock") {
    PresenterFixture f;
    f.clock.set_audio_pts(1000000); // clock at 1s
    // Frame at 1.01s with 41ms duration → tolerance = 20ms → within range
    f.push_frame(1010000, 41708);

    auto p = f.make_presenter();
    auto* frame = p->acquire(0);

    REQUIRE(frame != nullptr);
    REQUIRE(frame->pts_us == 1010000);
    REQUIRE(f.frames_rendered.load() == 1);
}

TEST_CASE("FramePresenter skips late frames and increments frames_dropped") {
    PresenterFixture f;
    f.clock.set_audio_pts(3000000); // clock at 3s
    // Push 3 frames: all behind the clock
    f.push_frame(1000000);
    f.push_frame(2000000);
    f.push_frame(2500000);

    auto p = f.make_presenter();
    auto* frame = p->acquire(0);

    REQUIRE(frame != nullptr);
    // Should show the last frame (2.5s), having skipped the earlier ones
    REQUIRE(frame->pts_us == 2500000);
    // First frame is "rendered", subsequent ones are "dropped"
    REQUIRE(f.frames_rendered.load() == 1);
    REQUIRE(f.frames_dropped.load() == 2);
}

TEST_CASE("FramePresenter keeps slightly late frames that are still within tolerance") {
    PresenterFixture f;
    f.clock.set_audio_pts(1000000); // clock at 1s
    f.push_frame(980000);
    f.push_frame(990000);

    auto p = f.make_presenter();
    auto* frame = p->acquire(0);

    REQUIRE(frame != nullptr);
    REQUIRE(frame->pts_us == 980000);
    REQUIRE(f.frames_dropped.load() == 0);
}

TEST_CASE("FramePresenter unfreezes clock on first frame") {
    PresenterFixture f;
    f.waiting_for_first_frame.store(true);
    f.clock.seek_to(500000); // freeze at 500ms
    f.clock.set_paused(false);
    f.push_frame(500000);

    auto p = f.make_presenter();
    p->acquire(0);

    // After unfreeze, advancing audio PTS should update now_us
    f.clock.set_audio_pts(600000);
    REQUIRE(f.clock.now_us() >= 600000);
}

TEST_CASE("FramePresenter release is a no-op") {
    PresenterFixture f;
    auto p = f.make_presenter();
    // Should not crash
    p->release(nullptr);
}
