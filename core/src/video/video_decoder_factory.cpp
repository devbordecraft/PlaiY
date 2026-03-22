#include "video_decoder_factory.h"
#include "ff_video_decoder.h"
#include "plaiy/logger.h"

#ifdef __APPLE__
#include "../../platform/apple/vt_video_decoder.h"
#endif

extern "C" {
#include <libavcodec/avcodec.h>
}

static constexpr const char* TAG = "DecoderFactory";

namespace py {

std::unique_ptr<IVideoDecoder> VideoDecoderFactory::create(const TrackInfo& track) {
#ifdef __APPLE__
    // Try VideoToolbox for supported codecs
    bool vt_candidate = false;
    switch (static_cast<AVCodecID>(track.codec_id)) {
        case AV_CODEC_ID_H264:
        case AV_CODEC_ID_HEVC:
        case AV_CODEC_ID_VP9:
        case AV_CODEC_ID_AV1:
            vt_candidate = true;
            break;
        default:
            break;
    }

    if (vt_candidate) {
        auto vt = std::make_unique<VTVideoDecoder>();
        Error err = vt->open(track);
        if (err.ok()) {
            PY_LOG_INFO(TAG, "Using VideoToolbox for %s", track.codec_name.c_str());
            return vt;
        }
        PY_LOG_WARN(TAG, "VideoToolbox failed for %s: %s, falling back to FFmpeg",
                    track.codec_name.c_str(), err.message.c_str());
    }
#endif

    // FFmpeg software decoder
    auto ff = std::make_unique<FFVideoDecoder>();
    Error err = ff->open(track);
    if (err.ok()) {
        PY_LOG_INFO(TAG, "Using FFmpeg software decoder for %s", track.codec_name.c_str());
        return ff;
    }

    PY_LOG_ERROR(TAG, "No decoder available for %s: %s", track.codec_name.c_str(), err.message.c_str());
    return nullptr;
}

} // namespace py
