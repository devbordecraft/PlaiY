#include "audio_resampler.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavcodec/avcodec.h>
#include <libswresample/swresample.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libavutil/samplefmt.h>
}

static constexpr const char* TAG = "AudioResampler";

namespace py {

AudioResampler::AudioResampler() = default;

AudioResampler::~AudioResampler() {
    close();
}

Error AudioResampler::open(AVCodecContext* codec_ctx, int out_sample_rate, int out_channels) {
    close();

    out_sample_rate_ = out_sample_rate;
    out_channels_ = out_channels;

    AVChannelLayout out_layout{};
    av_channel_layout_default(&out_layout, out_channels);
    int ret = swr_alloc_set_opts2(&swr_ctx_,
        &out_layout,
        AV_SAMPLE_FMT_FLT,
        out_sample_rate,
        &codec_ctx->ch_layout,
        codec_ctx->sample_fmt,
        codec_ctx->sample_rate,
        0, nullptr);
    av_channel_layout_uninit(&out_layout);

    if (ret < 0 || !swr_ctx_) {
        return {ErrorCode::AudioOutputError, "Failed to allocate resampler"};
    }

    ret = swr_init(swr_ctx_);
    if (ret < 0) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to init resampler"};
    }

    PY_LOG_INFO(TAG, "Resampler: %d Hz %d ch -> %d Hz %d ch float32",
                codec_ctx->sample_rate, codec_ctx->ch_layout.nb_channels,
                out_sample_rate, out_channels);
    return Error::Ok();
}

void AudioResampler::close() {
    if (swr_ctx_) {
        swr_free(&swr_ctx_);
        swr_ctx_ = nullptr;
    }
}

Error AudioResampler::convert(AVFrame* frame, std::vector<float>& out_samples, int& out_num_samples) {
    if (!swr_ctx_) return {ErrorCode::InvalidState};

    // Calculate output sample count
    int64_t delay = swr_get_delay(swr_ctx_, frame->sample_rate);
    int out_count = static_cast<int>(av_rescale_rnd(
        delay + frame->nb_samples,
        out_sample_rate_,
        frame->sample_rate,
        AV_ROUND_UP));

    out_samples.resize(static_cast<size_t>(out_count * out_channels_));
    uint8_t* out_buf = reinterpret_cast<uint8_t*>(out_samples.data());

    int converted = swr_convert(swr_ctx_,
        &out_buf, out_count,
        const_cast<const uint8_t**>(frame->extended_data),
        frame->nb_samples);

    if (converted < 0) {
        return {ErrorCode::AudioOutputError, "Resample conversion failed"};
    }

    out_num_samples = converted;
    return Error::Ok();
}

} // namespace py
