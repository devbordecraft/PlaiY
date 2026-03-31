#include "video_decoder_factory.h"
#include "ff_video_decoder.h"
#include "plaiy/logger.h"
#include "plaiy/types.h"

#ifdef __APPLE__
#include "../../platform/apple/vt_video_decoder.h"
#endif

extern "C" {
#include <libavcodec/avcodec.h>
}

static constexpr const char* TAG = "DecoderFactory";

namespace py {

std::unique_ptr<IVideoDecoder> VideoDecoderFactory::create(
        const TrackInfo& track, HWDecodePreference hw_pref) {
#ifdef __APPLE__
    if (hw_pref != HWDecodePreference::ForceSoftware) {
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

        // HDR10+: use FFmpeg SW decoder so per-frame dynamic metadata
        // (bezier curves) is available via AVFrame side data.
        // VideoToolbox strips this metadata from the bitstream.
        if (vt_candidate && track.hdr_metadata.type == HDRType::HDR10Plus) {
            PY_LOG_INFO(TAG, "HDR10+ content: using FFmpeg decoder for dynamic metadata");
            vt_candidate = false;
        }

        // Any DV content reaching this factory must use FFmpeg.
        // VT corrupts IPTPQc2 chroma during its internal pixel format conversion.
        if (vt_candidate && track.dv_profile > 0) {
            PY_LOG_INFO(TAG, "DV Profile %d: forcing FFmpeg (skip VT)", track.dv_profile);
            vt_candidate = false;
        }

        if (vt_candidate) {
            auto vt = std::make_unique<VTVideoDecoder>();
            Error err = vt->open(track);
            if (err.ok()) {
                PY_LOG_INFO(TAG, "Using VideoToolbox for %s", track.codec_name.c_str());
                return vt;
            }
            if (hw_pref == HWDecodePreference::ForceHardware) {
                PY_LOG_ERROR(TAG, "ForceHardware: VideoToolbox failed for %s: %s",
                             track.codec_name.c_str(), err.message.c_str());
                return nullptr;
            }
            PY_LOG_WARN(TAG, "VideoToolbox failed for %s: %s, falling back to FFmpeg",
                        track.codec_name.c_str(), err.message.c_str());
        } else if (hw_pref == HWDecodePreference::ForceHardware) {
            PY_LOG_WARN(TAG, "ForceHardware requested but codec/HDR requires SW decoder, using FFmpeg");
        }
    } else {
        PY_LOG_INFO(TAG, "ForceSoftware: skipping VideoToolbox for %s", track.codec_name.c_str());
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
