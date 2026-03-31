#include <catch2/catch_test_macros.hpp>
#include "sources/plex_media_source.h"
#include "plaiy/source_manager.h"
#include "http/http_client.h"
#include <queue>
#include <string>
#include <vector>

using namespace py;

// ---------------------------------------------------------------------------
// Mock HTTP client
// ---------------------------------------------------------------------------

class MockHttpClient : public IHttpClient {
public:
    void enqueue(int status, std::string body) {
        responses_.push({status, std::move(body), ""});
    }
    void enqueue_error(std::string msg) {
        responses_.push({0, "", std::move(msg)});
    }

    HttpResponse request(const HttpRequest& req) override {
        last_request = req;
        requests.push_back(req);
        request_count++;
        if (responses_.empty()) return {500, "", "No mock response queued"};
        auto r = std::move(responses_.front());
        responses_.pop();
        return r;
    }

    HttpRequest last_request;
    std::vector<HttpRequest> requests;
    int request_count = 0;

private:
    std::queue<HttpResponse> responses_;
};

// ---------------------------------------------------------------------------
// Canned Plex API JSON responses
// ---------------------------------------------------------------------------

static const char* IDENTITY_JSON = R"({
    "MediaContainer": {
        "size": 0,
        "machineIdentifier": "abc123",
        "friendlyName": "TestPlex",
        "version": "1.40.0"
    }
})";

static const char* SECTIONS_JSON = R"({
    "MediaContainer": {
        "size": 3,
        "Directory": [
            {"key": "1", "title": "Movies", "type": "movie"},
            {"key": "2", "title": "TV Shows", "type": "show"},
            {"key": "3", "title": "Music", "type": "artist"}
        ]
    }
})";

static const char* MOVIES_JSON = R"({
    "MediaContainer": {
        "size": 2,
        "Metadata": [
            {
                "ratingKey": "101",
                "title": "Test Movie",
                "type": "movie",
                "year": 2024,
                "Media": [{
                    "Part": [{
                        "id": 501,
                        "size": 2147483648
                    }]
                }]
            },
            {
                "ratingKey": "102",
                "title": "Another Movie",
                "type": "movie",
                "year": 2023,
                "Media": [{
                    "Part": [{
                        "id": 502,
                        "size": 1073741824
                    }]
                }]
            }
        ]
    }
})";

static const char* SHOWS_JSON = R"({
    "MediaContainer": {
        "size": 1,
        "Metadata": [
            {
                "ratingKey": "201",
                "title": "Test Show",
                "type": "show"
            }
        ]
    }
})";

static const char* SHOWS_SKIP_CHILDREN_JSON = R"({
    "MediaContainer": {
        "size": 1,
        "Metadata": [
            {
                "ratingKey": "211",
                "title": "Mini Series",
                "type": "show",
                "skipChildren": true,
                "leafCount": 3,
                "viewedLeafCount": 1
            }
        ]
    }
})";

static const char* SEASONS_JSON = R"({
    "MediaContainer": {
        "size": 2,
        "Metadata": [
            {"ratingKey": "301", "title": "Season 1", "type": "season", "index": 1},
            {"ratingKey": "302", "title": "Season 2", "type": "season", "index": 2}
        ]
    }
})";

static const char* EPISODES_JSON = R"({
    "MediaContainer": {
        "size": 2,
        "Metadata": [
            {
                "ratingKey": "401",
                "title": "Pilot",
                "type": "episode",
                "index": 1,
                "Media": [{"Part": [{"id": 601, "size": 524288000}]}]
            },
            {
                "ratingKey": "402",
                "title": "Second Episode",
                "type": "episode",
                "index": 2,
                "Media": [{"Part": [{"id": 602, "size": 536870912}]}]
            }
        ]
    }
})";

static const char* SEASONS_UNSORTED_JSON = R"({
    "MediaContainer": {
        "size": 2,
        "Metadata": [
            {"ratingKey": "310", "title": "Season 10", "type": "season", "index": 10},
            {"ratingKey": "302", "title": "Season 2", "type": "season", "index": 2}
        ]
    }
})";

static const char* EPISODES_UNSORTED_JSON = R"({
    "MediaContainer": {
        "size": 2,
        "Metadata": [
            {
                "ratingKey": "410",
                "title": "Tenth Episode",
                "type": "episode",
                "index": 10,
                "Media": [{"Part": [{"id": 610, "size": 300}]}]
            },
            {
                "ratingKey": "402",
                "title": "Second Episode",
                "type": "episode",
                "index": 2,
                "Media": [{"Part": [{"id": 602, "size": 200}]}]
            }
        ]
    }
})";

static const char* PLEX_TV_AUTH_JSON = R"({
    "user": {
        "id": 12345,
        "uuid": "abc",
        "email": "test@example.com",
        "authToken": "plex-tv-token-xyz"
    }
})";

static const char* PLEX_RESOURCES_JSON = R"([
    {
        "name": "TestPlex",
        "provides": "server",
        "clientIdentifier": "abc123",
        "accessToken": "pms-token-xyz",
        "connections": [
            {
                "uri": "http://192.168.1.50:32400",
                "local": true,
                "relay": false
            }
        ]
    }
])";

// ---------------------------------------------------------------------------
// Helper to create a PlexMediaSource with a mock HTTP client
// ---------------------------------------------------------------------------

struct TestFixture {
    MockHttpClient* mock;   // non-owning, valid as long as source lives
    std::unique_ptr<PlexMediaSource> source;

    TestFixture(const std::string& base_uri = "http://192.168.1.50:32400",
                const std::string& token = "test-token",
                const std::string& username = "") {
        auto http = std::make_unique<MockHttpClient>();
        mock = http.get();

        SourceConfig cfg;
        cfg.source_id = "plex-test-1";
        cfg.display_name = "Test Plex";
        cfg.type = MediaSourceType::Plex;
        cfg.base_uri = base_uri;
        cfg.username = username;
        cfg.password = token;

        source = std::make_unique<PlexMediaSource>(std::move(cfg), std::move(http));
    }
};

// ---------------------------------------------------------------------------
// Connection tests
// ---------------------------------------------------------------------------

TEST_CASE("PlexMediaSource connect with valid token") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);

    Error err = f.source->connect();
    REQUIRE(err.ok());
    REQUIRE(f.source->is_connected());
    REQUIRE(f.mock->request_count == 1);
    REQUIRE(f.mock->last_request.url.find("/identity") != std::string::npos);
    REQUIRE(f.mock->last_request.url.find("X-Plex-Token=test-token") != std::string::npos);
}

TEST_CASE("PlexMediaSource connect with invalid token returns error") {
    TestFixture f;
    f.mock->enqueue(401, "");

    Error err = f.source->connect();
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::NetworkError);
    REQUIRE_FALSE(f.source->is_connected());
}

TEST_CASE("PlexMediaSource connect with unreachable server") {
    TestFixture f;
    f.mock->enqueue_error("Connection refused");

    Error err = f.source->connect();
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::NetworkError);
    REQUIRE(err.message.find("not reachable") != std::string::npos);
    REQUIRE_FALSE(f.source->is_connected());
}

TEST_CASE("PlexMediaSource connect with empty token returns error") {
    TestFixture f("http://192.168.1.50:32400", "");

    Error err = f.source->connect();
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidArgument);
}

TEST_CASE("PlexMediaSource connect already connected is no-op") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    // Second connect should not make another request
    REQUIRE(f.source->connect().ok());
    REQUIRE(f.mock->request_count == 1);
}

TEST_CASE("PlexMediaSource plex.tv login exchanges credentials for token") {
    TestFixture f("http://192.168.1.50:32400", "mypassword", "user@example.com");

    // First request: plex.tv auth
    f.mock->enqueue(200, PLEX_TV_AUTH_JSON);
    // Second request: resources lookup for the PMS token
    f.mock->enqueue(200, PLEX_RESOURCES_JSON);
    // Third request: validate token via /identity
    f.mock->enqueue(200, IDENTITY_JSON);

    Error err = f.source->connect();
    REQUIRE(err.ok());
    REQUIRE(f.source->is_connected());
    REQUIRE(f.mock->request_count == 3);

    REQUIRE(f.mock->last_request.url.find("X-Plex-Token=pms-token-xyz") != std::string::npos);
}

TEST_CASE("PlexMediaSource plex.tv login encodes form fields") {
    TestFixture f("http://192.168.1.50:32400", "p@ss w+rd&=", "user+name@example.com");
    f.mock->enqueue(200, PLEX_TV_AUTH_JSON);
    f.mock->enqueue(200, PLEX_RESOURCES_JSON);
    f.mock->enqueue(200, IDENTITY_JSON);

    Error err = f.source->connect();
    REQUIRE(err.ok());
    REQUIRE(f.mock->requests.size() >= 1);
    REQUIRE(f.mock->requests[0].body.find("user[login]=user%2Bname%40example.com") != std::string::npos);
    REQUIRE(f.mock->requests[0].body.find("user[password]=p%40ss+w%2Brd%26%3D") != std::string::npos);
}

TEST_CASE("PlexMediaSource connect encodes token query parameter") {
    TestFixture f("http://192.168.1.50:32400", "tok+/%?=&");
    f.mock->enqueue(200, IDENTITY_JSON);

    Error err = f.source->connect();
    REQUIRE(err.ok());
    REQUIRE(f.mock->last_request.url.find("X-Plex-Token=tok%2B%2F%25%3F%3D%26") != std::string::npos);
}

TEST_CASE("PlexMediaSource plex.tv login with wrong credentials") {
    TestFixture f("http://192.168.1.50:32400", "wrong", "user@example.com");
    f.mock->enqueue(401, "");

    Error err = f.source->connect();
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::NetworkError);
    REQUIRE(err.message.find("Authentication failed") != std::string::npos);
}

// ---------------------------------------------------------------------------
// Disconnect tests
// ---------------------------------------------------------------------------

TEST_CASE("PlexMediaSource disconnect clears connected state") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());
    REQUIRE(f.source->is_connected());

    f.source->disconnect();
    REQUIRE_FALSE(f.source->is_connected());
}

// ---------------------------------------------------------------------------
// Directory listing tests
// ---------------------------------------------------------------------------

TEST_CASE("PlexMediaSource list_directory fails when not connected") {
    TestFixture f;
    std::vector<SourceEntry> entries;

    Error err = f.source->list_directory("", entries);
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidState);
}

TEST_CASE("PlexMediaSource list_directory root lists sections") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, SECTIONS_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("", entries);
    REQUIRE(err.ok());

    // Music section should be filtered out (not movie/show)
    REQUIRE(entries.size() == 2);
    REQUIRE(entries[0].name == "Movies");
    REQUIRE(entries[0].uri == "/library/sections/1/all");
    REQUIRE(entries[0].is_directory);
    REQUIRE(entries[1].name == "TV Shows");
    REQUIRE(entries[1].uri == "/library/sections/2/all");
    REQUIRE(entries[1].is_directory);
}

TEST_CASE("PlexMediaSource list_directory section lists movies") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, MOVIES_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/sections/1/all", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 2);

    // Movies sorted alphabetically (no directories first since all are files)
    REQUIRE(entries[0].name == "Another Movie (2023)");
    REQUIRE(entries[0].uri == "/library/metadata/102");
    REQUIRE_FALSE(entries[0].is_directory);
    REQUIRE(entries[0].size == 1073741824);
    REQUIRE(entries[0].has_plex_metadata);
    REQUIRE(entries[0].plex.rating_key == "102");
    REQUIRE(entries[0].plex.key == "/library/metadata/102");
    REQUIRE(entries[0].plex.type == "movie");

    REQUIRE(entries[1].name == "Test Movie (2024)");
    REQUIRE(entries[1].uri == "/library/metadata/101");
    REQUIRE_FALSE(entries[1].is_directory);
    REQUIRE(entries[1].size == 2147483648);
}

TEST_CASE("PlexMediaSource list_directory section lists TV shows as directories") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, SHOWS_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/sections/2/all", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 1);
    REQUIRE(entries[0].name == "Test Show");
    REQUIRE(entries[0].uri == "/library/metadata/201/children");
    REQUIRE(entries[0].is_directory);
    REQUIRE(entries[0].plex.key == "/library/metadata/201");
}

TEST_CASE("PlexMediaSource list_directory show with skipChildren jumps to grandchildren") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, SHOWS_SKIP_CHILDREN_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/sections/2/all", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 1);
    REQUIRE(entries[0].uri == "/library/metadata/211/grandchildren");
    REQUIRE(entries[0].plex.skip_children);
    REQUIRE(entries[0].plex.leaf_count == 3);
    REQUIRE(entries[0].plex.viewed_leaf_count == 1);
}

TEST_CASE("PlexMediaSource list_directory TV show lists seasons") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, SEASONS_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/metadata/201/children", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 2);
    REQUIRE(entries[0].name == "Season 1");
    REQUIRE(entries[0].uri == "/library/metadata/301/children");
    REQUIRE(entries[0].is_directory);
    REQUIRE(entries[1].name == "Season 2");
    REQUIRE(entries[1].uri == "/library/metadata/302/children");
    REQUIRE(entries[1].is_directory);
}

TEST_CASE("PlexMediaSource list_directory seasons sorted numerically") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, SEASONS_UNSORTED_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/metadata/201/children", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 2);
    REQUIRE(entries[0].name == "Season 2");
    REQUIRE(entries[1].name == "Season 10");
}

TEST_CASE("PlexMediaSource list_directory season lists episodes") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, EPISODES_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/metadata/301/children", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 2);
    REQUIRE(entries[0].name == "E1 - Pilot");
    REQUIRE(entries[0].uri == "/library/metadata/401");
    REQUIRE_FALSE(entries[0].is_directory);
    REQUIRE(entries[0].size == 524288000);

    REQUIRE(entries[1].name == "E2 - Second Episode");
    REQUIRE(entries[1].uri == "/library/metadata/402");
    REQUIRE_FALSE(entries[1].is_directory);
}

TEST_CASE("PlexMediaSource list_directory episodes sorted numerically") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, EPISODES_UNSORTED_JSON);
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/metadata/301/children", entries);
    REQUIRE(err.ok());

    REQUIRE(entries.size() == 2);
    REQUIRE(entries[0].name == "E2 - Second Episode");
    REQUIRE(entries[0].uri == "/library/metadata/402");
    REQUIRE(entries[1].name == "E10 - Tenth Episode");
    REQUIRE(entries[1].uri == "/library/metadata/410");
}

TEST_CASE("PlexMediaSource list_directory empty section") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, R"({"MediaContainer": {"size": 0}})");
    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("/library/sections/1/all", entries);
    REQUIRE(err.ok());
    REQUIRE(entries.empty());
}

TEST_CASE("PlexMediaSource list_directory invalid path") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    std::vector<SourceEntry> entries;
    Error err = f.source->list_directory("garbage:xyz", entries);
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidArgument);
}

// ---------------------------------------------------------------------------
// Playable path tests
// ---------------------------------------------------------------------------

TEST_CASE("PlexMediaSource playable_path for movie returns stream URL") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, MOVIES_JSON);
    std::vector<SourceEntry> entries;
    REQUIRE(f.source->list_directory("/library/sections/1/all", entries).ok());
    REQUIRE(entries.size() == 2);

    std::string path = f.source->playable_path(entries[1]);
    REQUIRE(path == "http://192.168.1.50:32400/library/parts/501/file?X-Plex-Token=test-token");
}

TEST_CASE("PlexMediaSource playable_path for directory returns empty") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    SourceEntry entry;
    entry.uri = "/library/sections/1/all";
    entry.is_directory = true;

    std::string path = f.source->playable_path(entry);
    REQUIRE(path.empty());
}

TEST_CASE("PlexMediaSource playable_path encodes auth token") {
    TestFixture f("http://192.168.1.50:32400", "tok+/%?=&");
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    f.mock->enqueue(200, MOVIES_JSON);
    std::vector<SourceEntry> entries;
    REQUIRE(f.source->list_directory("/library/sections/1/all", entries).ok());

    std::string path = f.source->playable_path(entries[1]);
    REQUIRE(path.find("X-Plex-Token=tok%2B%2F%25%3F%3D%26") != std::string::npos);
}

// ---------------------------------------------------------------------------
// Plex headers tests
// ---------------------------------------------------------------------------

TEST_CASE("PlexMediaSource sends correct Plex headers") {
    TestFixture f;
    f.mock->enqueue(200, IDENTITY_JSON);
    REQUIRE(f.source->connect().ok());

    auto& headers = f.mock->last_request.headers;
    REQUIRE(headers.count("Accept"));
    REQUIRE(headers.at("Accept") == "application/json");
    REQUIRE(headers.count("X-Plex-Client-Identifier"));
    REQUIRE_FALSE(headers.at("X-Plex-Client-Identifier").empty());
    REQUIRE(headers.count("X-Plex-Product"));
    REQUIRE(headers.at("X-Plex-Product") == "PlaiY");
}

// ---------------------------------------------------------------------------
// Factory integration
// ---------------------------------------------------------------------------

TEST_CASE("SourceManager create_source returns Plex for Plex type") {
    SourceConfig cfg;
    cfg.source_id = "factory-plex";
    cfg.type = MediaSourceType::Plex;
    cfg.base_uri = "http://192.168.1.50:32400";

    auto src = SourceManager::create_source(std::move(cfg));
    REQUIRE(src != nullptr);
    REQUIRE(src->type() == MediaSourceType::Plex);
}

// ---------------------------------------------------------------------------
// Type and config
// ---------------------------------------------------------------------------

TEST_CASE("PlexMediaSource type returns Plex") {
    TestFixture f;
    REQUIRE(f.source->type() == MediaSourceType::Plex);
}

TEST_CASE("PlexMediaSource config returns stored config") {
    TestFixture f;
    REQUIRE(f.source->config().source_id == "plex-test-1");
    REQUIRE(f.source->config().display_name == "Test Plex");
    REQUIRE(f.source->config().base_uri == "http://192.168.1.50:32400");
}
