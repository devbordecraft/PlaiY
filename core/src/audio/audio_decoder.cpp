#include "audio_decoder.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
}

static constexpr const char* TAG = "AudioDecoder";

namespace py {

AudioDecoder::AudioDecoder() = default;

AudioDecoder::~AudioDecoder() {
    close();
}

Error AudioDecoder::open(const TrackInfo& track) {
    close();

    const AVCodec* codec = avcodec_find_decoder(static_cast<AVCodecID>(track.codec_id));
    if (!codec) {
        return {ErrorCode::UnsupportedCodec, "No audio decoder for: " + track.codec_name};
    }

    codec_ctx_ = avcodec_alloc_context3(codec);
    if (!codec_ctx_) return {ErrorCode::OutOfMemory};

    codec_ctx_->sample_rate = track.sample_rate;
    av_channel_layout_default(&codec_ctx_->ch_layout, track.channels);

    if (!track.extradata.empty()) {
        codec_ctx_->extradata = static_cast<uint8_t*>(
            av_mallocz(track.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        if (!codec_ctx_->extradata) {
            close();
            return {ErrorCode::OutOfMemory, "Failed to allocate codec extradata"};
        }
        codec_ctx_->extradata_size = static_cast<int>(track.extradata.size());
        memcpy(codec_ctx_->extradata, track.extradata.data(), track.extradata.size());
    }

    codec_ctx_->thread_count = 1;

    int ret = avcodec_open2(codec_ctx_, codec, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        close();
        return {ErrorCode::DecoderInitFailed, std::string("Audio decoder open failed: ") + errbuf};
    }

    av_frame_ = av_frame_alloc();
    if (!av_frame_) {
        close();
        return {ErrorCode::OutOfMemory};
    }

    PY_LOG_INFO(TAG, "Opened audio decoder: %s (%d Hz, %d ch)",
                codec->name, codec_ctx_->sample_rate, codec_ctx_->ch_layout.nb_channels);
    return Error::Ok();
}

void AudioDecoder::close() {
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

void AudioDecoder::flush() {
    if (codec_ctx_) avcodec_flush_buffers(codec_ctx_);
}

Error AudioDecoder::send_packet(const Packet& pkt) {
    if (!codec_ctx_) return {ErrorCode::InvalidState};

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
    if (ret < 0) return {ErrorCode::DecoderError, "Audio send_packet failed"};

    return Error::Ok();
}

Error AudioDecoder::receive_frame(AudioFrame& out) {
    if (!codec_ctx_ || !av_frame_) return {ErrorCode::InvalidState};

    int ret = avcodec_receive_frame(codec_ctx_, av_frame_);
    if (ret == AVERROR(EAGAIN)) return {ErrorCode::OutputNotReady};
    if (ret == AVERROR_EOF) return {ErrorCode::EndOfFile};
    if (ret < 0) return {ErrorCode::DecoderError, "Audio receive_frame failed"};

    out.sample_rate = av_frame_->sample_rate;
    out.channels = av_frame_->ch_layout.nb_channels;
    out.num_samples = av_frame_->nb_samples;

    // PTS in microseconds
    if (av_frame_->pts != AV_NOPTS_VALUE && codec_ctx_->pkt_timebase.den > 0) {
        out.pts_us = av_rescale_q(av_frame_->pts, codec_ctx_->pkt_timebase, {1, 1000000});
    }

    // Note: actual format conversion is done by the resampler
    // Here we just pass the raw frame info; the resampler will convert to float32 interleaved
    out.data.clear();

    av_frame_unref(av_frame_);
    return Error::Ok();
}

int AudioDecoder::sample_rate() const {
    return codec_ctx_ ? codec_ctx_->sample_rate : 0;
}

int AudioDecoder::channels() const {
    return codec_ctx_ ? codec_ctx_->ch_layout.nb_channels : 0;
}

} // namespace py
