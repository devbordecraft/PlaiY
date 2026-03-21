#pragma once

#include "testplayer/types.h"
#include <string>
#include <vector>

namespace tp {

class SrtParser {
public:
    struct Entry {
        int index = 0;
        int64_t start_us = 0;
        int64_t end_us = 0;
        std::string text;
    };

    // Parse an SRT file from disk
    bool parse_file(const std::string& path);

    // Parse SRT content from a string
    bool parse_string(const std::string& content);

    // Get the subtitle text at the given timestamp
    SubtitleFrame get_frame_at(int64_t timestamp_us) const;

    const std::vector<Entry>& entries() const { return entries_; }

private:
    static int64_t parse_timestamp(const std::string& ts);
    std::vector<Entry> entries_;
};

} // namespace tp
