#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace py {

enum class MediaSourceType {
    Local = 0,
    SMB,
    NFS,
    HTTP,
    Plex,
};

struct PlexSourceEntryMetadata {
    std::string rating_key;
    std::string key;
    std::string type;
    int64_t duration_ms = 0;
    int64_t view_offset_ms = 0;
    int view_count = 0;
    int leaf_count = 0;
    int viewed_leaf_count = 0;
    std::string thumb_url;
    std::string art_url;
    bool skip_children = false;
    bool skip_parent = false;
};

// A single entry in a directory listing from a media source
struct SourceEntry {
    std::string name;           // display name
    std::string uri;            // full path or URI for playback / navigation
    bool is_directory = false;
    int64_t size = 0;           // bytes, 0 if unknown
    bool has_plex_metadata = false;
    PlexSourceEntryMetadata plex;
};

// Configuration needed to connect to a source
struct SourceConfig {
    std::string source_id;      // stable UUID
    std::string display_name;   // user-visible name ("My NAS")
    MediaSourceType type = MediaSourceType::Local;
    std::string base_uri;       // e.g. "smb://192.168.1.50/media", "/Users/foo/Movies"
    std::string username;
    std::string auth_token;     // persisted for Plex sources
    std::string password;       // only in-memory; persisted in Keychain on Swift side
};

// Abstract interface for a browsable media source.
// Each network protocol implements this interface.
class IMediaSource {
public:
    virtual ~IMediaSource() = default;
    virtual MediaSourceType type() const = 0;
    virtual const SourceConfig& config() const = 0;

    // Connect/authenticate to the source. Called once before browsing.
    virtual Error connect() = 0;
    virtual void disconnect() = 0;
    virtual bool is_connected() const = 0;

    // List contents of a directory within this source.
    // relative_path="" means root of the source.
    virtual Error list_directory(const std::string& relative_path,
                                 std::vector<SourceEntry>& entries) = 0;

    // Convert a SourceEntry to a path/URI suitable for FFmpeg playback.
    // For mount-based sources (SMB), returns the local mount path.
    // For URL-based sources (HTTP, Plex), returns a URL string.
    virtual std::string playable_path(const SourceEntry& entry) const = 0;
};

} // namespace py
