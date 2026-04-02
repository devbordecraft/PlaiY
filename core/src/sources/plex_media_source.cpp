#include "plex_media_source.h"
#include "plaiy/logger.h"

#include <nlohmann/json.hpp>
#include <algorithm>
#include <cctype>
#include <functional>
#include <utility>

static constexpr const char* TAG = "PlexSource";

using json = nlohmann::json;

namespace {

bool is_unreserved(unsigned char c) {
    return std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~';
}

bool has_prefix(const std::string& s, const std::string& prefix) {
    return s.rfind(prefix, 0) == 0;
}

bool has_suffix(const std::string& s, const std::string& suffix) {
    return s.size() >= suffix.size() &&
           s.compare(s.size() - suffix.size(), suffix.size(), suffix) == 0;
}

std::string percent_encode(const std::string& input, bool space_as_plus = false) {
    static constexpr char kHex[] = "0123456789ABCDEF";
    std::string out;
    out.reserve(input.size() * 3);

    for (char ch : input) {
        unsigned char c = static_cast<unsigned char>(ch);
        if (is_unreserved(c)) {
            out.push_back(ch);
            continue;
        }
        if (space_as_plus && c == ' ') {
            out.push_back('+');
            continue;
        }
        out.push_back('%');
        out.push_back(kHex[(c >> 4) & 0x0F]);
        out.push_back(kHex[c & 0x0F]);
    }

    return out;
}

std::string trim_trailing_slashes(std::string value) {
    while (value.size() > 1 && !value.empty() && value.back() == '/') {
        value.pop_back();
    }
    return value;
}

std::string detail_key_for_rating_key(const std::string& rating_key) {
    return "/library/metadata/" + rating_key;
}

std::string children_key_for_rating_key(const std::string& rating_key,
                                        bool grandchildren) {
    return detail_key_for_rating_key(rating_key) +
           (grandchildren ? "/grandchildren" : "/children");
}

std::string detail_key_from_metadata(const json& meta) {
    std::string rating_key = meta.value("ratingKey", "");
    std::string key = meta.value("key", "");

    if (key.empty()) {
        return rating_key.empty() ? std::string{} : detail_key_for_rating_key(rating_key);
    }
    if (has_suffix(key, "/children")) {
        return key.substr(0, key.size() - std::string("/children").size());
    }
    if (has_suffix(key, "/grandchildren")) {
        return key.substr(0, key.size() - std::string("/grandchildren").size());
    }
    return key;
}

std::string browse_key_from_metadata(const json& meta) {
    const std::string type = meta.value("type", "");
    const std::string rating_key = meta.value("ratingKey", "");
    const std::string key = meta.value("key", "");

    if (type == "show") {
        if (!rating_key.empty()) {
            return children_key_for_rating_key(rating_key, meta.value("skipChildren", false));
        }
        return key;
    }
    if (type == "season") {
        if (!rating_key.empty()) {
            return children_key_for_rating_key(rating_key, false);
        }
        return key;
    }
    return detail_key_from_metadata(meta);
}

std::string section_browse_key(const json& dir) {
    const std::string key = dir.value("key", "");
    if (has_prefix(key, "/")) {
        return has_suffix(key, "/all") ? key : (trim_trailing_slashes(key) + "/all");
    }
    return "/library/sections/" + key + "/all";
}

std::string movie_display_name(const json& meta) {
    std::string name = meta.value("title", "Untitled");
    if (meta.contains("year") && meta["year"].is_number_integer()) {
        name += " (" + std::to_string(meta["year"].get<int>()) + ")";
    }
    return name;
}

std::string episode_display_name(const json& meta) {
    const int index = meta.value("index", 0);
    std::string name = "E" + std::to_string(index);
    const std::string title = meta.value("title", "");
    if (!title.empty()) {
        name += " - " + title;
    }
    return name;
}

std::string season_display_name(const json& meta) {
    const int index = meta.value("index", 0);
    return "Season " + std::to_string(index);
}

std::string normalize_connection_uri(const std::string& uri) {
    return trim_trailing_slashes(uri);
}

struct ParsedPart {
    std::string part_id;
    int64_t size = 0;
};

ParsedPart first_playable_part(const json& meta) {
    ParsedPart parsed;
    if (!meta.contains("Media") || !meta["Media"].is_array() || meta["Media"].empty()) {
        return parsed;
    }

    const auto& media = meta["Media"][0];
    if (!media.contains("Part") || !media["Part"].is_array() || media["Part"].empty()) {
        return parsed;
    }

    const auto& part = media["Part"][0];
    const int part_id = part.value("id", 0);
    if (part_id > 0) {
        parsed.part_id = std::to_string(part_id);
    }
    parsed.size = part.value("size", static_cast<int64_t>(0));
    return parsed;
}

} // namespace

namespace py {

namespace {

struct SortableSourceEntry {
    SourceEntry entry;
    bool has_index = false;
    int index = 0;
};

} // namespace

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

PlexMediaSource::PlexMediaSource(SourceConfig config,
                                 std::unique_ptr<IHttpClient> http_client)
    : config_(std::move(config)), http_(std::move(http_client)) {
    std::size_t h = std::hash<std::string>{}(config_.source_id);
    client_id_ = "plaiy-" + std::to_string(h);
    config_.base_uri = trim_trailing_slashes(config_.base_uri);
}

PlexMediaSource::~PlexMediaSource() {
    if (connected_) {
        disconnect();
    }
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

Error PlexMediaSource::connect() {
    if (connected_) {
        PY_LOG_INFO(TAG, "Already connected to %s", server_name_.c_str());
        return Error::Ok();
    }

    playable_items_.clear();

    auth_token_ = !config_.auth_token.empty() ? config_.auth_token : config_.password;

    if (auth_token_.empty()) {
        return {ErrorCode::InvalidArgument,
                "Plex token missing — reconnect the source"};
    }

    std::string body;
    Error err = fetch_json("/identity", body);
    if (err) {
        auth_token_.clear();
        return err;
    }

    try {
        auto j = json::parse(body);
        auto& mc = j["MediaContainer"];
        server_name_ = mc.value("friendlyName", mc.value("machineIdentifier", "Plex Server"));
    } catch (const json::exception&) {
        server_name_ = "Plex Server";
    }

    connected_ = true;
    PY_LOG_INFO(TAG, "Connected to %s (%s)", server_name_.c_str(),
                config_.base_uri.c_str());
    return Error::Ok();
}

Error PlexMediaSource::authenticate_plex_tv() {
    PY_LOG_INFO(TAG, "Authenticating via plex.tv for user %s",
                config_.username.c_str());

    HttpRequest req;
    req.url = "https://plex.tv/users/sign_in.json";
    req.method = "POST";
    req.headers = plex_headers();
    req.headers["Content-Type"] = "application/x-www-form-urlencoded";
    req.body = "user[login]=" + percent_encode(config_.username, true) +
               "&user[password]=" + percent_encode(config_.password, true);
    req.timeout_seconds = 15;

    HttpResponse resp = http_->request(req);

    if (!resp.error_message.empty()) {
        return {ErrorCode::NetworkError,
                "Could not reach plex.tv — " + resp.error_message};
    }
    if (resp.status_code == 401) {
        return {ErrorCode::NetworkError,
                "Authentication failed — check email and password"};
    }
    if (!resp.ok()) {
        return {ErrorCode::NetworkError,
                "plex.tv returned status " + std::to_string(resp.status_code)};
    }

    try {
        auto j = json::parse(resp.body);
        auth_token_ = j["user"]["authToken"].get<std::string>();
        PY_LOG_INFO(TAG, "Obtained plex.tv auth token");

        std::string server_token;
        Error err = resolve_pms_access_token(auth_token_, server_token);
        if (err) return err;
        if (!server_token.empty()) {
            auth_token_ = server_token;
            PY_LOG_INFO(TAG, "Resolved PMS access token for %s", config_.base_uri.c_str());
        } else {
            PY_LOG_WARN(TAG, "Falling back to plex.tv token for %s", config_.base_uri.c_str());
        }

        return Error::Ok();
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse plex.tv response: ") + e.what()};
    }
}

Error PlexMediaSource::resolve_pms_access_token(const std::string& user_token,
                                                std::string& server_token) {
    server_token.clear();

    HttpRequest req;
    req.url = "https://clients.plex.tv/api/v2/resources?includeHttps=1&includeRelay=1&includeIPv6=1";
    req.method = "GET";
    req.headers = plex_headers();
    req.headers["X-Plex-Token"] = user_token;
    req.timeout_seconds = 15;

    HttpResponse resp = http_->request(req);
    if (!resp.error_message.empty()) {
        PY_LOG_WARN(TAG, "Could not resolve PMS token via resources: %s",
                    resp.error_message.c_str());
        return Error::Ok();
    }
    if (!resp.ok()) {
        PY_LOG_WARN(TAG, "resources lookup returned status %d", resp.status_code);
        return Error::Ok();
    }

    try {
        const auto resources = json::parse(resp.body);
        if (!resources.is_array()) {
            return Error::Ok();
        }

        const std::string target_uri = normalize_connection_uri(config_.base_uri);
        for (const auto& resource : resources) {
            const std::string provides = resource.value("provides", "");
            if (provides.find("server") == std::string::npos) {
                continue;
            }

            const std::string access_token = resource.value("accessToken", "");
            if (access_token.empty() ||
                !resource.contains("connections") ||
                !resource["connections"].is_array()) {
                continue;
            }

            for (const auto& connection : resource["connections"]) {
                const std::string uri = normalize_connection_uri(connection.value("uri", ""));
                if (!uri.empty() && uri == target_uri) {
                    server_token = access_token;
                    return Error::Ok();
                }
            }
        }
    } catch (const json::exception& e) {
        PY_LOG_WARN(TAG, "Could not parse resources lookup: %s", e.what());
    }

    return Error::Ok();
}

void PlexMediaSource::disconnect() {
    PY_LOG_INFO(TAG, "Disconnecting from %s", server_name_.c_str());
    auth_token_.clear();
    server_name_.clear();
    playable_items_.clear();
    connected_ = false;
}

bool PlexMediaSource::is_connected() const {
    return connected_;
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

std::map<std::string, std::string> PlexMediaSource::plex_headers() const {
    return {
        {"Accept", "application/json"},
        {"X-Plex-Client-Identifier", client_id_},
        {"X-Plex-Product", "PlaiY"},
        {"X-Plex-Version", "1.0"},
    };
}

std::string PlexMediaSource::api_url(const std::string& path) const {
    std::string url = has_prefix(path, "http://") || has_prefix(path, "https://")
        ? path
        : config_.base_uri + path;

    if (!auth_token_.empty()) {
        url += (url.find('?') != std::string::npos) ? "&" : "?";
        url += "X-Plex-Token=" + percent_encode(auth_token_);
    }
    return url;
}

std::string PlexMediaSource::media_url(const std::string& path) const {
    if (path.empty()) return {};
    return api_url(path);
}

Error PlexMediaSource::fetch_json(const std::string& api_path, std::string& body) {
    HttpRequest req;
    req.url = api_url(api_path);
    req.method = "GET";
    req.headers = plex_headers();
    req.timeout_seconds = 30;

    HttpResponse resp = http_->request(req);

    if (!resp.error_message.empty()) {
        PY_LOG_ERROR(TAG, "Request failed for %s: %s",
                     api_path.c_str(), resp.error_message.c_str());
        return {ErrorCode::NetworkError,
                "Server not reachable — " + resp.error_message};
    }
    if (resp.status_code == 401 || resp.status_code == 403) {
        connected_ = false;
        return {ErrorCode::NetworkError,
                "Authentication expired — reconnect the source"};
    }
    if (!resp.ok()) {
        return {ErrorCode::NetworkError,
                "Server returned status " + std::to_string(resp.status_code) +
                " for " + api_path};
    }

    body = std::move(resp.body);
    return Error::Ok();
}

// ---------------------------------------------------------------------------
// Directory listing
// ---------------------------------------------------------------------------

Error PlexMediaSource::list_directory(const std::string& relative_path,
                                      std::vector<SourceEntry>& entries) {
    entries.clear();

    if (!connected_) {
        return {ErrorCode::InvalidState, "Plex source not connected"};
    }

    if (relative_path.empty()) {
        return list_sections(entries);
    }
    if (!has_prefix(relative_path, "/library/")) {
        return {ErrorCode::InvalidArgument, "Unrecognized path: " + relative_path};
    }

    return list_api_path(relative_path, entries);
}

Error PlexMediaSource::list_sections(std::vector<SourceEntry>& entries) {
    std::string body;
    Error err = fetch_json("/library/sections", body);
    if (err) return err;

    try {
        const auto j = json::parse(body);
        const auto& mc = j["MediaContainer"];

        if (!mc.contains("Directory") || !mc["Directory"].is_array()) {
            PY_LOG_INFO(TAG, "No library sections found");
            return Error::Ok();
        }

        for (const auto& dir : mc["Directory"]) {
            const std::string type = dir.value("type", "");
            if (type != "movie" && type != "show") {
                continue;
            }

            SourceEntry entry;
            entry.name = dir.value("title", "Untitled");
            entry.uri = section_browse_key(dir);
            entry.is_directory = true;
            entries.push_back(std::move(entry));
        }

        PY_LOG_DEBUG(TAG, "Found %zu library sections", entries.size());
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse sections: ") + e.what()};
    }

    return Error::Ok();
}

Error PlexMediaSource::list_api_path(const std::string& api_path,
                                     std::vector<SourceEntry>& entries) {
    std::string body;
    Error err = fetch_json(api_path, body);
    if (err) return err;

    std::vector<SortableSourceEntry> sortable_entries;

    try {
        const auto j = json::parse(body);
        const auto& mc = j["MediaContainer"];

        if (!mc.contains("Metadata") || !mc["Metadata"].is_array()) {
            PY_LOG_INFO(TAG, "Plex path %s is empty", api_path.c_str());
            return Error::Ok();
        }

        for (const auto& meta : mc["Metadata"]) {
            const std::string type = meta.value("type", "");
            if (type.empty()) {
                continue;
            }

            SourceEntry entry;
            bool has_index = false;
            int index = 0;

            if (type == "movie") {
                const ParsedPart part = first_playable_part(meta);
                entry.name = movie_display_name(meta);
                entry.uri = detail_key_from_metadata(meta);
                entry.is_directory = part.part_id.empty();
                entry.size = part.size;
                if (!part.part_id.empty()) {
                    CachedPlayableItem cached;
                    cached.part_id = part.part_id;
                    cached.metadata_key = entry.uri;
                    cached.rating_key = meta.value("ratingKey", "");
                    playable_items_[entry.uri] = std::move(cached);
                }
            } else if (type == "show") {
                entry.name = meta.value("title", "Untitled");
                entry.uri = browse_key_from_metadata(meta);
                entry.is_directory = true;
                has_index = false;
            } else if (type == "season") {
                index = meta.value("index", 0);
                has_index = true;
                entry.name = season_display_name(meta);
                entry.uri = browse_key_from_metadata(meta);
                entry.is_directory = true;
            } else if (type == "episode") {
                const ParsedPart part = first_playable_part(meta);
                index = meta.value("index", 0);
                has_index = true;
                entry.name = episode_display_name(meta);
                entry.uri = detail_key_from_metadata(meta);
                entry.is_directory = part.part_id.empty();
                entry.size = part.size;
                if (!part.part_id.empty()) {
                    CachedPlayableItem cached;
                    cached.part_id = part.part_id;
                    cached.metadata_key = entry.uri;
                    cached.rating_key = meta.value("ratingKey", "");
                    playable_items_[entry.uri] = std::move(cached);
                }
            } else {
                continue;
            }

            entry.has_plex_metadata = true;
            entry.plex.rating_key = meta.value("ratingKey", "");
            entry.plex.key = detail_key_from_metadata(meta);
            entry.plex.type = type;
            entry.plex.duration_ms = meta.value("duration", static_cast<int64_t>(0));
            entry.plex.view_offset_ms = meta.value("viewOffset", static_cast<int64_t>(0));
            entry.plex.view_count = meta.value("viewCount", 0);
            entry.plex.leaf_count = meta.value("leafCount", 0);
            entry.plex.viewed_leaf_count = meta.value("viewedLeafCount", 0);
            entry.plex.skip_children = meta.value("skipChildren", false);
            entry.plex.skip_parent = meta.value("skipParent", false);

            const std::string thumb = meta.value("thumb", "");
            const std::string art = meta.value("art", "");
            if (!thumb.empty()) {
                entry.plex.thumb_url = media_url(thumb);
            }
            if (!art.empty()) {
                entry.plex.art_url = media_url(art);
            }

            SortableSourceEntry sortable;
            sortable.entry = std::move(entry);
            sortable.has_index = has_index;
            sortable.index = index;
            sortable_entries.push_back(std::move(sortable));
        }
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse Plex listing: ") + e.what()};
    }

    std::sort(sortable_entries.begin(), sortable_entries.end(),
              [](const SortableSourceEntry& a, const SortableSourceEntry& b) {
                  if (a.entry.is_directory != b.entry.is_directory) {
                      return a.entry.is_directory > b.entry.is_directory;
                  }
                  if (a.has_index != b.has_index) {
                      return a.has_index > b.has_index;
                  }
                  if (a.has_index && b.has_index && a.index != b.index) {
                      return a.index < b.index;
                  }
                  return a.entry.name < b.entry.name;
              });

    entries.reserve(sortable_entries.size());
    for (auto& sortable : sortable_entries) {
        entries.push_back(std::move(sortable.entry));
    }

    PY_LOG_DEBUG(TAG, "Plex path %s: %zu items", api_path.c_str(), entries.size());
    return Error::Ok();
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

Error PlexMediaSource::load_playable_item(const std::string& metadata_key,
                                          CachedPlayableItem& item) const {
    auto it = playable_items_.find(metadata_key);
    if (it != playable_items_.end()) {
        item = it->second;
        return Error::Ok();
    }

    std::string body;
    Error err = const_cast<PlexMediaSource*>(this)->fetch_json(metadata_key, body);
    if (err) return err;

    try {
        const auto j = json::parse(body);
        const auto& mc = j["MediaContainer"];
        if (!mc.contains("Metadata") || !mc["Metadata"].is_array() || mc["Metadata"].empty()) {
            return {ErrorCode::NetworkError, "Plex item is missing metadata"};
        }

        const auto& meta = mc["Metadata"][0];
        const ParsedPart part = first_playable_part(meta);
        if (part.part_id.empty()) {
            return {ErrorCode::InvalidArgument, "Plex item is not directly playable"};
        }

        item.part_id = part.part_id;
        item.metadata_key = detail_key_from_metadata(meta);
        item.rating_key = meta.value("ratingKey", "");
        playable_items_[metadata_key] = item;
        return Error::Ok();
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse playable item metadata: ") + e.what()};
    }
}

std::string PlexMediaSource::playable_path(const SourceEntry& entry) const {
    if (entry.is_directory || entry.uri.empty()) {
        return {};
    }

    CachedPlayableItem item;
    Error err = load_playable_item(entry.uri, item);
    if (err || item.part_id.empty()) {
        return {};
    }

    return media_url("/library/parts/" + item.part_id + "/file");
}

} // namespace py
