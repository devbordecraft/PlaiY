#include <catch2/catch_test_macros.hpp>

#include <chrono>
#include <filesystem>
#include <fstream>
#include <sstream>

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

TEST_CASE("Seek thumbnail generator reuses a complete on-disk cache manifest") {
    namespace fs = std::filesystem;

    const auto unique = std::to_string(
        std::chrono::steady_clock::now().time_since_epoch().count());
    const fs::path root = fs::temp_directory_path() / ("plaiy-seekthumb-cache-" + unique);
    const fs::path video_path = root / "movie.mkv";
    const fs::path cache_dir = root / "cache";

    fs::create_directories(cache_dir);
    {
        std::ofstream video(video_path);
        video << "not-a-real-video";
    }

    {
        std::ofstream(cache_dir / "thumb_0000.jpg") << "cached";
        std::ofstream(cache_dir / "thumb_0001.jpg") << "cached";
    }

    const auto modified = fs::last_write_time(video_path);
    const auto modified_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(
        modified.time_since_epoch()).count();

    std::ostringstream manifest;
    manifest
        << "{\"video_path\":\"" << video_path.string() << "\","
        << "\"file_size\":" << fs::file_size(video_path) << ","
        << "\"modified_ns\":" << modified_ns << ","
        << "\"interval_seconds\":1,"
        << "\"mode\":\"legacy\","
        << "\"total_count\":2}";
    {
        std::ofstream manifest_file(cache_dir / "manifest.json");
        manifest_file << manifest.str();
    }

    py::SeekThumbnailGenerator generator;
    generator.start(video_path.string(), cache_dir.string(), 1, nullptr);

    REQUIRE(generator.progress() == 100);

    generator.cancel();
    fs::remove_all(root);
}
