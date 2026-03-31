#pragma once

#include "plaiy/types.h"
#include <string>

namespace py {

class MetadataReader {
public:
    enum class ProbeMode {
        Shallow,
        Full,
    };

    // Probe a media file and fill in a MediaItem with metadata.
    static bool read(const std::string& path, MediaItem& out,
                     ProbeMode mode = ProbeMode::Full);

    // Returns true when shallow probing should fall back to full stream info.
    static bool needs_full_probe(const MediaItem& item);
};

} // namespace py
