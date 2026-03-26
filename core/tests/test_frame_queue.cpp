#include <catch2/catch_test_macros.hpp>
#include "plaiy/frame_queue.h"
#include <thread>
#include <chrono>

using py::FrameQueue;
using py::VideoFrame;
using namespace std::chrono_literals;

static VideoFrame make_frame(int64_t pts_us, int64_t duration_us = 33333) {
    VideoFrame f;
    f.pts_us = pts_us;
    f.duration_us = duration_us;
    // Leave native_buffer null — no platform code invoked
    return f;
}

TEST_CASE("FrameQueue starts empty") {
    FrameQueue q(4);
    REQUIRE(q.empty());
    REQUIRE(q.size() == 0);
}

TEST_CASE("FrameQueue push and pop") {
    FrameQueue q(4);
    REQUIRE(q.push(make_frame(100'000)));
    REQUIRE(q.size() == 1);

    VideoFrame out;
    REQUIRE(q.pop(out));
    REQUIRE(out.pts_us == 100'000);
    REQUIRE(q.empty());
}

TEST_CASE("FrameQueue FIFO order") {
    FrameQueue q(4);
    q.push(make_frame(1000));
    q.push(make_frame(2000));
    q.push(make_frame(3000));

    VideoFrame out;
    q.pop(out); REQUIRE(out.pts_us == 1000);
    q.pop(out); REQUIRE(out.pts_us == 2000);
    q.pop(out); REQUIRE(out.pts_us == 3000);
}

TEST_CASE("FrameQueue try_push when full") {
    FrameQueue q(2);
    REQUIRE(q.push(make_frame(1000)));
    REQUIRE(q.push(make_frame(2000)));
    // Queue is full
    REQUIRE_FALSE(q.try_push(make_frame(3000)));
}

TEST_CASE("FrameQueue try_pop when empty") {
    FrameQueue q(4);
    VideoFrame out;
    REQUIRE_FALSE(q.try_pop(out));
}

TEST_CASE("FrameQueue peek_fields") {
    FrameQueue q(4);
    q.push(make_frame(500'000, 16666));

    auto fields = q.peek_fields();
    REQUIRE(fields.valid);
    REQUIRE(fields.pts_us == 500'000);
    REQUIRE(fields.duration_us == 16666);

    // peek_fields does not remove
    REQUIRE(q.size() == 1);
}

TEST_CASE("FrameQueue peek_fields on empty") {
    FrameQueue q(4);
    auto fields = q.peek_fields();
    REQUIRE_FALSE(fields.valid);
}

TEST_CASE("FrameQueue peek") {
    FrameQueue q(4);
    q.push(make_frame(42'000));

    VideoFrame* front = q.peek();
    REQUIRE(front != nullptr);
    REQUIRE(front->pts_us == 42'000);
    REQUIRE(q.size() == 1); // not removed
}

TEST_CASE("FrameQueue void pop") {
    FrameQueue q(4);
    q.push(make_frame(1000));
    q.push(make_frame(2000));
    REQUIRE(q.size() == 2);

    q.pop(); // remove front without returning
    REQUIRE(q.size() == 1);

    auto fields = q.peek_fields();
    REQUIRE(fields.pts_us == 2000);
}

TEST_CASE("FrameQueue flush") {
    FrameQueue q(4);
    q.push(make_frame(1000));
    q.push(make_frame(2000));
    q.flush();
    REQUIRE(q.empty());
}

TEST_CASE("FrameQueue abort unblocks pop") {
    FrameQueue q(4);

    std::thread popper([&] {
        VideoFrame out;
        bool got = q.pop(out);
        REQUIRE_FALSE(got);
    });

    std::this_thread::sleep_for(10ms);
    q.abort();
    popper.join();
}

TEST_CASE("FrameQueue reset after abort") {
    FrameQueue q(4);
    q.abort();

    VideoFrame out;
    REQUIRE_FALSE(q.try_pop(out));

    q.reset();
    REQUIRE(q.push(make_frame(1000)));
    REQUIRE(q.size() == 1);
}

TEST_CASE("FrameQueue blocking push unblocked by pop") {
    FrameQueue q(2);
    q.push(make_frame(1000));
    q.push(make_frame(2000));
    // Queue is full

    std::atomic<bool> push_done{false};
    std::thread pusher([&] {
        q.push(make_frame(3000)); // should block
        push_done.store(true);
    });

    std::this_thread::sleep_for(10ms);
    REQUIRE_FALSE(push_done.load()); // still blocked

    VideoFrame out;
    q.pop(out); // free a slot
    pusher.join();
    REQUIRE(push_done.load());
    REQUIRE(q.size() == 2); // 2000 + 3000
}
