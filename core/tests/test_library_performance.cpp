#include <catch2/catch_test_macros.hpp>

#include "plaiy/media_library.h"
#include "plaiy/types.h"
#include "plaiy_c.h"

#include <array>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <string>
#include <system_error>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {

struct TempDirGuard {
    fs::path path;

    explicit TempDirGuard(fs::path p) : path(std::move(p)) {}

    ~TempDirGuard() {
        std::error_code ec;
        if (path.empty()) return;

        for (auto it = fs::recursive_directory_iterator(
                 path, fs::directory_options::skip_permission_denied, ec);
             it != fs::recursive_directory_iterator();
             it.increment(ec)) {
            fs::permissions(it->path(), fs::perms::owner_all, fs::perm_options::replace, ec);
            ec.clear();
        }
        fs::permissions(path, fs::perms::owner_all, fs::perm_options::replace, ec);
        ec.clear();
        fs::remove_all(path, ec);
    }
};

fs::path unique_temp_path(const std::string& suffix) {
    return fs::temp_directory_path() / fs::path("plaiy_perf_" + suffix + "_" + std::to_string(::getpid()));
}

void write_le16(std::ofstream& out, uint16_t value) {
    char bytes[2] = {
        static_cast<char>(value & 0xff),
        static_cast<char>((value >> 8) & 0xff),
    };
    out.write(bytes, sizeof(bytes));
}

void write_le32(std::ofstream& out, uint32_t value) {
    char bytes[4] = {
        static_cast<char>(value & 0xff),
        static_cast<char>((value >> 8) & 0xff),
        static_cast<char>((value >> 16) & 0xff),
        static_cast<char>((value >> 24) & 0xff),
    };
    out.write(bytes, sizeof(bytes));
}

void write_test_wav(const fs::path& path, int sample_count = 128) {
    constexpr uint16_t channels = 1;
    constexpr uint32_t sample_rate = 8000;
    constexpr uint16_t bits_per_sample = 16;
    const uint32_t data_size = static_cast<uint32_t>(sample_count * channels * (bits_per_sample / 8));
    const uint32_t riff_size = 36 + data_size;
    const uint32_t byte_rate = sample_rate * channels * (bits_per_sample / 8);
    const uint16_t block_align = channels * (bits_per_sample / 8);

    std::ofstream out(path, std::ios::binary | std::ios::trunc);
    REQUIRE(out.good());

    out.write("RIFF", 4);
    write_le32(out, riff_size);
    out.write("WAVE", 4);
    out.write("fmt ", 4);
    write_le32(out, 16);
    write_le16(out, 1);
    write_le16(out, channels);
    write_le32(out, sample_rate);
    write_le32(out, byte_rate);
    write_le16(out, block_align);
    write_le16(out, bits_per_sample);
    out.write("data", 4);
    write_le32(out, data_size);

    for (int i = 0; i < sample_count; i++) {
        write_le16(out, static_cast<uint16_t>(0));
    }
}

} // namespace

TEST_CASE("MediaLibrary reuses cached metadata for unchanged files") {
    fs::path dir = unique_temp_path("cache_hit");
    TempDirGuard guard(dir);

    std::error_code ec;
    fs::create_directories(dir, ec);
    REQUIRE_FALSE(ec);

    fs::path file = dir / "cached_clip.mp4";
    write_test_wav(file);

    py::MediaLibrary library;
    REQUIRE(library.add_folder(dir.string()).ok());
    REQUIRE(library.item_count() == 1);
    REQUIRE(library.item_at(0) != nullptr);
    REQUIRE(library.item_at(0)->title == "cached_clip");

    library.clear();

    fs::permissions(file, fs::perms::none, fs::perm_options::replace, ec);
    REQUIRE_FALSE(ec);

    REQUIRE(library.add_folder(dir.string()).ok());
    REQUIRE(library.item_count() == 1);
    REQUIRE(library.item_at(0) != nullptr);
    REQUIRE(library.item_at(0)->title == "cached_clip");
}

TEST_CASE("MediaLibrary invalidates cached metadata when file identity changes") {
    fs::path dir = unique_temp_path("cache_invalidate");
    TempDirGuard guard(dir);

    std::error_code ec;
    fs::create_directories(dir, ec);
    REQUIRE_FALSE(ec);

    fs::path file = dir / "clip.mp4";
    write_test_wav(file);

    py::MediaLibrary library;
    REQUIRE(library.add_folder(dir.string()).ok());
    REQUIRE(library.item_count() == 1);

    library.clear();

    {
        std::ofstream out(file, std::ios::binary | std::ios::trunc);
        REQUIRE(out.good());
        out << "not-a-media-file";
    }

    REQUIRE(library.add_folder(dir.string()).ok());
    REQUIRE(library.item_count() == 0);
}

TEST_CASE("MediaLibrary keeps sorted output with parallel metadata workers") {
    fs::path dir = unique_temp_path("sorted_scan");
    TempDirGuard guard(dir);

    std::error_code ec;
    fs::create_directories(dir, ec);
    REQUIRE_FALSE(ec);

    write_test_wav(dir / "b_title.mp4");
    write_test_wav(dir / "a_title.mp4");
    write_test_wav(dir / "c_title.mp4");

    py::MediaLibrary library;
    REQUIRE(library.add_folder(dir.string()).ok());
    REQUIRE(library.item_count() == 3);
    REQUIRE(library.item_at(0) != nullptr);
    REQUIRE(library.item_at(1) != nullptr);
    REQUIRE(library.item_at(2) != nullptr);
    REQUIRE(library.item_at(0)->title == "a_title");
    REQUIRE(library.item_at(1)->title == "b_title");
    REQUIRE(library.item_at(2)->title == "c_title");
}

TEST_CASE("Dolby Vision reshape fingerprint is stable and changes with LUT data") {
    py::VideoFrame a;
    a.dovi_color.has_reshaping = true;
    a.dovi_color.reshape_lut[0][0] = 0.25f;
    a.dovi_color.reshape_lut[1][128] = 0.5f;
    a.dovi_color.reshape_lut[2][1023] = 1.0f;

    py::VideoFrame b;
    b.dovi_color.has_reshaping = true;
    b.dovi_color.reshape_lut[0][0] = 0.25f;
    b.dovi_color.reshape_lut[1][128] = 0.5f;
    b.dovi_color.reshape_lut[2][1023] = 1.0f;

    const uint64_t hash_a = py_player_frame_dovi_reshape_fingerprint(&a);
    const uint64_t hash_b = py_player_frame_dovi_reshape_fingerprint(&b);
    REQUIRE(hash_a != 0);
    REQUIRE(hash_a == hash_b);

    b.dovi_color.reshape_lut[1][128] = 0.75f;
    REQUIRE(py_player_frame_dovi_reshape_fingerprint(&b) != hash_a);
}
