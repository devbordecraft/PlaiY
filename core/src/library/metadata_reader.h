#pragma once

#include "testplayer/types.h"
#include <string>

namespace tp {

class MetadataReader {
public:
    // Probe a media file and fill in a MediaItem with metadata.
    static bool read(const std::string& path, MediaItem& out);
};

} // namespace tp
