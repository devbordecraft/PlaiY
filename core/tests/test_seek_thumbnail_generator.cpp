#include <catch2/catch_test_macros.hpp>

#include "library/seek_thumbnail_generator.h"

TEST_CASE("Seek thumbnail generation mode selects custom renderer only for DV Profile 5") {
    py::TrackInfo track;
    track.type = py::MediaType::Video;

    SECTION("DV Profile 5") {
        track.hdr_metadata.type = py::HDRType::DolbyVision;
        track.dv_profile = 5;
#ifdef __APPLE__
        REQUIRE(py::SeekThumbnailGenerator::select_mode(track) ==
                py::SeekThumbnailGenerator::ThumbnailMode::CustomMetalP5);
#else
        REQUIRE(py::SeekThumbnailGenerator::select_mode(track) ==
                py::SeekThumbnailGenerator::ThumbnailMode::LegacySwscale);
#endif
    }

    SECTION("DV Profile 8") {
        track.hdr_metadata.type = py::HDRType::DolbyVision;
        track.dv_profile = 8;
        REQUIRE(py::SeekThumbnailGenerator::select_mode(track) ==
                py::SeekThumbnailGenerator::ThumbnailMode::LegacySwscale);
    }

    SECTION("HDR10") {
        track.hdr_metadata.type = py::HDRType::HDR10;
        track.dv_profile = 0;
        REQUIRE(py::SeekThumbnailGenerator::select_mode(track) ==
                py::SeekThumbnailGenerator::ThumbnailMode::LegacySwscale);
    }

    SECTION("non-video track") {
        track.type = py::MediaType::Audio;
        track.hdr_metadata.type = py::HDRType::DolbyVision;
        track.dv_profile = 5;
        REQUIRE(py::SeekThumbnailGenerator::select_mode(track) ==
                py::SeekThumbnailGenerator::ThumbnailMode::LegacySwscale);
    }
}
