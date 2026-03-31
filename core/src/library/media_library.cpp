#include "plaiy/media_library.h"
#include "plaiy/logger.h"
#include "metadata_reader.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <filesystem>
#include <mutex>
#include <thread>
#include <unordered_map>
#include <unordered_set>

static constexpr const char* TAG = "MediaLibrary";

namespace fs = std::filesystem;

namespace py {

namespace {

static const std::unordered_set<std::string> MEDIA_EXTENSIONS = {
    ".mkv", ".mp4", ".avi", ".ts", ".m4v", ".mov",
    ".wmv", ".flv", ".webm", ".m2ts", ".mpg", ".mpeg",
};

struct CacheKey {
    std::string canonical_path;
    int64_t file_size = 0;
    int64_t mtime_ns = 0;

    bool operator==(const CacheKey& other) const {
        return canonical_path == other.canonical_path &&
               file_size == other.file_size &&
               mtime_ns == other.mtime_ns;
    }
};

struct CacheKeyHash {
    size_t operator()(const CacheKey& key) const {
        size_t h1 = std::hash<std::string>{}(key.canonical_path);
        size_t h2 = std::hash<int64_t>{}(key.file_size);
        size_t h3 = std::hash<int64_t>{}(key.mtime_ns);
        return h1 ^ (h2 << 1) ^ (h3 << 7);
    }
};

struct CandidateFile {
    std::string path;
    CacheKey key;
};

std::string normalize_path(const fs::path& path) {
    std::error_code ec;
    fs::path canonical = fs::weakly_canonical(path, ec);
    if (ec) {
        ec.clear();
        canonical = fs::absolute(path, ec);
    }
    if (ec) return path.lexically_normal().string();
    return canonical.lexically_normal().string();
}

int64_t file_mtime_ns(const fs::directory_entry& entry) {
    std::error_code ec;
    auto mtime = entry.last_write_time(ec);
    if (ec) return 0;
    return static_cast<int64_t>(mtime.time_since_epoch().count());
}

std::string lowercase_extension(const fs::path& path) {
    std::string ext = path.extension().string();
    for (char& c : ext) {
        c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    return ext;
}

bool path_is_within_root(const std::string& path, const std::string& root) {
    if (path == root) return true;
    if (path.size() <= root.size()) return false;
    if (path.compare(0, root.size(), root) != 0) return false;
    char next = path[root.size()];
    return next == fs::path::preferred_separator || next == '/';
}

size_t metadata_worker_count(size_t candidate_count) {
    if (candidate_count <= 1) return candidate_count;
    unsigned hw = std::thread::hardware_concurrency();
    size_t workers = hw == 0 ? 2u : static_cast<size_t>(hw);
    workers = std::max<size_t>(2, workers);
    workers = std::min<size_t>(6, workers);
    return std::min(workers, candidate_count);
}

} // namespace

struct MediaLibrary::Impl {
    std::vector<MediaItem> items;
    std::vector<std::string> folders;
    std::unordered_map<CacheKey, MediaItem, CacheKeyHash> metadata_cache;
    std::mutex cache_mutex;
};

MediaLibrary::MediaLibrary() : impl_(std::make_unique<Impl>()) {}
MediaLibrary::~MediaLibrary() = default;

Error MediaLibrary::add_folder(const std::string& path) {
    std::error_code ec;
    bool exists = fs::exists(path, ec);
    if (ec || !exists || !fs::is_directory(path, ec)) {
        return {ErrorCode::FileNotFound, "Directory not found: " + path};
    }

    impl_->folders.push_back(path);

    std::string canonical_root = normalize_path(path);
    std::vector<CandidateFile> candidates;
    std::unordered_map<std::string, CacheKey> current_keys_by_path;

    fs::recursive_directory_iterator it(path, fs::directory_options::skip_permission_denied, ec);
    fs::recursive_directory_iterator end;
    if (ec) {
        return {ErrorCode::FileNotFound, "Directory not found: " + path};
    }

    for (; it != end; it.increment(ec)) {
        if (ec) {
            ec.clear();
            continue;
        }

        const auto& entry = *it;
        if (!entry.is_regular_file(ec)) {
            ec.clear();
            continue;
        }

        if (MEDIA_EXTENSIONS.count(lowercase_extension(entry.path())) == 0) continue;

        std::error_code file_ec;
        int64_t file_size = static_cast<int64_t>(entry.file_size(file_ec));
        if (file_ec) {
            file_ec.clear();
            continue;
        }

        CacheKey key{
            .canonical_path = normalize_path(entry.path()),
            .file_size = file_size,
            .mtime_ns = file_mtime_ns(entry),
        };
        current_keys_by_path[key.canonical_path] = key;
        candidates.push_back(CandidateFile{
            .path = entry.path().string(),
            .key = std::move(key),
        });
    }

    size_t worker_count = metadata_worker_count(candidates.size());
    std::vector<std::vector<MediaItem>> worker_results(worker_count == 0 ? 1 : worker_count);
    std::atomic<size_t> next_index{0};

    auto process_candidate = [&](size_t worker_index) {
        std::vector<MediaItem>& local = worker_results[worker_index];

        while (true) {
            size_t candidate_index = next_index.fetch_add(1, std::memory_order_relaxed);
            if (candidate_index >= candidates.size()) break;

            const CandidateFile& candidate = candidates[candidate_index];
            MediaItem item;
            bool cache_hit = false;

            {
                std::lock_guard lock(impl_->cache_mutex);
                auto it = impl_->metadata_cache.find(candidate.key);
                if (it != impl_->metadata_cache.end()) {
                    item = it->second;
                    cache_hit = true;
                }
            }

            if (!cache_hit) {
                if (!MetadataReader::read(candidate.path, item, MetadataReader::ProbeMode::Shallow)) {
                    continue;
                }
                if (MetadataReader::needs_full_probe(item)) {
                    MediaItem full_item;
                    if (MetadataReader::read(candidate.path, full_item, MetadataReader::ProbeMode::Full)) {
                        item = std::move(full_item);
                    }
                }
                item.file_path = candidate.path;
                item.file_size = candidate.key.file_size;

                std::lock_guard lock(impl_->cache_mutex);
                impl_->metadata_cache[candidate.key] = item;
            } else {
                item.file_path = candidate.path;
                item.file_size = candidate.key.file_size;
            }

            local.push_back(std::move(item));
        }
    };

    std::vector<std::thread> workers;
    if (worker_count <= 1) {
        process_candidate(0);
    } else {
        workers.reserve(worker_count);
        for (size_t i = 0; i < worker_count; i++) {
            workers.emplace_back(process_candidate, i);
        }
        for (auto& worker : workers) {
            worker.join();
        }
    }

    int added = 0;
    for (auto& local_items : worker_results) {
        added += static_cast<int>(local_items.size());
        for (auto& item : local_items) {
            impl_->items.push_back(std::move(item));
        }
    }

    {
        std::lock_guard lock(impl_->cache_mutex);
        for (auto it_cache = impl_->metadata_cache.begin(); it_cache != impl_->metadata_cache.end(); ) {
            auto current = current_keys_by_path.find(it_cache->first.canonical_path);
            if (current != current_keys_by_path.end() && !(it_cache->first == current->second)) {
                it_cache = impl_->metadata_cache.erase(it_cache);
                continue;
            }
            if (current == current_keys_by_path.end() &&
                path_is_within_root(it_cache->first.canonical_path, canonical_root)) {
                it_cache = impl_->metadata_cache.erase(it_cache);
                continue;
            }
            ++it_cache;
        }
    }

    std::sort(impl_->items.begin(), impl_->items.end(),
              [](const MediaItem& a, const MediaItem& b) {
                  return a.title < b.title;
              });

    PY_LOG_INFO(TAG, "Scanned %s: %d media files found (%zu workers)",
                path.c_str(), added, worker_count == 0 ? 1 : worker_count);
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
    return &impl_->items[static_cast<size_t>(index)];
}

int MediaLibrary::folder_count() const {
    return static_cast<int>(impl_->folders.size());
}

const std::string& MediaLibrary::folder_at(int index) const {
    static const std::string empty;
    if (index < 0 || index >= static_cast<int>(impl_->folders.size())) return empty;
    return impl_->folders[static_cast<size_t>(index)];
}

void MediaLibrary::remove_folder(int index) {
    if (index < 0 || index >= static_cast<int>(impl_->folders.size())) return;
    impl_->folders.erase(impl_->folders.begin() + index);

    impl_->items.clear();
    auto folders = std::move(impl_->folders);
    for (const auto& folder : folders) {
        add_folder(folder);
    }
}

void MediaLibrary::clear() {
    impl_->items.clear();
    impl_->folders.clear();
}

} // namespace py
