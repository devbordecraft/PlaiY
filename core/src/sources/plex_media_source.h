#pragma once

#include "plaiy/media_source.h"
#include "http/http_client.h"
#include <map>
#include <memory>
#include <string>
#include <unordered_map>

namespace py {

class PlexMediaSource : public IMediaSource {
public:
    PlexMediaSource(SourceConfig config, std::unique_ptr<IHttpClient> http_client);
    ~PlexMediaSource() override;

    MediaSourceType type() const override { return MediaSourceType::Plex; }
    const SourceConfig& config() const override { return config_; }

    Error connect() override;
    void disconnect() override;
    bool is_connected() const override;

    Error list_directory(const std::string& relative_path,
                         std::vector<SourceEntry>& entries) override;

    std::string playable_path(const SourceEntry& entry) const override;

private:
    struct CachedPlayableItem {
        std::string part_id;
        std::string metadata_key;
        std::string rating_key;
    };

    SourceConfig config_;
    std::unique_ptr<IHttpClient> http_;
    std::string auth_token_;
    std::string server_name_;
    bool connected_ = false;
    std::string client_id_;
    mutable std::unordered_map<std::string, CachedPlayableItem> playable_items_;

    // Build standard Plex headers for API requests
    std::map<std::string, std::string> plex_headers() const;

    // Build full API URL with token
    std::string api_url(const std::string& path) const;
    std::string media_url(const std::string& path) const;

    // Fetch and parse a JSON response from the Plex API
    Error fetch_json(const std::string& api_path, std::string& body);

    // Navigation handlers
    Error list_sections(std::vector<SourceEntry>& entries);
    Error list_api_path(const std::string& api_path,
                        std::vector<SourceEntry>& entries);

    // Exchange plex.tv username/password for an auth token
    Error authenticate_plex_tv();
    Error resolve_pms_access_token(const std::string& user_token,
                                   std::string& server_token);
    Error load_playable_item(const std::string& metadata_key,
                             CachedPlayableItem& item) const;
};

} // namespace py
