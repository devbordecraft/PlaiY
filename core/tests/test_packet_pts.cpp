#include <catch2/catch_test_macros.hpp>
#include "plaiy/types.h"

using py::Packet;

TEST_CASE("Packet::pts_us standard 90kHz") {
    Packet p;
    p.pts = 90000;
    p.time_base_num = 1;
    p.time_base_den = 90000;
    REQUIRE(p.pts_us() == 1'000'000); // 1 second
}

TEST_CASE("Packet::pts_us zero PTS") {
    Packet p;
    p.pts = 0;
    p.time_base_num = 1;
    p.time_base_den = 90000;
    REQUIRE(p.pts_us() == 0);
}

TEST_CASE("Packet::pts_us negative PTS") {
    Packet p;
    p.pts = -100;
    p.time_base_num = 1;
    p.time_base_den = 90000;
    REQUIRE(p.pts_us() == -1);
}

TEST_CASE("Packet::pts_us 48kHz audio time base") {
    Packet p;
    p.pts = 48000;
    p.time_base_num = 1;
    p.time_base_den = 48000;
    REQUIRE(p.pts_us() == 1'000'000); // 1 second
}

TEST_CASE("Packet::pts_us NTSC 1001/30000") {
    Packet p;
    p.time_base_num = 1001;
    p.time_base_den = 30000;

    // 1 frame at 29.97fps: pts=1
    // = (1/30000)*1000000*1001 + (1%30000)*1000000*1001/30000
    // = 0 + 1001000000/30000 = 33366
    p.pts = 1;
    REQUIRE(p.pts_us() == 33366);

    // 30 frames ~= 1.001 seconds
    // = (30/30000)*1000000*1001 + (30%30000)*1000000*1001/30000
    // = 0 + 30030000000/30000 = 1001000
    p.pts = 30;
    REQUIRE(p.pts_us() == 1'001'000);
}

TEST_CASE("Packet::pts_us large PTS avoids overflow") {
    Packet p;
    // PTS = 2 hours at 90kHz: 2 * 3600 * 90000 = 648000000
    p.pts = 648'000'000;
    p.time_base_num = 1;
    p.time_base_den = 90000;
    // Expected: 2 hours = 7200 seconds = 7200000000 us
    REQUIRE(p.pts_us() == 7'200'000'000LL);
}

TEST_CASE("Packet::pts_us very large PTS") {
    Packet p;
    // 24 hours at 90kHz: 24 * 3600 * 90000 = 7776000000
    p.pts = 7'776'000'000LL;
    p.time_base_num = 1;
    p.time_base_den = 90000;
    // Expected: 86400 seconds = 86400000000 us
    REQUIRE(p.pts_us() == 86'400'000'000LL);
}

TEST_CASE("Packet::pts_us fractional result") {
    Packet p;
    p.pts = 1; // 1 tick at 90kHz
    p.time_base_num = 1;
    p.time_base_den = 90000;
    // Expected: 1/90000 * 1000000 = 11.111... -> integer truncation = 11
    REQUIRE(p.pts_us() == 11);
}
