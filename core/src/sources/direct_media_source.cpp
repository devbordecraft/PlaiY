#include "direct_media_source.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avio.h>
}

#include <algorithm>
#include <cctype>

static constexpr const char* TAG = "DirectSource";

namespace py {

namespace {

std::string trim_suffix_after_delimiters(const std::string& uri) {
    size_t end = uri.find_first_of("?#");
    if (end == std::string::npos) return uri;
    return uri.substr(0, end);
}

std::string lowercase(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

} // namespace

DirectMediaSource::DirectMediaSource(SourceConfig config, UriProbe probe)
    : config_(std::move(config))
    , probe_(std::move(probe)) {}

bool DirectMediaSource::is_runtime_supported(MediaSourceType type) {
    if (!is_direct_media_type(type)) {
        return false;
    }

    return !default_probe(type, probe_uri_for_type(type));
}

Error DirectMediaSource::connect() {
    if (!is_direct_media_type(config_.type)) {
        return {ErrorCode::InvalidArgument, "Unsupported direct media source type"};
    }

    if (config_.base_uri.empty()) {
        return {ErrorCode::InvalidArgument, "Source URI is required"};
    }

    std::string scheme = uri_scheme(config_.base_uri);
    if (config_.type == MediaSourceType::HTTP) {
        if (scheme != "http" && scheme != "https") {
            return {ErrorCode::InvalidArgument,
                    "HTTP source requires an http:// or https:// media URL"};
        }
    } else if (config_.type == MediaSourceType::NFS) {
        if (scheme != "nfs") {
            return {ErrorCode::InvalidArgument,
                    "NFS source requires an nfs:// media URL"};
        }
    }

    Error err = probe_ ? probe_(config_.type, config_.base_uri)
                       : default_probe(config_.type, config_.base_uri);
    if (err) {
        connected_ = false;
        return err;
    }

    connected_ = true;
    PY_LOG_INFO(TAG, "Connected direct media source: %s (%s)",
                config_.display_name.c_str(), config_.base_uri.c_str());
    return Error::Ok();
}

void DirectMediaSource::disconnect() {
    connected_ = false;
}

bool DirectMediaSource::is_connected() const {
    return connected_;
}

Error DirectMediaSource::list_directory(const std::string& relative_path,
                                        std::vector<SourceEntry>& entries) {
    entries.clear();

    if (!connected_) {
        return {ErrorCode::InvalidState, "Source not connected"};
    }

    if (!relative_path.empty()) {
        return {ErrorCode::InvalidArgument, "Direct media sources do not support subdirectories"};
    }

    SourceEntry entry;
    entry.name = entry_name_for_config(config_);
    entry.uri = config_.base_uri;
    entry.is_directory = false;
    entry.size = 0;
    entries.push_back(std::move(entry));
    return Error::Ok();
}

std::string DirectMediaSource::playable_path(const SourceEntry& entry) const {
    return entry.is_directory ? "" : config_.base_uri;
}

Error DirectMediaSource::default_probe(MediaSourceType type, const std::string& uri) {
    const char* protocol = avio_find_protocol_name(uri.c_str());
    if (!protocol) {
        return {ErrorCode::UnsupportedFormat, "Unsupported media URL protocol"};
    }

    std::string protocol_name = lowercase(protocol);
    if (type == MediaSourceType::HTTP &&
        protocol_name != "http" && protocol_name != "https") {
        return {ErrorCode::UnsupportedFormat,
                "FFmpeg build does not support http(s) media URLs"};
    }

    if (type == MediaSourceType::NFS && protocol_name != "nfs") {
        return {ErrorCode::UnsupportedFormat,
                "FFmpeg build does not support nfs:// media URLs"};
    }

    return Error::Ok();
}

std::string DirectMediaSource::probe_uri_for_type(MediaSourceType type) {
    switch (type) {
    case MediaSourceType::HTTP:
        return "http://example.com/media.mp4";
    case MediaSourceType::NFS:
        return "nfs://example.com/export/media.mkv";
    default:
        return "";
    }
}

std::string DirectMediaSource::uri_scheme(const std::string& uri) {
    size_t pos = uri.find("://");
    if (pos == std::string::npos) return "";
    return lowercase(uri.substr(0, pos));
}

std::string DirectMediaSource::entry_name_for_config(const SourceConfig& config) {
    if (!config.display_name.empty()) {
        return config.display_name;
    }

    std::string leaf = uri_leaf_name(config.base_uri);
    if (!leaf.empty()) {
        return leaf;
    }

    return config.base_uri;
}

std::string DirectMediaSource::uri_leaf_name(const std::string& uri) {
    std::string trimmed = trim_suffix_after_delimiters(uri);
    size_t slash = trimmed.find_last_of('/');
    if (slash != std::string::npos && slash + 1 < trimmed.size()) {
        return trimmed.substr(slash + 1);
    }

    size_t scheme = trimmed.find("://");
    if (scheme != std::string::npos) {
        return trimmed.substr(scheme + 3);
    }

    return trimmed;
}

bool DirectMediaSource::is_direct_media_type(MediaSourceType type) {
    return type == MediaSourceType::HTTP || type == MediaSourceType::NFS;
}

} // namespace py
