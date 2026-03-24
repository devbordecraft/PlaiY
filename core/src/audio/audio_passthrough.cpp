#include "audio_passthrough.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavcodec/defs.h>
}

namespace py {

bool is_passthrough_eligible(int codec_id, int /*codec_profile*/) {
    return codec_id == AV_CODEC_ID_AC3 ||
           codec_id == AV_CODEC_ID_EAC3 ||
           codec_id == AV_CODEC_ID_DTS ||
           codec_id == AV_CODEC_ID_TRUEHD;
}

int passthrough_bytes_per_second(int codec_id, int codec_profile) {
    // SPDIF transport: 48000 Hz * 2ch * 2 bytes = 192000 bytes/s
    // These are approximate upper bounds for ring buffer sizing.
    switch (codec_id) {
        case AV_CODEC_ID_AC3:    return 192000;    // 48kHz stereo 16-bit SPDIF
        case AV_CODEC_ID_EAC3:   return 768000;    // 4x AC3 bandwidth
        case AV_CODEC_ID_DTS:
            // DTS-HD MA and HRA require HDMI and have much higher bitrates
            if (codec_profile == AV_PROFILE_DTS_HD_MA ||
                codec_profile == AV_PROFILE_DTS_HD_MA_X ||
                codec_profile == AV_PROFILE_DTS_HD_MA_X_IMAX) return 3072000;
            if (codec_profile == AV_PROFILE_DTS_HD_HRA) return 768000;
            return 192000;    // Base DTS over SPDIF
        case AV_CODEC_ID_TRUEHD: return 3072000;   // HDMI high bitrate
        default:                  return 192000;
    }
}

bool requires_hdmi(int codec_id, int codec_profile) {
    if (codec_id == AV_CODEC_ID_TRUEHD) return true;
    if (codec_id == AV_CODEC_ID_DTS &&
        (codec_profile == AV_PROFILE_DTS_HD_MA ||
         codec_profile == AV_PROFILE_DTS_HD_MA_X ||
         codec_profile == AV_PROFILE_DTS_HD_MA_X_IMAX ||
         codec_profile == AV_PROFILE_DTS_HD_HRA)) return true;
    return false;
}

bool is_atmos_stream(int codec_id, int codec_profile) {
    return codec_id == AV_CODEC_ID_EAC3 && codec_profile == AV_PROFILE_EAC3_DDP_ATMOS;
}

bool is_dts_hd_stream(int codec_id, int codec_profile) {
    return codec_id == AV_CODEC_ID_DTS &&
           (codec_profile == AV_PROFILE_DTS_HD_MA ||
            codec_profile == AV_PROFILE_DTS_HD_MA_X ||
            codec_profile == AV_PROFILE_DTS_HD_MA_X_IMAX ||
            codec_profile == AV_PROFILE_DTS_HD_HRA);
}

} // namespace py
