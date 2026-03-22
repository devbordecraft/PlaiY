#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <string>
#include <vector>

namespace py {

class MediaLibrary {
public:
    MediaLibrary();
    ~MediaLibrary();

    // Scan a folder recursively for media files
    Error add_folder(const std::string& path);

    // Get all discovered items
    const std::vector<MediaItem>& items() const;

    int item_count() const;
    const MediaItem* item_at(int index) const;

    // Serialize/deserialize the library to JSON
    Error save(const std::string& path);
    Error load(const std::string& path);

    void clear();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
