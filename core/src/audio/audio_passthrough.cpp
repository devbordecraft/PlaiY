#include "audio_passthrough.h"

extern "C" {
#include <libavcodec/avcodec.h>
}

namespace py {

bool is_passthrough_eligible(int codec_id) {
    return codec_id == AV_CODEC_ID_AC3 ||
           codec_id == AV_CODEC_ID_EAC3 ||
           codec_id == AV_CODEC_ID_DTS ||
           codec_id == AV_CODEC_ID_TRUEHD;
}

int passthrough_bytes_per_second(int codec_id) {
    // SPDIF transport: 48000 Hz * 2ch * 2 bytes = 192000 bytes/s
    // These are approximate upper bounds for ring buffer sizing.
    switch (codec_id) {
        case AV_CODEC_ID_AC3:    return 192000;    // 48kHz stereo 16-bit SPDIF
        case AV_CODEC_ID_EAC3:   return 768000;    // 4x AC3 bandwidth
        case AV_CODEC_ID_DTS:    return 192000;    // Same as AC3 over SPDIF
        case AV_CODEC_ID_TRUEHD: return 3072000;   // HDMI high bitrate
        default:                  return 192000;
    }
}

} // namespace py
