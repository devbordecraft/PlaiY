#include <catch2/catch_test_macros.hpp>

#include "plaiy/media_library.h"
#include "sources/local_media_source.h"
#include "library/seek_thumbnail_generator.h"

#include <filesystem>
#include <string>
#include <unistd.h>

namespace fs = std::filesystem;

namespace {

struct TempDirGuard {
    fs::path path;

    explicit TempDirGuard(fs::path p) : path(std::move(p)) {}

    ~TempDirGuard() {
        std::error_code ec;
        if (!path.empty()) {
            fs::permissions(path, fs::perms::owner_all, fs::perm_options::replace, ec);
            ec.clear();
            fs::remove_all(path, ec);
        }
    }
};

fs::path unique_temp_path(const std::string& suffix) {
    return fs::temp_directory_path() / fs::path("plaiy_" + suffix + "_" + std::to_string(::getpid()));
}

} // namespace

TEST_CASE("MediaLibrary add_folder handles inaccessible top-level directory without throwing") {
    fs::path dir = unique_temp_path("library_inaccessible");
    TempDirGuard guard(dir);

    std::error_code ec;
    fs::create_directories(dir, ec);
    REQUIRE_FALSE(ec);
    fs::permissions(dir, fs::perms::none, fs::perm_options::replace, ec);
    REQUIRE_FALSE(ec);

    py::MediaLibrary library;
    py::Error err = py::Error::Ok();
    REQUIRE_NOTHROW(err = library.add_folder(dir.string()));
    (void)err;
}

TEST_CASE("LocalMediaSource connect handles inaccessible directory without throwing") {
    fs::path dir = unique_temp_path("local_source_inaccessible");
    TempDirGuard guard(dir);

    std::error_code ec;
    fs::create_directories(dir, ec);
    REQUIRE_FALSE(ec);
    fs::permissions(dir, fs::perms::none, fs::perm_options::replace, ec);
    REQUIRE_FALSE(ec);

    py::SourceConfig cfg;
    cfg.source_id = "local-test";
    cfg.display_name = "Local Test";
    cfg.type = py::MediaSourceType::Local;
    cfg.base_uri = dir.string();

    py::LocalMediaSource source(cfg);
    py::Error err = py::Error::Ok();
    REQUIRE_NOTHROW(err = source.connect());
    (void)err;
}

TEST_CASE("SeekThumbnailGenerator start handles cache directory creation failure without throwing") {
    fs::path parent = unique_temp_path("thumb_parent");
    TempDirGuard guard(parent);

    std::error_code ec;
    fs::create_directories(parent, ec);
    REQUIRE_FALSE(ec);
    fs::permissions(parent, fs::perms::none, fs::perm_options::replace, ec);
    REQUIRE_FALSE(ec);

    py::SeekThumbnailGenerator generator;
    fs::path cache_dir = parent / "cache";

    REQUIRE_NOTHROW(generator.start("/tmp/nonexistent.mkv", cache_dir.string(), 10));
    generator.cancel();
}
