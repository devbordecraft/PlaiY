#include <catch2/catch_test_macros.hpp>
#include "playback_generation.h"

using namespace py;

TEST_CASE("PlaybackGeneration defaults to epoch 1") {
    PlaybackGeneration generation;

    REQUIRE(generation.current() == 1);
    REQUIRE(generation.matches(1));
    REQUIRE_FALSE(generation.matches(0));
}

TEST_CASE("PlaybackGeneration advance invalidates captured read epochs") {
    PlaybackGeneration generation;

    uint64_t captured = generation.capture_for_read();
    REQUIRE(captured == 1);

    uint64_t next = generation.advance();
    REQUIRE(next == 2);
    REQUIRE_FALSE(generation.matches(captured));
    REQUIRE(generation.matches(next));
}

TEST_CASE("PlaybackGeneration reset restores the initial epoch") {
    PlaybackGeneration generation;

    generation.advance();
    generation.advance();
    generation.reset();

    REQUIRE(generation.current() == 1);
    REQUIRE(generation.matches(1));
}
