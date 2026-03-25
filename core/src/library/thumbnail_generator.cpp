#include "thumbnail_generator.h"
#include "ffmpeg_video_opener.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
}

#include <cstdio>

static constexpr const char* TAG = "Thumbnail";

namespace py {

bool ThumbnailGenerator::generate(const std::string& video_path,
                                   const std::string& output_path,
                                   int max_width, int max_height) {
    FFmpegVideoOpener opener;
    if (!opener.open(video_path)) {
        return false;
    }

    AVFormatContext* fmt = opener.fmt;
    AVCodecContext* dec = opener.dec;
    int video_idx = opener.stream_index;

    // Seek to 10% of duration
    if (fmt->duration > 0) {
        int64_t target = fmt->duration / 10; // 10% in AV_TIME_BASE units
        av_seek_frame(fmt, -1, target, AVSEEK_FLAG_BACKWARD);
    }

    // Decode one frame
    AVFrame* frame = av_frame_alloc();
    AVPacket* pkt = av_packet_alloc();
    bool got_frame = false;
    int attempts = 0;
    int ret;

    while (!got_frame && attempts < 60) {
        ret = av_read_frame(fmt, pkt);
        if (ret < 0) break;

        if (pkt->stream_index != video_idx) {
            av_packet_unref(pkt);
            attempts++;
            continue;
        }

        ret = avcodec_send_packet(dec, pkt);
        av_packet_unref(pkt);
        if (ret < 0) {
            attempts++;
            continue;
        }

        ret = avcodec_receive_frame(dec, frame);
        if (ret == 0) {
            got_frame = true;
        }
        attempts++;
    }

    if (!got_frame) {
        PY_LOG_WARN(TAG, "no frame decoded for: %s", video_path.c_str());
        av_frame_free(&frame);
        av_packet_free(&pkt);
        return false;
    }

    // Calculate scaled dimensions preserving aspect ratio
    int src_w = frame->width;
    int src_h = frame->height;
    double scale = std::min(static_cast<double>(max_width) / src_w,
                            static_cast<double>(max_height) / src_h);
    // Don't upscale
    if (scale > 1.0) scale = 1.0;
    int dst_w = static_cast<int>(src_w * scale) & ~1; // even dimensions
    int dst_h = static_cast<int>(src_h * scale) & ~1;
    if (dst_w < 2) dst_w = 2;
    if (dst_h < 2) dst_h = 2;

    // Scale to YUVJ420P (JPEG-compatible YUV)
    SwsContext* sws = sws_getContext(
        src_w, src_h, static_cast<AVPixelFormat>(frame->format),
        dst_w, dst_h, AV_PIX_FMT_YUVJ420P,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);

    if (!sws) {
        av_frame_free(&frame);
        av_packet_free(&pkt);
        return false;
    }

    AVFrame* scaled = av_frame_alloc();
    scaled->format = AV_PIX_FMT_YUVJ420P;
    scaled->width = dst_w;
    scaled->height = dst_h;
    if (av_frame_get_buffer(scaled, 0) < 0) {
        av_frame_free(&scaled);
        sws_freeContext(sws);
        av_frame_free(&frame);
        av_packet_free(&pkt);
        return false;
    }

    sws_scale(sws, frame->data, frame->linesize, 0, src_h,
              scaled->data, scaled->linesize);
    sws_freeContext(sws);
    av_frame_free(&frame);

    // Encode as JPEG
    const AVCodec* mjpeg = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
    if (!mjpeg) {
        av_frame_free(&scaled);
        av_packet_free(&pkt);
        return false;
    }

    AVCodecContext* enc = avcodec_alloc_context3(mjpeg);
    enc->pix_fmt = AV_PIX_FMT_YUVJ420P;
    enc->width = dst_w;
    enc->height = dst_h;
    enc->time_base = {1, 1};
    // Quality: 2-31, lower = better. ~5 gives good quality at small size.
    enc->qmin = 2;
    enc->qmax = 8;

    ret = avcodec_open2(enc, mjpeg, nullptr);
    if (ret < 0) {
        avcodec_free_context(&enc);
        av_frame_free(&scaled);
        av_packet_free(&pkt);
        return false;
    }

    ret = avcodec_send_frame(enc, scaled);
    av_frame_free(&scaled);
    if (ret < 0) {
        avcodec_free_context(&enc);
        av_packet_free(&pkt);
        return false;
    }

    ret = avcodec_receive_packet(enc, pkt);
    bool success = false;
    if (ret == 0) {
        FILE* f = fopen(output_path.c_str(), "wb");
        if (f) {
            fwrite(pkt->data, 1, static_cast<size_t>(pkt->size), f);
            fclose(f);
            success = true;
            PY_LOG_DEBUG(TAG, "generated %dx%d (%d bytes): %s",
                         dst_w, dst_h, pkt->size, output_path.c_str());
        }
    }

    av_packet_unref(pkt);
    av_packet_free(&pkt);
    avcodec_free_context(&enc);
    return success;
}

} // namespace py
