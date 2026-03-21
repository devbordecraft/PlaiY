#include "pgs_decoder.h"
#include "testplayer/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
}

static constexpr const char* TAG = "PgsDecoder";

namespace tp {

PgsDecoder::PgsDecoder() = default;

PgsDecoder::~PgsDecoder() {
    close();
}

Error PgsDecoder::open() {
    close();

    const AVCodec* codec = avcodec_find_decoder(AV_CODEC_ID_HDMV_PGS_SUBTITLE);
    if (!codec) {
        return {ErrorCode::UnsupportedCodec, "PGS subtitle decoder not found"};
    }

    codec_ctx_ = avcodec_alloc_context3(codec);
    if (!codec_ctx_) return {ErrorCode::OutOfMemory};

    int ret = avcodec_open2(codec_ctx_, codec, nullptr);
    if (ret < 0) {
        close();
        return {ErrorCode::DecoderInitFailed, "Failed to open PGS decoder"};
    }

    TP_LOG_INFO(TAG, "PGS subtitle decoder opened");
    return Error::Ok();
}

void PgsDecoder::close() {
    if (codec_ctx_) {
        avcodec_free_context(&codec_ctx_);
        codec_ctx_ = nullptr;
    }
}

void PgsDecoder::flush() {
    if (codec_ctx_) avcodec_flush_buffers(codec_ctx_);
}

Error PgsDecoder::decode(const Packet& pkt, SubtitleFrame& out, bool& has_output) {
    has_output = false;
    if (!codec_ctx_) return {ErrorCode::InvalidState};

    AVPacket* av_pkt = av_packet_alloc();
    if (!av_pkt) return {ErrorCode::OutOfMemory};

    av_pkt->data = const_cast<uint8_t*>(pkt.data.data());
    av_pkt->size = static_cast<int>(pkt.data.size());
    av_pkt->pts = pkt.pts;
    av_pkt->dts = pkt.dts;

    AVSubtitle sub = {};
    int got_sub = 0;
    int ret = avcodec_decode_subtitle2(codec_ctx_, &sub, &got_sub, av_pkt);
    av_packet_free(&av_pkt);

    if (ret < 0) {
        return {ErrorCode::SubtitleError, "PGS decode error"};
    }

    if (!got_sub) return Error::Ok();

    // Convert to our format
    int64_t pts_us = pkt.pts_us();
    out.start_us = pts_us + static_cast<int64_t>(sub.start_display_time) * 1000LL;
    out.end_us = pts_us + static_cast<int64_t>(sub.end_display_time) * 1000LL;
    out.is_text = false;

    for (unsigned i = 0; i < sub.num_rects; i++) {
        AVSubtitleRect* rect = sub.rects[i];
        if (rect->type != SUBTITLE_BITMAP) continue;

        SubtitleFrame::BitmapRegion region;
        region.width = rect->w;
        region.height = rect->h;
        region.x = rect->x;
        region.y = rect->y;

        // Convert paletted bitmap to RGBA
        region.rgba_data.resize(rect->w * rect->h * 4);
        const uint32_t* palette = reinterpret_cast<const uint32_t*>(rect->data[1]);

        for (int y = 0; y < rect->h; y++) {
            for (int x = 0; x < rect->w; x++) {
                uint8_t idx = rect->data[0][y * rect->linesize[0] + x];
                uint32_t color = palette[idx]; // ARGB format in FFmpeg
                uint8_t a = (color >> 24) & 0xFF;
                uint8_t r = (color >> 16) & 0xFF;
                uint8_t g = (color >> 8) & 0xFF;
                uint8_t b = color & 0xFF;
                int dst = (y * rect->w + x) * 4;
                region.rgba_data[dst + 0] = r;
                region.rgba_data[dst + 1] = g;
                region.rgba_data[dst + 2] = b;
                region.rgba_data[dst + 3] = a;
            }
        }

        out.regions.push_back(std::move(region));
    }

    has_output = !out.regions.empty();
    avsubtitle_free(&sub);
    return Error::Ok();
}

} // namespace tp
