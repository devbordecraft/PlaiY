#include "ff_video_decoder.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libavutil/pixdesc.h>
#include <libswscale/swscale.h>
}

#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#endif

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
    out.color_range = av_frame->color_range;

    // PTS in microseconds
    if (av_frame->pts != AV_NOPTS_VALUE) {
        AVRational tb = codec_ctx_->time_base;
        if (codec_ctx_->pkt_timebase.den > 0) {
            tb = codec_ctx_->pkt_timebase;
        }
        out.pts_us = av_rescale_q(av_frame->pts, tb, {1, 1000000});
    }
    out.duration_us = av_frame->duration > 0
        ? av_rescale_q(av_frame->duration, codec_ctx_->pkt_timebase, {1, 1000000})
        : 0;

    // Copy metadata from track info
    out.hdr_metadata = track_info_.hdr_metadata;
    out.sar_num = track_info_.sar_num;
    out.sar_den = track_info_.sar_den;

#ifdef __APPLE__
    // On Apple, wrap the decoded frame in a CVPixelBuffer so the Metal
    // renderer can create textures from it. The renderer only handles
    // CVPixelBuffer (biplanar NV12/P010), so we convert if needed.
    bool is_10bit = (av_frame->format == AV_PIX_FMT_YUV420P10LE ||
                     av_frame->format == AV_PIX_FMT_YUV420P10BE ||
                     av_frame->format == AV_PIX_FMT_P010LE ||
                     av_frame->format == AV_PIX_FMT_P010BE ||
                     av_frame->format == AV_PIX_FMT_YUV420P12LE ||
                     av_frame->format == AV_PIX_FMT_YUV420P12BE);

    OSType cv_pix_fmt = is_10bit
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    AVPixelFormat target_av_fmt = is_10bit ? AV_PIX_FMT_P010LE : AV_PIX_FMT_NV12;

    out.pixel_format = is_10bit ? PixelFormat::P010 : PixelFormat::NV12;

    CVPixelBufferRef pixel_buffer = nullptr;

    // Build attributes dictionary using CoreFoundation (no Obj-C in .cpp)
    CFDictionaryRef empty_dict = CFDictionaryCreate(
        kCFAllocatorDefault, nullptr, nullptr, 0,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFBooleanRef yes_val = kCFBooleanTrue;
    const void* attr_keys[] = {
        kCVPixelBufferIOSurfacePropertiesKey,
        kCVPixelBufferMetalCompatibilityKey,
    };
    const void* attr_vals[] = { empty_dict, yes_val };
    CFDictionaryRef attrs = CFDictionaryCreate(
        kCFAllocatorDefault, attr_keys, attr_vals, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    CVReturn cvret = CVPixelBufferCreate(
        kCFAllocatorDefault,
        av_frame->width, av_frame->height,
        cv_pix_fmt,
        attrs,
        &pixel_buffer);

    CFRelease(attrs);
    CFRelease(empty_dict);

    if (cvret != kCVReturnSuccess || !pixel_buffer) {
        PY_LOG_ERROR(TAG, "CVPixelBufferCreate failed: %d", cvret);
        return;
    }

    CVPixelBufferLockBaseAddress(pixel_buffer, 0);

    // Convert from any FFmpeg format to NV12 or P010 using swscale
    uint8_t* dst_data[2];
    int dst_linesize[2];
    dst_data[0] = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 0));
    dst_data[1] = static_cast<uint8_t*>(CVPixelBufferGetBaseAddressOfPlane(pixel_buffer, 1));
    dst_linesize[0] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 0));
    dst_linesize[1] = static_cast<int>(CVPixelBufferGetBytesPerRowOfPlane(pixel_buffer, 1));

    SwsContext* sws = sws_getContext(
        av_frame->width, av_frame->height, static_cast<AVPixelFormat>(av_frame->format),
        av_frame->width, av_frame->height, target_av_fmt,
        SWS_BILINEAR, nullptr, nullptr, nullptr);

    if (sws) {
        sws_scale(sws, av_frame->data, av_frame->linesize, 0, av_frame->height,
                  dst_data, dst_linesize);
        sws_freeContext(sws);
    }

    CVPixelBufferUnlockBaseAddress(pixel_buffer, 0);

    out.native_buffer = pixel_buffer;
    out.owns_native_buffer = true;
    out.hardware_frame = true; // Treat as hardware frame for the renderer
#else
    // Non-Apple: keep raw plane data
    switch (av_frame->format) {
        case AV_PIX_FMT_NV12:         out.pixel_format = PixelFormat::NV12; break;
        case AV_PIX_FMT_P010LE:
        case AV_PIX_FMT_P010BE:       out.pixel_format = PixelFormat::P010; break;
        case AV_PIX_FMT_YUV420P:      out.pixel_format = PixelFormat::YUV420P; break;
        case AV_PIX_FMT_YUV420P10LE:
        case AV_PIX_FMT_YUV420P10BE:  out.pixel_format = PixelFormat::YUV420P10; break;
        default:                        out.pixel_format = PixelFormat::Unknown; break;
    }

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
#endif
}

} // namespace py
