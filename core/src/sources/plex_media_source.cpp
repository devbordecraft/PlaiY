#include "plex_media_source.h"
#include "plaiy/logger.h"

#include <nlohmann/json.hpp>
#include <algorithm>
#include <functional>
#include <cctype>

static constexpr const char* TAG = "PlexSource";

using json = nlohmann::json;

namespace {

bool is_unreserved(unsigned char c) {
    return std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~';
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

} // namespace

namespace py {

// ---------------------------------------------------------------------------
// Construction / destruction
// ---------------------------------------------------------------------------

PlexMediaSource::PlexMediaSource(SourceConfig config,
                                 std::unique_ptr<IHttpClient> http_client)
    : config_(std::move(config)), http_(std::move(http_client)) {
    // Deterministic client identifier from source_id
    std::size_t h = std::hash<std::string>{}(config_.source_id);
    client_id_ = "plaiy-" + std::to_string(h);
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

    // Step 1: Obtain auth token
    if (!config_.username.empty()) {
        // plex.tv login: exchange username/password for token
        Error err = authenticate_plex_tv();
        if (err) return err;
    } else {
        // Direct token mode: password field IS the token
        auth_token_ = config_.password;
    }

    if (auth_token_.empty()) {
        return {ErrorCode::InvalidArgument,
                "No authentication token — provide a Plex token or plex.tv credentials"};
    }

    // Step 2: Validate token by hitting /identity
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
        return Error::Ok();
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse plex.tv response: ") + e.what()};
    }
}

void PlexMediaSource::disconnect() {
    PY_LOG_INFO(TAG, "Disconnecting from %s", server_name_.c_str());
    auth_token_.clear();
    server_name_.clear();
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
    std::string url = config_.base_uri + path;
    // Append token as query parameter
    if (!auth_token_.empty()) {
        url += (url.find('?') != std::string::npos) ? "&" : "?";
        url += "X-Plex-Token=" + percent_encode(auth_token_);
    }
    return url;
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
    if (resp.status_code == 401) {
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

    // Route based on path prefix
    if (relative_path.empty()) {
        return list_sections(entries);
    }

    // Find the last meaningful segment for routing
    // Format: "section:{id}" or "section:{id}/meta:{key}/meta:{key}"
    auto last_slash = relative_path.rfind('/');
    std::string last_segment = (last_slash != std::string::npos)
        ? relative_path.substr(last_slash + 1)
        : relative_path;

    if (last_segment.rfind("meta:", 0) == 0) {
        // meta:{ratingKey} — list children
        std::string rating_key = last_segment.substr(5);
        return list_children(rating_key, relative_path, entries);
    }

    if (last_segment.rfind("section:", 0) == 0) {
        // section:{id} — list section items
        std::string section_id = last_segment.substr(8);
        return list_section_items(section_id, entries);
    }

    return {ErrorCode::InvalidArgument, "Unrecognized path: " + relative_path};
}

Error PlexMediaSource::list_sections(std::vector<SourceEntry>& entries) {
    std::string body;
    Error err = fetch_json("/library/sections", body);
    if (err) return err;

    try {
        auto j = json::parse(body);
        auto& mc = j["MediaContainer"];

        if (!mc.contains("Directory")) {
            PY_LOG_INFO(TAG, "No library sections found");
            return Error::Ok();
        }

        for (const auto& dir : mc["Directory"]) {
            std::string type_str = dir.value("type", "");
            // Only show video-related libraries
            if (type_str != "movie" && type_str != "show") continue;

            SourceEntry se;
            se.name = dir.value("title", "Untitled");
            se.uri = "section:" + dir.value("key", "");
            se.is_directory = true;
            se.size = 0;
            entries.push_back(std::move(se));
        }

        PY_LOG_DEBUG(TAG, "Found %zu library sections", entries.size());
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse sections: ") + e.what()};
    }

    return Error::Ok();
}

Error PlexMediaSource::list_section_items(const std::string& section_id,
                                          std::vector<SourceEntry>& entries) {
    std::string body;
    Error err = fetch_json("/library/sections/" + section_id + "/all", body);
    if (err) return err;

    try {
        auto j = json::parse(body);
        auto& mc = j["MediaContainer"];

        if (!mc.contains("Metadata")) {
            PY_LOG_INFO(TAG, "Section %s is empty", section_id.c_str());
            return Error::Ok();
        }

        for (const auto& meta : mc["Metadata"]) {
            std::string item_type = meta.value("type", "");
            std::string title = meta.value("title", "Untitled");
            std::string rating_key = meta.value("ratingKey", "");

            if (item_type == "movie") {
                // Movies: directly playable
                std::string year_str;
                if (meta.contains("year")) {
                    year_str = " (" + std::to_string(meta["year"].get<int>()) + ")";
                }

                // Extract part ID from Media[0].Part[0]
                int64_t file_size = 0;
                std::string part_id;
                if (meta.contains("Media") && !meta["Media"].empty()) {
                    const auto& media = meta["Media"][0];
                    if (media.contains("Part") && !media["Part"].empty()) {
                        const auto& part = media["Part"][0];
                        part_id = std::to_string(part.value("id", 0));
                        file_size = part.value("size", static_cast<int64_t>(0));
                    }
                }

                SourceEntry se;
                se.name = title + year_str;
                se.uri = part_id.empty() ? ("meta:" + rating_key) : ("part:" + part_id);
                se.is_directory = part_id.empty(); // no part = can't play directly
                se.size = file_size;
                entries.push_back(std::move(se));

            } else if (item_type == "show") {
                // TV shows: navigate into seasons
                SourceEntry se;
                se.name = title;
                se.uri = "section:" + section_id + "/meta:" + rating_key;
                se.is_directory = true;
                se.size = 0;
                entries.push_back(std::move(se));
            }
        }
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse section items: ") + e.what()};
    }

    // Sort: directories first, then alphabetical
    std::sort(entries.begin(), entries.end(),
              [](const SourceEntry& a, const SourceEntry& b) {
                  if (a.is_directory != b.is_directory)
                      return a.is_directory > b.is_directory;
                  return a.name < b.name;
              });

    PY_LOG_DEBUG(TAG, "Section %s: %zu items", section_id.c_str(), entries.size());
    return Error::Ok();
}

Error PlexMediaSource::list_children(const std::string& rating_key,
                                     const std::string& parent_path,
                                     std::vector<SourceEntry>& entries) {
    struct SortableSourceEntry {
        SourceEntry entry;
        bool has_index = false;
        int index = 0;
    };

    std::string body;
    Error err = fetch_json("/library/metadata/" + rating_key + "/children", body);
    if (err) return err;

    std::vector<SortableSourceEntry> sortable_entries;

    try {
        auto j = json::parse(body);
        auto& mc = j["MediaContainer"];

        if (!mc.contains("Metadata")) {
            PY_LOG_INFO(TAG, "No children for %s", rating_key.c_str());
            return Error::Ok();
        }

        for (const auto& meta : mc["Metadata"]) {
            std::string item_type = meta.value("type", "");
            std::string child_key = meta.value("ratingKey", "");

            if (item_type == "season") {
                // Seasons: navigate into episodes
                int season_index = meta.value("index", 0);
                SourceEntry se;
                se.name = "Season " + std::to_string(season_index);
                se.uri = parent_path + "/meta:" + child_key;
                se.is_directory = true;
                se.size = 0;
                sortable_entries.push_back({
                    .entry = std::move(se),
                    .has_index = true,
                    .index = season_index,
                });

            } else if (item_type == "episode") {
                // Episodes: directly playable
                int episode_index = meta.value("index", 0);
                std::string title = meta.value("title", "");
                std::string display = "E" + std::to_string(episode_index);
                if (!title.empty()) {
                    display += " - " + title;
                }

                int64_t file_size = 0;
                std::string part_id;
                if (meta.contains("Media") && !meta["Media"].empty()) {
                    const auto& media = meta["Media"][0];
                    if (media.contains("Part") && !media["Part"].empty()) {
                        const auto& part = media["Part"][0];
                        part_id = std::to_string(part.value("id", 0));
                        file_size = part.value("size", static_cast<int64_t>(0));
                    }
                }

                SourceEntry se;
                se.name = display;
                se.uri = part_id.empty() ? ("meta:" + child_key) : ("part:" + part_id);
                se.is_directory = part_id.empty();
                se.size = file_size;
                sortable_entries.push_back({
                    .entry = std::move(se),
                    .has_index = true,
                    .index = episode_index,
                });
            }
        }
    } catch (const json::exception& e) {
        return {ErrorCode::NetworkError,
                std::string("Failed to parse children: ") + e.what()};
    }

    // Sort: directories (seasons) first, then numeric index, then name.
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

    PY_LOG_DEBUG(TAG, "Children of %s: %zu items", rating_key.c_str(),
                 entries.size());
    return Error::Ok();
}

// ---------------------------------------------------------------------------
// Playback
// ---------------------------------------------------------------------------

std::string PlexMediaSource::playable_path(const SourceEntry& entry) const {
    // Only entries with "part:{id}" URIs are directly playable
    if (entry.uri.rfind("part:", 0) != 0) {
        return {};
    }

    std::string part_id = entry.uri.substr(5);
    return config_.base_uri + "/library/parts/" + part_id +
           "/file?X-Plex-Token=" + percent_encode(auth_token_);
}

} // namespace py
