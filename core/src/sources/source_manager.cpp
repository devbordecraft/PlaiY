#include "plaiy/source_manager.h"
#include "plaiy/logger.h"
#include "direct_media_source.h"
#include "local_media_source.h"
#include "plex_media_source.h"

#ifdef __APPLE__
#include <TargetConditionals.h>
#include "ns_http_client.h"
#endif

#if defined(__APPLE__) && !TARGET_OS_TV
#include "smb_media_source.h"
#endif

#include <nlohmann/json.hpp>
#include <algorithm>
#include <vector>

static constexpr const char* TAG = "SourceManager";

using json = nlohmann::json;

namespace py {

// ---- JSON helpers ----

static std::string source_type_to_string(MediaSourceType t) {
    switch (t) {
        case MediaSourceType::Local: return "local";
        case MediaSourceType::SMB:   return "smb";
        case MediaSourceType::NFS:   return "nfs";
        case MediaSourceType::HTTP:  return "http";
        case MediaSourceType::Plex:  return "plex";
    }
    return "unknown";
}

static MediaSourceType source_type_from_string(const std::string& s) {
    if (s == "local") return MediaSourceType::Local;
    if (s == "smb")   return MediaSourceType::SMB;
    if (s == "nfs")   return MediaSourceType::NFS;
    if (s == "http")  return MediaSourceType::HTTP;
    if (s == "plex")  return MediaSourceType::Plex;
    return MediaSourceType::Local;
}

static json config_to_json(const SourceConfig& cfg) {
    json j = {
        {"source_id", cfg.source_id},
        {"display_name", cfg.display_name},
        {"type", source_type_to_string(cfg.type)},
        {"base_uri", cfg.base_uri},
        {"username", cfg.username},
        // password intentionally excluded from serialization
    };
    if (!cfg.auth_token.empty()) {
        j["auth_token"] = cfg.auth_token;
    }
    return j;
}

static SourceConfig config_from_json(const json& j) {
    SourceConfig cfg;
    cfg.source_id = j.value("source_id", "");
    cfg.display_name = j.value("display_name", "");
    cfg.type = source_type_from_string(j.value("type", "local"));
    cfg.base_uri = j.value("base_uri", "");
    cfg.username = j.value("username", "");
    cfg.auth_token = j.value("auth_token", "");
    return cfg;
}

// ---- Impl ----

struct SourceManager::Impl {
    std::vector<std::unique_ptr<IMediaSource>> sources;

    // Cached JSON strings for bridge return (valid until next mutation)
    std::string cached_configs_json;
    std::string cached_listing_json;
    std::string cached_config_json;
    std::string cached_playable_path;
};

SourceManager::SourceManager() : impl_(std::make_unique<Impl>()) {}
SourceManager::~SourceManager() = default;

Error SourceManager::add_source(const SourceConfig& config) {
    if (config.source_id.empty()) {
        return {ErrorCode::InvalidArgument, "source_id is required"};
    }
    // Check for duplicate
    for (const auto& s : impl_->sources) {
        if (s->config().source_id == config.source_id) {
            return {ErrorCode::InvalidArgument, "Source already exists: " + config.source_id};
        }
    }

    auto source = create_source(config);
    if (!source) {
        return {ErrorCode::Unknown, "Unsupported source type"};
    }

    PY_LOG_INFO(TAG, "Added source: %s (%s) type=%s",
                config.display_name.c_str(), config.source_id.c_str(),
                source_type_to_string(config.type).c_str());

    impl_->sources.push_back(std::move(source));
    return Error::Ok();
}

void SourceManager::remove_source(const std::string& source_id) {
    auto it = std::find_if(impl_->sources.begin(), impl_->sources.end(),
                           [&](const auto& s) { return s->config().source_id == source_id; });
    if (it != impl_->sources.end()) {
        if ((*it)->is_connected()) {
            (*it)->disconnect();
        }
        PY_LOG_INFO(TAG, "Removed source: %s", source_id.c_str());
        impl_->sources.erase(it);
    }
}

int SourceManager::source_count() const {
    return static_cast<int>(impl_->sources.size());
}

IMediaSource* SourceManager::source_at(int index) {
    if (index < 0 || index >= static_cast<int>(impl_->sources.size())) return nullptr;
    return impl_->sources[static_cast<size_t>(index)].get();
}

IMediaSource* SourceManager::source_by_id(const std::string& source_id) {
    for (auto& s : impl_->sources) {
        if (s->config().source_id == source_id) return s.get();
    }
    return nullptr;
}

std::unique_ptr<IMediaSource> SourceManager::create_source(SourceConfig config) {
    switch (config.type) {
        case MediaSourceType::Local:
            return std::make_unique<LocalMediaSource>(std::move(config));
        case MediaSourceType::NFS:
        case MediaSourceType::HTTP:
            return std::make_unique<DirectMediaSource>(std::move(config));
#if defined(__APPLE__) && !TARGET_OS_TV
        case MediaSourceType::SMB:
            return std::make_unique<SMBMediaSource>(std::move(config));
#endif
        case MediaSourceType::Plex: {
#if defined(__APPLE__)
            auto http = std::make_unique<NSHttpClient>();
            return std::make_unique<PlexMediaSource>(std::move(config), std::move(http));
#else
            PY_LOG_WARN(TAG, "Plex not yet supported on this platform");
            return nullptr;
#endif
        }
        default:
            PY_LOG_WARN(TAG, "Unsupported source type: %s",
                        source_type_to_string(config.type).c_str());
            return nullptr;
    }
}

std::string SourceManager::configs_json() const {
    json arr = json::array();
    for (const auto& s : impl_->sources) {
        arr.push_back(config_to_json(s->config()));
    }
    return arr.dump();
}

Error SourceManager::load_configs_json(const std::string& json_str) {
    try {
        auto arr = json::parse(json_str);
        if (!arr.is_array()) {
            return {ErrorCode::InvalidArgument, "Expected JSON array"};
        }
        for (const auto& j : arr) {
            SourceConfig cfg = config_from_json(j);
            if (!cfg.source_id.empty()) {
                add_source(cfg);
            }
        }
        PY_LOG_INFO(TAG, "Loaded %zu source configs", arr.size());
        return Error::Ok();
    } catch (const json::exception& e) {
        return {ErrorCode::InvalidArgument, std::string("JSON parse error: ") + e.what()};
    }
}

} // namespace py
