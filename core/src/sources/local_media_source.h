#pragma once

#include "plaiy/media_source.h"

namespace py {

class LocalMediaSource : public IMediaSource {
public:
    explicit LocalMediaSource(SourceConfig config);

    MediaSourceType type() const override { return MediaSourceType::Local; }
    const SourceConfig& config() const override { return config_; }

    Error connect() override;
    void disconnect() override;
    bool is_connected() const override;

    Error list_directory(const std::string& relative_path,
                         std::vector<SourceEntry>& entries) override;

    std::string playable_path(const SourceEntry& entry) const override;

private:
    SourceConfig config_;
};

} // namespace py
