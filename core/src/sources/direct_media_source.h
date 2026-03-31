#pragma once

#include "plaiy/media_source.h"

#include <functional>

namespace py {

class DirectMediaSource : public IMediaSource {
public:
    using UriProbe = std::function<Error(MediaSourceType type, const std::string& uri)>;

    explicit DirectMediaSource(SourceConfig config, UriProbe probe = {});

    MediaSourceType type() const override { return config_.type; }
    const SourceConfig& config() const override { return config_; }

    static bool is_runtime_supported(MediaSourceType type);

    Error connect() override;
    void disconnect() override;
    bool is_connected() const override;

    Error list_directory(const std::string& relative_path,
                         std::vector<SourceEntry>& entries) override;

    std::string playable_path(const SourceEntry& entry) const override;

private:
    static Error default_probe(MediaSourceType type, const std::string& uri);
    static std::string probe_uri_for_type(MediaSourceType type);
    static std::string uri_scheme(const std::string& uri);
    static std::string entry_name_for_config(const SourceConfig& config);
    static std::string uri_leaf_name(const std::string& uri);
    static bool is_direct_media_type(MediaSourceType type);

    SourceConfig config_;
    UriProbe probe_;
    bool connected_ = false;
};

} // namespace py
