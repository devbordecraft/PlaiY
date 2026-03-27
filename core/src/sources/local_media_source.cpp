#include "local_media_source.h"
#include "plaiy/logger.h"

#include <algorithm>
#include <filesystem>
#include <unordered_set>

static constexpr const char* TAG = "LocalSource";

namespace fs = std::filesystem;

namespace py {

static const std::unordered_set<std::string> MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov",
    ".wmv", ".flv", ".webm", ".m2ts", ".mpg", ".mpeg",
};

LocalMediaSource::LocalMediaSource(SourceConfig config)
    : config_(std::move(config)) {}

Error LocalMediaSource::connect() {
    if (!fs::exists(config_.base_uri) || !fs::is_directory(config_.base_uri)) {
        return {ErrorCode::FileNotFound, "Directory not found: " + config_.base_uri};
    }
    PY_LOG_INFO(TAG, "Connected: %s (%s)", config_.display_name.c_str(), config_.base_uri.c_str());
    return Error::Ok();
}

void LocalMediaSource::disconnect() {
    // No-op for local filesystem
}

bool LocalMediaSource::is_connected() const {
    return fs::exists(config_.base_uri) && fs::is_directory(config_.base_uri);
}

Error LocalMediaSource::list_directory(const std::string& relative_path,
                                       std::vector<SourceEntry>& entries) {
    entries.clear();

    std::string full_path = config_.base_uri;
    if (!relative_path.empty()) {
        full_path += "/" + relative_path;
    }

    if (!fs::exists(full_path) || !fs::is_directory(full_path)) {
        return {ErrorCode::FileNotFound, "Directory not found: " + full_path};
    }

    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(full_path,
             fs::directory_options::skip_permission_denied, ec)) {
        if (ec) continue;

        std::string name = entry.path().filename().string();

        // Skip hidden files
        if (!name.empty() && name[0] == '.') continue;

        if (entry.is_directory(ec)) {
            SourceEntry se;
            se.name = name;
            se.uri = entry.path().string();
            se.is_directory = true;
            se.size = 0;
            entries.push_back(std::move(se));
        } else if (entry.is_regular_file(ec)) {
            std::string ext = entry.path().extension().string();
            for (auto& c : ext) c = static_cast<char>(tolower(c));

            if (MEDIA_EXTENSIONS.count(ext) == 0) continue;

            SourceEntry se;
            se.name = name;
            se.uri = entry.path().string();
            se.is_directory = false;
            se.size = static_cast<int64_t>(entry.file_size(ec));
            entries.push_back(std::move(se));
        }
    }

    // Sort: directories first, then alphabetical
    std::sort(entries.begin(), entries.end(), [](const SourceEntry& a, const SourceEntry& b) {
        if (a.is_directory != b.is_directory) return a.is_directory > b.is_directory;
        return a.name < b.name;
    });

    PY_LOG_DEBUG(TAG, "Listed %s: %zu entries", full_path.c_str(), entries.size());
    return Error::Ok();
}

std::string LocalMediaSource::playable_path(const SourceEntry& entry) const {
    return entry.uri;
}

} // namespace py
