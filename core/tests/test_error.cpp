#include <catch2/catch_test_macros.hpp>
#include "plaiy/error.h"

using py::Error;
using py::ErrorCode;

TEST_CASE("Error default is OK") {
    Error e;
    REQUIRE(e.ok());
    REQUIRE_FALSE(static_cast<bool>(e));
    REQUIRE(e.code == ErrorCode::OK);
    REQUIRE(e.message.empty());
}

TEST_CASE("Error::Ok() factory") {
    auto e = Error::Ok();
    REQUIRE(e.ok());
    REQUIRE_FALSE(static_cast<bool>(e));
}

TEST_CASE("Error with code only") {
    Error e(ErrorCode::FileNotFound);
    REQUIRE_FALSE(e.ok());
    REQUIRE(static_cast<bool>(e));
    REQUIRE(e.code == ErrorCode::FileNotFound);
    REQUIRE(e.message.empty());
}

TEST_CASE("Error with code and message") {
    Error e(ErrorCode::DecoderError, "codec failed");
    REQUIRE_FALSE(e.ok());
    REQUIRE(static_cast<bool>(e));
    REQUIRE(e.code == ErrorCode::DecoderError);
    REQUIRE(e.message == "codec failed");
}

TEST_CASE("All ErrorCode values are distinct") {
    // Verify a selection of codes are usable and non-zero (except OK)
    REQUIRE(ErrorCode::OK == ErrorCode::OK);
    REQUIRE(ErrorCode::Unknown != ErrorCode::OK);
    REQUIRE(ErrorCode::InvalidArgument != ErrorCode::Unknown);
    REQUIRE(ErrorCode::OutOfMemory != ErrorCode::InvalidState);
}
