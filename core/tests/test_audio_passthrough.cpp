#include <catch2/catch_test_macros.hpp>
#include "audio/audio_passthrough.h"

extern "C" {
#include <libavcodec/avcodec.h>
}

using namespace py;

// ── is_passthrough_eligible ──

TEST_CASE("AC3 is passthrough eligible") {
    REQUIRE(is_passthrough_eligible(AV_CODEC_ID_AC3));
}

TEST_CASE("EAC3 is passthrough eligible") {
    REQUIRE(is_passthrough_eligible(AV_CODEC_ID_EAC3));
}

TEST_CASE("DTS is passthrough eligible") {
    REQUIRE(is_passthrough_eligible(AV_CODEC_ID_DTS));
}

TEST_CASE("TrueHD is passthrough eligible") {
    REQUIRE(is_passthrough_eligible(AV_CODEC_ID_TRUEHD));
}

TEST_CASE("AAC is not passthrough eligible") {
    REQUIRE_FALSE(is_passthrough_eligible(AV_CODEC_ID_AAC));
}

TEST_CASE("FLAC is not passthrough eligible") {
    REQUIRE_FALSE(is_passthrough_eligible(AV_CODEC_ID_FLAC));
}

TEST_CASE("MP3 is not passthrough eligible") {
    REQUIRE_FALSE(is_passthrough_eligible(AV_CODEC_ID_MP3));
}

// ── passthrough_bytes_per_second ──

TEST_CASE("AC3 byte rate") {
    REQUIRE(passthrough_bytes_per_second(AV_CODEC_ID_AC3) == 192000);
}

TEST_CASE("EAC3 byte rate") {
    REQUIRE(passthrough_bytes_per_second(AV_CODEC_ID_EAC3) == 768000);
}

TEST_CASE("Base DTS byte rate") {
    REQUIRE(passthrough_bytes_per_second(AV_CODEC_ID_DTS) == 192000);
}

TEST_CASE("DTS-HD MA byte rate") {
    REQUIRE(passthrough_bytes_per_second(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA) == 3072000);
}

TEST_CASE("DTS-HD HRA byte rate") {
    REQUIRE(passthrough_bytes_per_second(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_HRA) == 768000);
}

TEST_CASE("TrueHD byte rate") {
    REQUIRE(passthrough_bytes_per_second(AV_CODEC_ID_TRUEHD) == 3072000);
}

// ── requires_hdmi ──

TEST_CASE("TrueHD requires HDMI") {
    REQUIRE(requires_hdmi(AV_CODEC_ID_TRUEHD));
}

TEST_CASE("DTS-HD MA requires HDMI") {
    REQUIRE(requires_hdmi(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA));
}

TEST_CASE("DTS-HD HRA requires HDMI") {
    REQUIRE(requires_hdmi(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_HRA));
}

TEST_CASE("AC3 does not require HDMI") {
    REQUIRE_FALSE(requires_hdmi(AV_CODEC_ID_AC3));
}

TEST_CASE("EAC3 does not require HDMI") {
    REQUIRE_FALSE(requires_hdmi(AV_CODEC_ID_EAC3));
}

TEST_CASE("Base DTS does not require HDMI") {
    REQUIRE_FALSE(requires_hdmi(AV_CODEC_ID_DTS));
}

// ── is_atmos_stream ──

TEST_CASE("EAC3 with Atmos profile is Atmos") {
    REQUIRE(is_atmos_stream(AV_CODEC_ID_EAC3, AV_PROFILE_EAC3_DDP_ATMOS));
}

TEST_CASE("EAC3 without Atmos profile is not Atmos") {
    REQUIRE_FALSE(is_atmos_stream(AV_CODEC_ID_EAC3, AV_PROFILE_UNKNOWN));
}

TEST_CASE("AC3 is not Atmos") {
    REQUIRE_FALSE(is_atmos_stream(AV_CODEC_ID_AC3, AV_PROFILE_UNKNOWN));
}

// ── is_dts_hd_stream ──

TEST_CASE("DTS-HD MA is DTS-HD") {
    REQUIRE(is_dts_hd_stream(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA));
}

TEST_CASE("DTS-HD MA X is DTS-HD") {
    REQUIRE(is_dts_hd_stream(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_MA_X));
}

TEST_CASE("DTS-HD HRA is DTS-HD") {
    REQUIRE(is_dts_hd_stream(AV_CODEC_ID_DTS, AV_PROFILE_DTS_HD_HRA));
}

TEST_CASE("Base DTS is not DTS-HD") {
    REQUIRE_FALSE(is_dts_hd_stream(AV_CODEC_ID_DTS, AV_PROFILE_UNKNOWN));
}

TEST_CASE("EAC3 is not DTS-HD") {
    REQUIRE_FALSE(is_dts_hd_stream(AV_CODEC_ID_EAC3, AV_PROFILE_UNKNOWN));
}
