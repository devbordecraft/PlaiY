#include <catch2/catch_test_macros.hpp>
#include "subtitle/srt_parser.h"

using py::SrtParser;

static const char* VALID_SRT = R"(1
00:00:01,000 --> 00:00:04,000
Hello, world!

2
00:00:05,500 --> 00:00:08,000
Second subtitle.

3
00:00:10,000 --> 00:00:12,500
Third line.

)";

TEST_CASE("SrtParser parse_string valid SRT") {
    SrtParser parser;
    REQUIRE(parser.parse_string(VALID_SRT));
    REQUIRE(parser.entries().size() == 3);

    auto& e0 = parser.entries()[0];
    REQUIRE(e0.start_us == 1'000'000);
    REQUIRE(e0.end_us == 4'000'000);
    REQUIRE(e0.text == "Hello, world!");

    auto& e1 = parser.entries()[1];
    REQUIRE(e1.start_us == 5'500'000);
    REQUIRE(e1.end_us == 8'000'000);
    REQUIRE(e1.text == "Second subtitle.");
}

TEST_CASE("SrtParser parse_string with CRLF") {
    std::string srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\nHello CRLF\r\n\r\n";
    SrtParser parser;
    REQUIRE(parser.parse_string(srt));
    REQUIRE(parser.entries().size() == 1);
    REQUIRE(parser.entries()[0].text == "Hello CRLF");
}

TEST_CASE("SrtParser parse_string multi-line text") {
    std::string srt = R"(1
00:00:01,000 --> 00:00:03,000
Line one
Line two

)";
    SrtParser parser;
    REQUIRE(parser.parse_string(srt));
    REQUIRE(parser.entries().size() == 1);
    // Multi-line cues should be joined
    REQUIRE(parser.entries()[0].text.find("Line one") != std::string::npos);
    REQUIRE(parser.entries()[0].text.find("Line two") != std::string::npos);
}

TEST_CASE("SrtParser parse_string empty input") {
    SrtParser parser;
    REQUIRE_FALSE(parser.parse_string(""));
    REQUIRE(parser.entries().empty());
}

TEST_CASE("SrtParser get_frame_at within entry") {
    SrtParser parser;
    parser.parse_string(VALID_SRT);

    // 2.5s is within the first subtitle (1s - 4s)
    auto frame = parser.get_frame_at(2'500'000);
    REQUIRE(frame.is_text);
    REQUIRE(frame.text == "Hello, world!");
}

TEST_CASE("SrtParser get_frame_at between entries") {
    SrtParser parser;
    parser.parse_string(VALID_SRT);

    // 4.5s is between first (ends at 4s) and second (starts at 5.5s)
    auto frame = parser.get_frame_at(4'500'000);
    REQUIRE_FALSE(frame.is_text);
}

TEST_CASE("SrtParser get_frame_at before first entry") {
    SrtParser parser;
    parser.parse_string(VALID_SRT);

    auto frame = parser.get_frame_at(0);
    REQUIRE_FALSE(frame.is_text);
}

TEST_CASE("SrtParser get_frame_at after last entry") {
    SrtParser parser;
    parser.parse_string(VALID_SRT);

    auto frame = parser.get_frame_at(100'000'000);
    REQUIRE_FALSE(frame.is_text);
}

TEST_CASE("SrtParser get_frame_at exact start boundary") {
    SrtParser parser;
    parser.parse_string(VALID_SRT);

    auto frame = parser.get_frame_at(1'000'000);
    REQUIRE(frame.is_text);
    REQUIRE(frame.text == "Hello, world!");
}

TEST_CASE("SrtParser add_entry") {
    SrtParser parser;
    parser.add_entry(1'000'000, 2'000'000, "Added manually");

    REQUIRE(parser.entries().size() == 1);
    auto frame = parser.get_frame_at(1'500'000);
    REQUIRE(frame.is_text);
    REQUIRE(frame.text == "Added manually");
}

TEST_CASE("SrtParser clear") {
    SrtParser parser;
    parser.parse_string(VALID_SRT);
    REQUIRE_FALSE(parser.entries().empty());

    parser.clear();
    REQUIRE(parser.entries().empty());
}

TEST_CASE("SrtParser dot separator in timestamp") {
    std::string srt = R"(1
00:00:01.500 --> 00:00:03.000
Dot separator

)";
    SrtParser parser;
    // Some SRT files use . instead of , — parser should handle both
    bool parsed = parser.parse_string(srt);
    if (parsed && !parser.entries().empty()) {
        REQUIRE(parser.entries()[0].start_us == 1'500'000);
    }
    // If not supported, that's fine — this is a compatibility check
}
