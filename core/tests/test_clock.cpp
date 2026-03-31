#include <catch2/catch_test_macros.hpp>
#include "plaiy/clock.h"
#include <thread>
#include <atomic>

using py::Clock;

TEST_CASE("Clock default state") {
    Clock clock;
    REQUIRE(clock.paused());
    REQUIRE(clock.rate() == 1.0);
    REQUIRE(clock.now_us() == 0);
    REQUIRE(clock.audio_pts() == 0);
}

TEST_CASE("Clock set_audio_pts while paused") {
    Clock clock;
    clock.set_audio_pts(500'000); // 0.5s
    REQUIRE(clock.audio_pts() == 500'000);
    // While paused, now_us returns the PTS without extrapolation
    REQUIRE(clock.now_us() == 500'000);
}

TEST_CASE("Clock set_audio_pts multiple times") {
    Clock clock;
    clock.set_audio_pts(100'000);
    REQUIRE(clock.audio_pts() == 100'000);
    clock.set_audio_pts(200'000);
    REQUIRE(clock.audio_pts() == 200'000);
    REQUIRE(clock.now_us() == 200'000);
}

TEST_CASE("Clock seek_to freezes at target") {
    Clock clock;
    clock.set_paused(false);
    clock.set_audio_pts(100'000);

    clock.seek_to(5'000'000); // seek to 5s
    // While frozen, now_us returns the seek target regardless of wall time
    REQUIRE(clock.now_us() == 5'000'000);

    // Setting audio PTS doesn't unfreeze
    clock.set_audio_pts(5'100'000);
    REQUIRE(clock.now_us() == 5'100'000); // PTS updated but still frozen (no extrapolation)
}

TEST_CASE("Clock unfreeze after seek") {
    Clock clock;
    clock.set_paused(false);
    clock.seek_to(1'000'000);
    REQUIRE(clock.now_us() == 1'000'000);

    clock.set_audio_pts(1'000'000);
    clock.unfreeze();

    // After unfreeze, the clock should extrapolate from audio PTS
    // While we can't test exact timing, now_us should be >= audio_pts
    REQUIRE(clock.now_us() >= 1'000'000);
}

TEST_CASE("Clock set_paused") {
    Clock clock;
    REQUIRE(clock.paused());
    clock.set_paused(false);
    REQUIRE_FALSE(clock.paused());
    clock.set_paused(true);
    REQUIRE(clock.paused());
}

TEST_CASE("Clock set_rate") {
    Clock clock;
    REQUIRE(clock.rate() == 1.0);
    clock.set_rate(2.0);
    REQUIRE(clock.rate() == 2.0);
    clock.set_rate(0.5);
    REQUIRE(clock.rate() == 0.5);
}

TEST_CASE("Clock set_rate while paused does not advance time") {
    Clock clock;
    clock.set_audio_pts(500'000);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    clock.set_rate(2.0);

    REQUIRE(clock.audio_pts() == 500'000);
    REQUIRE(clock.now_us() == 500'000);
    REQUIRE(clock.rate() == 2.0);
}

TEST_CASE("Clock set_rate while frozen does not advance time") {
    Clock clock;
    clock.set_paused(false);
    clock.seek_to(1'250'000);
    std::this_thread::sleep_for(std::chrono::milliseconds(20));

    clock.set_rate(0.5);

    REQUIRE(clock.audio_pts() == 1'250'000);
    REQUIRE(clock.now_us() == 1'250'000);
    REQUIRE(clock.rate() == 0.5);
}

TEST_CASE("Clock reset") {
    Clock clock;
    clock.set_paused(false);
    clock.set_rate(2.0);
    clock.set_audio_pts(5'000'000);

    clock.reset();
    REQUIRE(clock.paused());
    REQUIRE(clock.rate() == 1.0);
    REQUIRE(clock.now_us() == 0);
    REQUIRE(clock.audio_pts() == 0);
}

TEST_CASE("Clock concurrent readers and writer") {
    Clock clock;
    // Start with a known positive PTS so extrapolation stays positive
    clock.set_audio_pts(1'000'000);
    clock.set_paused(false);

    std::atomic<bool> done{false};
    std::atomic<int> read_count{0};
    // SeqLock stress: verify no crashes or torn reads.
    // We don't assert exact values because wall-clock extrapolation
    // varies, but the call must not crash or hang.

    std::thread writer([&] {
        for (int64_t pts = 1'000'000; pts < 2'000'000; pts += 1000) {
            clock.set_audio_pts(pts);
        }
        done.store(true, std::memory_order_release);
    });

    auto reader_fn = [&] {
        while (!done.load(std::memory_order_acquire)) {
            [[maybe_unused]] int64_t val = clock.now_us();
            read_count.fetch_add(1, std::memory_order_relaxed);
        }
    };

    std::thread reader1(reader_fn);
    std::thread reader2(reader_fn);

    writer.join();
    reader1.join();
    reader2.join();

    REQUIRE(read_count.load() > 0);
}
