#include "plaiy/media_library.h"
#include "plaiy/logger.h"
#include "metadata_reader.h"

#include <nlohmann/json.hpp>

#include <algorithm>
#include <filesystem>
#include <fstream>
#include <unordered_set>

static constexpr const char* TAG = "MediaLibrary";

namespace fs = std::filesystem;

namespace py {

static const std::unordered_set<std::string> MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov",
    ".wmv", ".flv", ".webm", ".m2ts", ".mpg", ".mpeg",
};

struct MediaLibrary::Impl {
    std::vector<MediaItem> items;
};

MediaLibrary::MediaLibrary() : impl_(std::make_unique<Impl>()) {}
MediaLibrary::~MediaLibrary() = default;

Error MediaLibrary::add_folder(const std::string& path) {
    if (!fs::exists(path) || !fs::is_directory(path)) {
        return {ErrorCode::FileNotFound, "Directory not found: " + path};
    }

    int added = 0;
    for (const auto& entry : fs::recursive_directory_iterator(path,
             fs::directory_options::skip_permission_denied)) {
        if (!entry.is_regular_file()) continue;

        std::string ext = entry.path().extension().string();
        for (auto& c : ext) c = static_cast<char>(tolower(c));

        if (MEDIA_EXTENSIONS.count(ext) == 0) continue;

        MediaItem item;
        if (MetadataReader::read(entry.path().string(), item)) {
            impl_->items.push_back(std::move(item));
            added++;
        }
    }

    // Sort by title
    std::sort(impl_->items.begin(), impl_->items.end(),
              [](const MediaItem& a, const MediaItem& b) {
                  return a.title < b.title;
              });

    PY_LOG_INFO(TAG, "Scanned %s: %d media files found", path.c_str(), added);
    return Error::Ok();
}

const std::vector<MediaItem>& MediaLibrary::items() const {
    return impl_->items;
}

int MediaLibrary::item_count() const {
    return static_cast<int>(impl_->items.size());
}

const MediaItem* MediaLibrary::item_at(int index) const {
    if (index < 0 || index >= static_cast<int>(impl_->items.size())) return nullptr;
    return &impl_->items[index];
}

Error MediaLibrary::save(const std::string& path) {
    using json = nlohmann::json;

    json arr = json::array();
    for (const auto& item : impl_->items) {
        json j;
        j["file_path"] = item.file_path;
        j["title"] = item.title;
        j["container_format"] = item.container_format;
        j["duration_us"] = item.duration_us;
        j["video_width"] = item.video_width;
        j["video_height"] = item.video_height;
        j["video_codec"] = item.video_codec;
        j["audio_codec"] = item.audio_codec;
        j["audio_channels"] = item.audio_channels;
        j["hdr_type"] = static_cast<int>(item.hdr_type);
        j["file_size"] = item.file_size;
        j["audio_track_count"] = item.audio_track_count;
        j["subtitle_track_count"] = item.subtitle_track_count;
        arr.push_back(j);
    }

    std::ofstream file(path);
    if (!file.is_open()) {
        return {ErrorCode::LibraryError, "Cannot write library file: " + path};
    }
    file << arr.dump(2);
    return Error::Ok();
}

Error MediaLibrary::load(const std::string& path) {
    using json = nlohmann::json;

    std::ifstream file(path);
    if (!file.is_open()) {
        return {ErrorCode::FileNotFound, "Library file not found: " + path};
    }

    try {
        json arr = json::parse(file);
        impl_->items.clear();

        for (const auto& j : arr) {
            MediaItem item;
            item.file_path = j.value("file_path", "");
            item.title = j.value("title", "");
            item.container_format = j.value("container_format", "");
            item.duration_us = j.value("duration_us", int64_t(0));
            item.video_width = j.value("video_width", 0);
            item.video_height = j.value("video_height", 0);
            item.video_codec = j.value("video_codec", "");
            item.audio_codec = j.value("audio_codec", "");
            item.audio_channels = j.value("audio_channels", 0);
            item.hdr_type = static_cast<HDRType>(j.value("hdr_type", 0));
            item.file_size = j.value("file_size", int64_t(0));
            item.audio_track_count = j.value("audio_track_count", 0);
            item.subtitle_track_count = j.value("subtitle_track_count", 0);
            impl_->items.push_back(std::move(item));
        }
    } catch (const json::exception& e) {
        return {ErrorCode::LibraryError, std::string("JSON parse error: ") + e.what()};
    }

    return Error::Ok();
}

void MediaLibrary::clear() {
    impl_->items.clear();
}

} // namespace py
