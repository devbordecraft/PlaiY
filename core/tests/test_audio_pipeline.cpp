#include <catch2/catch_test_macros.hpp>
#include "audio_pipeline.h"

#include <chrono>
#include <thread>
#include <vector>

using namespace py;

namespace {

struct AudioPipelineFixture {
    SPSCRingBuffer<float> audio_ring;
    std::mutex audio_ring_flush_mutex;
    std::condition_variable audio_ring_not_full;
    std::atomic<bool> pause_requested{false};
    std::mutex pause_mutex;
    std::condition_variable pause_cv;
    std::atomic<int64_t> audio_pts_for_ring{0};
    std::atomic<bool> waiting_for_first_frame{false};
    Clock clock;
    std::atomic<bool> running{true};
    std::atomic<bool> audio_restart_requested{false};
    PacketQueue audio_packet_queue{32, 10 * 1024 * 1024};
    AudioPipeline pipeline;

    AudioPipelineFixture()
        : pipeline(AudioPipeline::SharedState{
            audio_ring,
            audio_ring_flush_mutex,
            audio_ring_not_full,
            pause_requested,
            pause_mutex,
            pause_cv,
            audio_pts_for_ring,
            waiting_for_first_frame,
            clock,
            running,
            audio_restart_requested,
            audio_packet_queue,
        }) {
        audio_ring.resize(256);
        pipeline.set_output_mode(AudioOutputMode::PCM);
    }
};

} // namespace

TEST_CASE("AudioPipeline wait_for_drain returns true when PCM ring is already empty") {
    AudioPipelineFixture f;
    REQUIRE(f.pipeline.wait_for_drain());
}

TEST_CASE("AudioPipeline wait_for_drain returns false when restart is requested") {
    AudioPipelineFixture f;
    f.audio_restart_requested.store(true);
    REQUIRE_FALSE(f.pipeline.wait_for_drain());
}

TEST_CASE("AudioPipeline wait_for_drain resumes from pause and drains ring") {
    using namespace std::chrono_literals;

    AudioPipelineFixture f;
    std::vector<float> samples(32, 0.0f);
    REQUIRE(f.audio_ring.write(samples.data(), samples.size()) == samples.size());

    f.pause_requested.store(true);

    bool drained = false;
    std::thread waiter([&] {
        drained = f.pipeline.wait_for_drain();
    });

    std::this_thread::sleep_for(20ms);
    f.pause_requested.store(false);
    f.pause_cv.notify_all();

    std::vector<float> scratch(samples.size(), 0.0f);
    REQUIRE(f.audio_ring.read(scratch.data(), samples.size()) == samples.size());
    f.audio_ring_not_full.notify_all();

    waiter.join();
    REQUIRE(drained);
}
