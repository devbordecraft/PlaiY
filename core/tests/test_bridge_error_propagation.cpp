#include <catch2/catch_test_macros.hpp>
#include "plaiy_c.h"

#include <string>

TEST_CASE("py_player_open stores last error message for invalid path argument") {
    PYPlayer* player = py_player_create();
    REQUIRE(player != nullptr);

    int rc = py_player_open(player, nullptr);
    REQUIRE(rc == PY_ERROR_INVALID_ARG);

    const char* msg = py_player_get_last_error(player);
    REQUIRE(msg != nullptr);
    REQUIRE(std::string(msg).find("Path is required") != std::string::npos);

    py_player_destroy(player);
}

TEST_CASE("py_player_open stores detailed open failure message") {
    PYPlayer* player = py_player_create();
    REQUIRE(player != nullptr);

    int rc = py_player_open(player, "/tmp/this-file-does-not-exist.mkv");
    REQUIRE(rc != PY_OK);
    const char* msg = py_player_get_last_error(player);
    REQUIRE(msg != nullptr);
    REQUIRE_FALSE(std::string(msg).empty());

    py_player_destroy(player);
}

TEST_CASE("py_source_add reports duplicate source error message") {
    PYSourceManager* sm = py_source_manager_create();
    REQUIRE(sm != nullptr);

    const char* config = R"({
        "source_id": "dup-source",
        "display_name": "Duplicate Source",
        "type": "local",
        "base_uri": "/tmp",
        "username": ""
    })";

    REQUIRE(py_source_add(sm, config) == PY_OK);
    REQUIRE(std::string(py_source_get_last_error(sm)).empty());

    int rc = py_source_add(sm, config);
    REQUIRE(rc == PY_ERROR_INVALID_ARG);
    REQUIRE(std::string(py_source_get_last_error(sm)).find("already exists") != std::string::npos);

    py_source_manager_destroy(sm);
}

TEST_CASE("py_source_connect reports missing source ID in last error") {
    PYSourceManager* sm = py_source_manager_create();
    REQUIRE(sm != nullptr);

    int rc = py_source_connect(sm, "missing-source", "");
    REQUIRE(rc == PY_ERROR_INVALID_ARG);
    REQUIRE(std::string(py_source_get_last_error(sm)).find("Source not found") != std::string::npos);

    py_source_manager_destroy(sm);
}

TEST_CASE("py_source_list_directory stores last error when source is missing") {
    PYSourceManager* sm = py_source_manager_create();
    REQUIRE(sm != nullptr);

    const char* listing = py_source_list_directory(sm, "missing-source", "");
    REQUIRE(listing != nullptr);
    REQUIRE(std::string(listing) == "[]");
    REQUIRE(std::string(py_source_get_last_error(sm)).find("Source not found") != std::string::npos);

    py_source_manager_destroy(sm);
}
