#include "srt_parser.h"
#include "testplayer/logger.h"

#include <algorithm>
#include <fstream>
#include <sstream>

static constexpr const char* TAG = "SrtParser";

namespace tp {

bool SrtParser::parse_file(const std::string& path) {
    std::ifstream file(path);
    if (!file.is_open()) {
        TP_LOG_ERROR(TAG, "Cannot open SRT file: %s", path.c_str());
        return false;
    }
    std::string content((std::istreambuf_iterator<char>(file)),
                         std::istreambuf_iterator<char>());
    return parse_string(content);
}

bool SrtParser::parse_string(const std::string& content) {
    entries_.clear();
    std::istringstream stream(content);
    std::string line;

    enum State { EXPECT_INDEX, EXPECT_TIME, EXPECT_TEXT };
    State state = EXPECT_INDEX;
    Entry current;

    while (std::getline(stream, line)) {
        // Remove carriage return
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }

        switch (state) {
            case EXPECT_INDEX:
                if (line.empty()) continue;
                try {
                    current.index = std::stoi(line);
                    state = EXPECT_TIME;
                } catch (...) {
                    // Skip invalid index
                }
                break;

            case EXPECT_TIME: {
                auto arrow = line.find("-->");
                if (arrow == std::string::npos) break;

                std::string start_str = line.substr(0, arrow);
                std::string end_str = line.substr(arrow + 3);

                // Trim whitespace
                while (!start_str.empty() && start_str.back() == ' ') start_str.pop_back();
                while (!end_str.empty() && end_str.front() == ' ') end_str.erase(0, 1);

                current.start_us = parse_timestamp(start_str);
                current.end_us = parse_timestamp(end_str);
                current.text.clear();
                state = EXPECT_TEXT;
                break;
            }

            case EXPECT_TEXT:
                if (line.empty()) {
                    if (!current.text.empty()) {
                        entries_.push_back(current);
                        current = {};
                    }
                    state = EXPECT_INDEX;
                } else {
                    if (!current.text.empty()) current.text += '\n';
                    current.text += line;
                }
                break;
        }
    }

    // Don't forget last entry
    if (state == EXPECT_TEXT && !current.text.empty()) {
        entries_.push_back(current);
    }

    // Sort by start time
    std::sort(entries_.begin(), entries_.end(),
              [](const Entry& a, const Entry& b) { return a.start_us < b.start_us; });

    TP_LOG_INFO(TAG, "Parsed %zu SRT entries", entries_.size());
    return !entries_.empty();
}

SubtitleFrame SrtParser::get_frame_at(int64_t timestamp_us) const {
    SubtitleFrame frame;

    for (const auto& entry : entries_) {
        if (timestamp_us >= entry.start_us && timestamp_us < entry.end_us) {
            frame.start_us = entry.start_us;
            frame.end_us = entry.end_us;
            frame.text = entry.text;
            frame.is_text = true;
            return frame;
        }
        if (entry.start_us > timestamp_us) break; // entries are sorted
    }

    return frame;
}

int64_t SrtParser::parse_timestamp(const std::string& ts) {
    // Format: HH:MM:SS,mmm or HH:MM:SS.mmm
    int h = 0, m = 0, s = 0, ms = 0;
    char sep;

    std::string cleaned = ts;
    // Replace comma with dot for consistent parsing
    for (auto& c : cleaned) {
        if (c == ',') c = '.';
    }

    if (sscanf(cleaned.c_str(), "%d:%d:%d.%d", &h, &m, &s, &ms) < 4) {
        return 0;
    }

    return (static_cast<int64_t>(h) * 3600 +
            static_cast<int64_t>(m) * 60 +
            static_cast<int64_t>(s)) * 1000000LL +
           static_cast<int64_t>(ms) * 1000LL;
}

} // namespace tp
