#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include "playback_stats.h"

using namespace py;

// Helper to create a StatsContext with default-constructed state.
// Caller overrides specific fields as needed.
struct StatsFixture {
    MediaInfo media_info;
    int active_video_stream = -1;
    int active_audio_stream = -1;

    AudioOutputMode audio_output_mode = AudioOutputMode::PCM;

    std::mutex presented_frame_mutex;
    std::unique_ptr<VideoFrame> presented_frame;

    std::atomic<int> frames_rendered{0};
    std::atomic<int> frames_dropped{0};

    FrameQueue video_frame_queue{8};
    PacketQueue video_packet_queue{32, 50 * 1024 * 1024};
    PacketQueue audio_packet_queue{32, 10 * 1024 * 1024};

    SPSCRingBuffer<float> audio_ring;

    std::mutex audio_ring_flush_mutex;
    size_t passthrough_ring_size = 0;
    size_t passthrough_ring_capacity = 0;

    Clock clock;
    std::atomic<double> playback_speed{1.0};

    StatsContext make_context() {
        return StatsContext{
            .media_info = media_info,
            .active_video_stream = active_video_stream,
            .active_audio_stream = active_audio_stream,
            .audio_output = nullptr,
            .audio_output_mode = audio_output_mode,
            .presented_frame_mutex = presented_frame_mutex,
            .presented_frame = presented_frame,
            .frames_rendered = frames_rendered,
            .frames_dropped = frames_dropped,
            .video_frame_queue = video_frame_queue,
            .video_packet_queue = video_packet_queue,
            .audio_packet_queue = audio_packet_queue,
            .audio_ring = audio_ring,
            .audio_ring_flush_mutex = audio_ring_flush_mutex,
            .passthrough_ring_size = passthrough_ring_size,
            .passthrough_ring_capacity = passthrough_ring_capacity,
            .clock = clock,
            .playback_speed = playback_speed,
        };
    }
};

TEST_CASE("gather_playback_stats with no active streams") {
    StatsFixture f;
    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.video_width == 0);
    REQUIRE(stats.video_height == 0);
    REQUIRE(stats.audio_channels == 0);
    REQUIRE(stats.frames_rendered == 0);
    REQUIRE(stats.frames_dropped == 0);
    REQUIRE(stats.audio_passthrough == false);
    REQUIRE(stats.audio_spatial == false);
}

TEST_CASE("gather_playback_stats populates video info from track") {
    StatsFixture f;

    TrackInfo vt;

    vt.width = 3840;
    vt.height = 2160;
    vt.codec_id = 27; // AV_CODEC_ID_H264
    vt.codec_name = "h264";
    vt.frame_rate = 23.976;
    vt.hdr_metadata.type = HDRType::HDR10;
    vt.color_space = 9;
    vt.color_trc = 16;
    vt.dv_profile = 8;
    vt.dv_level = 6;
    vt.dv_bl_signal_compatibility_id = 1;

    f.media_info.tracks.push_back(vt);
    f.active_video_stream = 0;

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.video_width == 3840);
    REQUIRE(stats.video_height == 2160);
    REQUIRE(stats.video_codec_id == 27);
    REQUIRE(std::string(stats.video_codec_name) == "h264");
    REQUIRE(stats.video_fps == Catch::Approx(23.976));
    REQUIRE(stats.hdr_type == static_cast<int>(HDRType::HDR10));
    REQUIRE(stats.color_space == 9);
    REQUIRE(stats.transfer_func == 16);
    REQUIRE(stats.dv_profile == 8);
    REQUIRE(stats.dv_level == 6);
    REQUIRE(stats.dv_bl_compatibility_id == 1);
}

TEST_CASE("gather_playback_stats populates audio info from track") {
    StatsFixture f;

    TrackInfo at;

    at.codec_id = 86018; // AV_CODEC_ID_EAC3
    at.codec_name = "eac3";
    at.sample_rate = 48000;
    at.channels = 6;
    at.codec_profile = 0;

    f.media_info.tracks.push_back(at);
    f.active_audio_stream = 0;

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.audio_codec_id == 86018);
    REQUIRE(std::string(stats.audio_codec_name) == "eac3");
    REQUIRE(stats.audio_sample_rate == 48000);
    REQUIRE(stats.audio_channels == 6);
}

TEST_CASE("gather_playback_stats frame counters") {
    StatsFixture f;
    f.frames_rendered.store(1000);
    f.frames_dropped.store(5);

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.frames_rendered == 1000);
    REQUIRE(stats.frames_dropped == 5);
}

TEST_CASE("gather_playback_stats PCM ring fill percentage") {
    StatsFixture f;
    f.audio_ring.resize(1000);
    // Write 500 samples to get 50% fill
    std::vector<float> data(500, 0.0f);
    f.audio_ring.write(data.data(), 500);

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.audio_ring_fill_pct == 50);
}

TEST_CASE("gather_playback_stats passthrough ring fill percentage") {
    StatsFixture f;
    f.audio_output_mode = AudioOutputMode::Passthrough;
    f.passthrough_ring_capacity = 200;
    f.passthrough_ring_size = 100;

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.audio_ring_fill_pct == 50);
}

TEST_CASE("gather_playback_stats passthrough mode flag") {
    StatsFixture f;
    f.audio_output_mode = AudioOutputMode::Passthrough;

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.audio_passthrough == true);
    REQUIRE(stats.audio_spatial == false);
}

TEST_CASE("gather_playback_stats spatial mode flag") {
    StatsFixture f;
    f.audio_output_mode = AudioOutputMode::Spatial;

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.audio_passthrough == false);
    REQUIRE(stats.audio_spatial == true);
}

TEST_CASE("gather_playback_stats container and speed") {
    StatsFixture f;
    f.media_info.container_format = "matroska";
    f.media_info.bit_rate = 25000000;
    f.playback_speed.store(2.0);

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(std::string(stats.container_format) == "matroska");
    REQUIRE(stats.bitrate == 25000000);
    REQUIRE(stats.playback_speed == Catch::Approx(2.0));
}

TEST_CASE("gather_playback_stats presented frame metadata") {
    StatsFixture f;
    f.presented_frame = std::make_unique<VideoFrame>();
    f.presented_frame->hardware_frame = true;
    f.presented_frame->pts_us = 5000000;

    auto ctx = f.make_context();
    auto stats = gather_playback_stats(ctx);

    REQUIRE(stats.hardware_decode == true);
    REQUIRE(stats.video_pts_us == 5000000);
}
