#pragma once

#include "plaiy/media_source.h"
#include <string>

namespace py {

class SMBMediaSource : public IMediaSource {
public:
    explicit SMBMediaSource(SourceConfig config);
    ~SMBMediaSource() override;

    MediaSourceType type() const override { return MediaSourceType::SMB; }
    const SourceConfig& config() const override { return config_; }

    Error connect() override;
    void disconnect() override;
    bool is_connected() const override;

    Error list_directory(const std::string& relative_path,
                         std::vector<SourceEntry>& entries) override;

    std::string playable_path(const SourceEntry& entry) const override;

private:
    SourceConfig config_;
    std::string mount_path_;   // e.g. "/Volumes/ShareName"
    bool mounted_ = false;
};

} // namespace py
