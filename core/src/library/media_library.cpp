#include "plaiy/media_library.h"
#include "plaiy/logger.h"
#include "metadata_reader.h"

#include <algorithm>
#include <filesystem>
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

void MediaLibrary::clear() {
    impl_->items.clear();
}

} // namespace py
