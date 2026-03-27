#include <catch2/catch_test_macros.hpp>
#include "plaiy/source_manager.h"
#include "plaiy/media_source.h"

using namespace py;

// ---- SourceConfig / SourceEntry basic tests ----

TEST_CASE("SourceConfig default values") {
    SourceConfig cfg;
    REQUIRE(cfg.source_id.empty());
    REQUIRE(cfg.display_name.empty());
    REQUIRE(cfg.type == MediaSourceType::Local);
    REQUIRE(cfg.base_uri.empty());
    REQUIRE(cfg.username.empty());
    REQUIRE(cfg.password.empty());
}

TEST_CASE("SourceEntry default values") {
    SourceEntry entry;
    REQUIRE(entry.name.empty());
    REQUIRE(entry.uri.empty());
    REQUIRE(entry.is_directory == false);
    REQUIRE(entry.size == 0);
}

// ---- SourceManager lifecycle ----

TEST_CASE("SourceManager starts empty") {
    SourceManager mgr;
    REQUIRE(mgr.source_count() == 0);
    REQUIRE(mgr.source_at(0) == nullptr);
    REQUIRE(mgr.source_at(-1) == nullptr);
    REQUIRE(mgr.source_by_id("nonexistent") == nullptr);
}

TEST_CASE("SourceManager add_source requires non-empty source_id") {
    SourceManager mgr;
    SourceConfig cfg;
    cfg.source_id = "";
    Error err = mgr.add_source(cfg);
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidArgument);
    REQUIRE(mgr.source_count() == 0);
}

TEST_CASE("SourceManager add and retrieve Local source") {
    SourceManager mgr;
    SourceConfig cfg;
    cfg.source_id = "test-local-1";
    cfg.display_name = "Test Local";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    Error err = mgr.add_source(cfg);
    REQUIRE(err.ok());
    REQUIRE(mgr.source_count() == 1);

    IMediaSource* src = mgr.source_at(0);
    REQUIRE(src != nullptr);
    REQUIRE(src->type() == MediaSourceType::Local);
    REQUIRE(src->config().source_id == "test-local-1");
    REQUIRE(src->config().display_name == "Test Local");
    REQUIRE(src->config().base_uri == "/tmp");
}

TEST_CASE("SourceManager source_by_id works") {
    SourceManager mgr;
    SourceConfig cfg;
    cfg.source_id = "lookup-test";
    cfg.display_name = "Lookup";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";
    mgr.add_source(cfg);

    REQUIRE(mgr.source_by_id("lookup-test") != nullptr);
    REQUIRE(mgr.source_by_id("lookup-test")->config().display_name == "Lookup");
    REQUIRE(mgr.source_by_id("other-id") == nullptr);
}

TEST_CASE("SourceManager rejects duplicate source_id") {
    SourceManager mgr;
    SourceConfig cfg;
    cfg.source_id = "dupe";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    REQUIRE(mgr.add_source(cfg).ok());
    Error err = mgr.add_source(cfg);
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidArgument);
    REQUIRE(mgr.source_count() == 1);
}

TEST_CASE("SourceManager remove_source") {
    SourceManager mgr;
    SourceConfig cfg;
    cfg.source_id = "to-remove";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";
    mgr.add_source(cfg);
    REQUIRE(mgr.source_count() == 1);

    mgr.remove_source("to-remove");
    REQUIRE(mgr.source_count() == 0);
    REQUIRE(mgr.source_by_id("to-remove") == nullptr);
}

TEST_CASE("SourceManager remove_source with nonexistent id is no-op") {
    SourceManager mgr;
    mgr.remove_source("does-not-exist");
    REQUIRE(mgr.source_count() == 0);
}

TEST_CASE("SourceManager add multiple sources and access by index") {
    SourceManager mgr;

    SourceConfig c1;
    c1.source_id = "src-1";
    c1.display_name = "First";
    c1.type = MediaSourceType::Local;
    c1.base_uri = "/tmp/a";
    mgr.add_source(c1);

    SourceConfig c2;
    c2.source_id = "src-2";
    c2.display_name = "Second";
    c2.type = MediaSourceType::Local;
    c2.base_uri = "/tmp/b";
    mgr.add_source(c2);

    REQUIRE(mgr.source_count() == 2);
    REQUIRE(mgr.source_at(0)->config().source_id == "src-1");
    REQUIRE(mgr.source_at(1)->config().source_id == "src-2");
    REQUIRE(mgr.source_at(2) == nullptr);
}

// ---- JSON serialization ----

TEST_CASE("SourceManager configs_json serializes sources") {
    SourceManager mgr;
    SourceConfig cfg;
    cfg.source_id = "json-test";
    cfg.display_name = "JSON Source";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp/media";
    cfg.username = "user1";
    cfg.password = "secret";
    mgr.add_source(cfg);

    std::string json = mgr.configs_json();
    REQUIRE_FALSE(json.empty());
    REQUIRE(json != "[]");

    // Verify key fields are present
    REQUIRE(json.find("json-test") != std::string::npos);
    REQUIRE(json.find("JSON Source") != std::string::npos);
    REQUIRE(json.find("local") != std::string::npos);
    REQUIRE(json.find("/tmp/media") != std::string::npos);
    REQUIRE(json.find("user1") != std::string::npos);

    // Password must NOT be serialized
    REQUIRE(json.find("secret") == std::string::npos);
}

TEST_CASE("SourceManager configs_json for empty manager returns empty array") {
    SourceManager mgr;
    REQUIRE(mgr.configs_json() == "[]");
}

TEST_CASE("SourceManager load_configs_json roundtrips") {
    // Create a manager, add sources, serialize
    SourceManager mgr1;
    SourceConfig c1;
    c1.source_id = "rt-1";
    c1.display_name = "Roundtrip 1";
    c1.type = MediaSourceType::Local;
    c1.base_uri = "/tmp/rt1";
    c1.username = "u1";
    mgr1.add_source(c1);

    SourceConfig c2;
    c2.source_id = "rt-2";
    c2.display_name = "Roundtrip 2";
    c2.type = MediaSourceType::SMB;
    c2.base_uri = "smb://192.168.1.1/share";
    mgr1.add_source(c2);

    std::string json = mgr1.configs_json();

    // Load into a fresh manager
    SourceManager mgr2;
    Error err = mgr2.load_configs_json(json);
    REQUIRE(err.ok());
    REQUIRE(mgr2.source_count() == 2);

    auto* s1 = mgr2.source_by_id("rt-1");
    REQUIRE(s1 != nullptr);
    REQUIRE(s1->config().display_name == "Roundtrip 1");
    REQUIRE(s1->type() == MediaSourceType::Local);

    auto* s2 = mgr2.source_by_id("rt-2");
    REQUIRE(s2 != nullptr);
    REQUIRE(s2->config().display_name == "Roundtrip 2");
    REQUIRE(s2->type() == MediaSourceType::SMB);
    REQUIRE(s2->config().base_uri == "smb://192.168.1.1/share");
}

TEST_CASE("SourceManager load_configs_json rejects invalid JSON") {
    SourceManager mgr;
    Error err = mgr.load_configs_json("not valid json");
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidArgument);
}

TEST_CASE("SourceManager load_configs_json rejects non-array JSON") {
    SourceManager mgr;
    Error err = mgr.load_configs_json("{\"key\": \"value\"}");
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::InvalidArgument);
}

TEST_CASE("SourceManager load_configs_json skips entries with empty source_id") {
    SourceManager mgr;
    Error err = mgr.load_configs_json(R"([{"source_id":"","type":"local"}])");
    REQUIRE(err.ok());
    REQUIRE(mgr.source_count() == 0);
}

// ---- Factory ----

TEST_CASE("SourceManager create_source returns Local for Local type") {
    SourceConfig cfg;
    cfg.source_id = "factory-local";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    auto src = SourceManager::create_source(std::move(cfg));
    REQUIRE(src != nullptr);
    REQUIRE(src->type() == MediaSourceType::Local);
}

TEST_CASE("SourceManager create_source returns SMB for SMB type") {
    SourceConfig cfg;
    cfg.source_id = "factory-smb";
    cfg.type = MediaSourceType::SMB;
    cfg.base_uri = "smb://server/share";

    auto src = SourceManager::create_source(std::move(cfg));
    REQUIRE(src != nullptr);
    REQUIRE(src->type() == MediaSourceType::SMB);
}

TEST_CASE("SourceManager create_source returns null for unsupported types") {
    SourceConfig cfg;
    cfg.source_id = "factory-nfs";
    cfg.type = MediaSourceType::NFS;

    auto src = SourceManager::create_source(std::move(cfg));
    REQUIRE(src == nullptr);
}

// ---- LocalMediaSource ----

TEST_CASE("LocalMediaSource connect succeeds for valid directory") {
    SourceConfig cfg;
    cfg.source_id = "local-connect";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    auto src = SourceManager::create_source(std::move(cfg));
    REQUIRE(src != nullptr);

    Error err = src->connect();
    REQUIRE(err.ok());
    REQUIRE(src->is_connected());
}

TEST_CASE("LocalMediaSource connect fails for nonexistent path") {
    SourceConfig cfg;
    cfg.source_id = "local-bad";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/nonexistent_path_12345";

    auto src = SourceManager::create_source(std::move(cfg));
    REQUIRE(src != nullptr);

    Error err = src->connect();
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::FileNotFound);
}

TEST_CASE("LocalMediaSource list_directory returns entries for /tmp") {
    SourceConfig cfg;
    cfg.source_id = "local-list";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    auto src = SourceManager::create_source(std::move(cfg));
    src->connect();

    std::vector<SourceEntry> entries;
    Error err = src->list_directory("", entries);
    REQUIRE(err.ok());
    // /tmp typically has at least a few files/dirs
    // Just verify the call works without error
}

TEST_CASE("LocalMediaSource list_directory fails for nonexistent subpath") {
    SourceConfig cfg;
    cfg.source_id = "local-list-bad";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    auto src = SourceManager::create_source(std::move(cfg));
    src->connect();

    std::vector<SourceEntry> entries;
    Error err = src->list_directory("nonexistent_subdir_xyz", entries);
    REQUIRE(err);
    REQUIRE(err.code == ErrorCode::FileNotFound);
}

TEST_CASE("LocalMediaSource playable_path returns entry uri unchanged") {
    SourceConfig cfg;
    cfg.source_id = "local-path";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    auto src = SourceManager::create_source(std::move(cfg));

    SourceEntry entry;
    entry.uri = "/tmp/test/movie.mkv";
    REQUIRE(src->playable_path(entry) == "/tmp/test/movie.mkv");
}

TEST_CASE("LocalMediaSource disconnect is no-op") {
    SourceConfig cfg;
    cfg.source_id = "local-disconnect";
    cfg.type = MediaSourceType::Local;
    cfg.base_uri = "/tmp";

    auto src = SourceManager::create_source(std::move(cfg));
    src->connect();
    REQUIRE(src->is_connected());

    src->disconnect();
    // Still "connected" since /tmp still exists
    REQUIRE(src->is_connected());
}

// ---- MediaSourceType enum ----

TEST_CASE("MediaSourceType enum values are distinct") {
    REQUIRE(MediaSourceType::Local != MediaSourceType::SMB);
    REQUIRE(MediaSourceType::SMB != MediaSourceType::NFS);
    REQUIRE(MediaSourceType::NFS != MediaSourceType::HTTP);
    REQUIRE(MediaSourceType::HTTP != MediaSourceType::Plex);
}

// ---- NetworkError code ----

TEST_CASE("NetworkError code is usable") {
    Error e(ErrorCode::NetworkError, "connection refused");
    REQUIRE(e);
    REQUIRE(e.code == ErrorCode::NetworkError);
    REQUIRE(e.message == "connection refused");
}
