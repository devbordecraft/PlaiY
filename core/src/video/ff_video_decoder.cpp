#include "ff_video_decoder.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
}

static constexpr const char* TAG = "FFVideoDecoder";

namespace py {

FFVideoDecoder::FFVideoDecoder() = default;

FFVideoDecoder::~FFVideoDecoder() {
    close();
}

Error FFVideoDecoder::open(const TrackInfo& track) {
    close();
    track_info_ = track;

    const AVCodec* codec = avcodec_find_decoder(static_cast<AVCodecID>(track.codec_id));
    if (!codec) {
        return {ErrorCode::UnsupportedCodec, "No FFmpeg decoder for codec: " + track.codec_name};
    }

    codec_ctx_ = avcodec_alloc_context3(codec);
    if (!codec_ctx_) {
        return {ErrorCode::OutOfMemory, "Failed to allocate codec context"};
    }

    codec_ctx_->width = track.width;
    codec_ctx_->height = track.height;
    codec_ctx_->pix_fmt = AV_PIX_FMT_NONE;

    // Set extradata
    if (!track.extradata.empty()) {
        codec_ctx_->extradata_size = static_cast<int>(track.extradata.size());
        codec_ctx_->extradata = static_cast<uint8_t*>(
            av_mallocz(track.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        if (codec_ctx_->extradata) {
            memcpy(codec_ctx_->extradata, track.extradata.data(), track.extradata.size());
        }
    }

    // Request multi-threaded decoding
    codec_ctx_->thread_count = 0; // auto
    codec_ctx_->thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE;

    int ret = avcodec_open2(codec_ctx_, codec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        close();
        return {ErrorCode::DecoderInitFailed, std::string("Failed to open decoder: ") + errbuf};
    }

    av_frame_ = av_frame_alloc();
    if (!av_frame_) {
        close();
        return {ErrorCode::OutOfMemory, "Failed to allocate frame"};
    }

    PY_LOG_INFO(TAG, "Opened software decoder: %s (%dx%d)", codec->name, track.width, track.height);
    return Error::Ok();
}

void FFVideoDecoder::close() {
    if (reuse_pkt_) {
        av_packet_free(&reuse_pkt_);
        reuse_pkt_ = nullptr;
    }
    if (av_frame_) {
        av_frame_free(&av_frame_);
        av_frame_ = nullptr;
    }
    if (codec_ctx_) {
        avcodec_free_context(&codec_ctx_);
        codec_ctx_ = nullptr;
    }
}

void FFVideoDecoder::flush() {
    if (codec_ctx_) {
        avcodec_flush_buffers(codec_ctx_);
    }
}

Error FFVideoDecoder::send_packet(const Packet& pkt) {
    if (!codec_ctx_) return {ErrorCode::InvalidState, "Decoder not open"};

    // Set pkt_timebase from the first real packet so PTS conversion works
    if (codec_ctx_->pkt_timebase.den == 0 && !pkt.is_flush && pkt.time_base_den > 0) {
        codec_ctx_->pkt_timebase = AVRational{pkt.time_base_num, pkt.time_base_den};
    }

    if (!reuse_pkt_) {
        reuse_pkt_ = av_packet_alloc();
        if (!reuse_pkt_) return {ErrorCode::OutOfMemory};
    }
    av_packet_unref(reuse_pkt_);

    if (pkt.is_flush) {
        reuse_pkt_->data = nullptr;
        reuse_pkt_->size = 0;
    } else {
        reuse_pkt_->data = const_cast<uint8_t*>(pkt.data.data());
        reuse_pkt_->size = static_cast<int>(pkt.data.size());
        reuse_pkt_->pts = pkt.pts;
        reuse_pkt_->dts = pkt.dts;
        reuse_pkt_->duration = pkt.duration;
    }

    int ret = avcodec_send_packet(codec_ctx_, pkt.is_flush ? nullptr : reuse_pkt_);

    if (ret == AVERROR(EAGAIN)) return {ErrorCode::NeedMoreInput};
    if (ret == AVERROR_EOF) return {ErrorCode::EndOfFile};
    if (ret < 0) return {ErrorCode::DecoderError, "send_packet failed"};

    return Error::Ok();
}

Error FFVideoDecoder::receive_frame(VideoFrame& out) {
    if (!codec_ctx_ || !av_frame_) return {ErrorCode::InvalidState};

    int ret = avcodec_receive_frame(codec_ctx_, av_frame_);
    if (ret == AVERROR(EAGAIN)) return {ErrorCode::OutputNotReady};
    if (ret == AVERROR_EOF) return {ErrorCode::EndOfFile};
    if (ret < 0) return {ErrorCode::DecoderError, "receive_frame failed"};

    fill_frame(av_frame_, out);
    av_frame_unref(av_frame_);
    return Error::Ok();
}

void FFVideoDecoder::fill_frame(const AVFrame* av_frame, VideoFrame& out) {
    out.width = av_frame->width;
    out.height = av_frame->height;
    out.hardware_frame = false;
    out.color_space = av_frame->colorspace;
    out.color_primaries = av_frame->color_primaries;
    out.color_trc = av_frame->color_trc;

    // PTS in microseconds
    if (av_frame->pts != AV_NOPTS_VALUE) {
        AVRational tb = codec_ctx_->time_base;
        // Use pkt_timebase if available (more reliable)
        if (codec_ctx_->pkt_timebase.den > 0) {
            tb = codec_ctx_->pkt_timebase;
        }
        out.pts_us = av_rescale_q(av_frame->pts, tb, {1, 1000000});
    }
    out.duration_us = av_frame->duration > 0
        ? av_rescale_q(av_frame->duration, codec_ctx_->pkt_timebase, {1, 1000000})
        : 0;

    // Pixel format
    switch (av_frame->format) {
        case AV_PIX_FMT_NV12:         out.pixel_format = PixelFormat::NV12; break;
        case AV_PIX_FMT_P010LE:
        case AV_PIX_FMT_P010BE:       out.pixel_format = PixelFormat::P010; break;
        case AV_PIX_FMT_YUV420P:      out.pixel_format = PixelFormat::YUV420P; break;
        case AV_PIX_FMT_YUV420P10LE:
        case AV_PIX_FMT_YUV420P10BE:  out.pixel_format = PixelFormat::YUV420P10; break;
        default:                        out.pixel_format = PixelFormat::Unknown; break;
    }

    // Copy HDR metadata from track info
    out.hdr_metadata = track_info_.hdr_metadata;

    // Copy plane data
    int num_planes = 0;
    int total_size = 0;
    for (int i = 0; i < 4 && av_frame->data[i]; i++) {
        num_planes = i + 1;
        int h = (i == 0) ? av_frame->height : (av_frame->height + 1) / 2;
        total_size += av_frame->linesize[i] * h;
    }

    out.plane_data = std::shared_ptr<uint8_t[]>(new uint8_t[total_size]);
    uint8_t* dst = out.plane_data.get();

    for (int i = 0; i < num_planes; i++) {
        int h = (i == 0) ? av_frame->height : (av_frame->height + 1) / 2;
        int plane_size = av_frame->linesize[i] * h;
        memcpy(dst, av_frame->data[i], plane_size);
        out.planes[i] = dst;
        out.strides[i] = av_frame->linesize[i];
        dst += plane_size;
    }
}

} // namespace py
