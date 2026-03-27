#include "audio_filter_chain.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavutil/frame.h>
}

#include <cstring>

static constexpr const char* TAG = "AudioFilterChain";

namespace py {

AudioFilterChain::AudioFilterChain() = default;

AudioFilterChain::~AudioFilterChain() {
    close();
}

void AudioFilterChain::add(std::unique_ptr<IAudioFilter> filter) {
    if (filter->stage() == AudioFilterStage::PreResample) {
        pre_resample_.push_back(std::move(filter));
    } else {
        post_resample_.push_back(std::move(filter));
    }
}

IAudioFilter* AudioFilterChain::find(const char* name) const {
    for (auto& f : pre_resample_) {
        if (std::strcmp(f->name(), name) == 0) return f.get();
    }
    for (auto& f : post_resample_) {
        if (std::strcmp(f->name(), name) == 0) return f.get();
    }
    return nullptr;
}

Error AudioFilterChain::open(AVCodecContext* codec_ctx, int out_sample_rate, int out_channels) {
    close();

    out_sample_rate_ = out_sample_rate;
    out_channels_ = out_channels;

    // Open pre-resample filters
    for (auto& f : pre_resample_) {
        Error err = f->open_avframe(codec_ctx);
        if (err) {
            PY_LOG_ERROR(TAG, "Failed to open pre-resample filter '%s': %s",
                         f->name(), err.message.c_str());
            close();
            return err;
        }
    }

    // Open resampler
    Error err = resampler_.open(codec_ctx, out_sample_rate, out_channels);
    if (err) {
        close();
        return err;
    }

    // Open post-resample filters
    for (auto& f : post_resample_) {
        Error post_err = f->open_float(out_sample_rate, out_channels);
        if (post_err) {
            PY_LOG_WARN(TAG, "Failed to open post-resample filter '%s': %s (disabling)",
                        f->name(), post_err.message.c_str());
            f->set_enabled(false);
        }
    }

    temp_frame_ = av_frame_alloc();
    open_ = true;
    has_pending_direct_ = false;
    pending_direct_frame_ = nullptr;
    active_pre_filter_ = nullptr;

    PY_LOG_INFO(TAG, "Audio filter chain opened: %d pre-resample, %d post-resample filters",
                static_cast<int>(pre_resample_.size()),
                static_cast<int>(post_resample_.size()));
    return Error::Ok();
}

void AudioFilterChain::close() {
    for (auto& f : pre_resample_) f->close();
    for (auto& f : post_resample_) f->close();
    resampler_.close();
    if (temp_frame_) {
        av_frame_free(&temp_frame_);
        temp_frame_ = nullptr;
    }
    has_pending_direct_ = false;
    pending_direct_frame_ = nullptr;
    active_pre_filter_ = nullptr;
    open_ = false;
}

void AudioFilterChain::flush() {
    for (auto& f : pre_resample_) {
        if (f->enabled()) f->flush();
    }
    for (auto& f : post_resample_) {
        if (f->enabled()) f->flush();
    }
    has_pending_direct_ = false;
    pending_direct_frame_ = nullptr;
    active_pre_filter_ = nullptr;
}

void AudioFilterChain::send_frame(AVFrame* frame) {
    if (!open_) return;

    // Find the last enabled pre-resample filter
    active_pre_filter_ = nullptr;
    for (auto& f : pre_resample_) {
        if (f->enabled()) active_pre_filter_ = f.get();
    }

    if (active_pre_filter_) {
        // Feed through the pre-resample filter chain
        // (currently supports one pre-resample filter — tempo)
        for (auto& f : pre_resample_) {
            if (f->enabled()) {
                f->send_frame(frame);
                break;  // only first enabled pre-resample filter gets the frame
            }
        }
        has_pending_direct_ = false;
    } else {
        // No pre-resample filter active — mark for direct pass-through
        pending_direct_frame_ = frame;
        has_pending_direct_ = true;
    }
}

bool AudioFilterChain::drain(std::vector<float>& out_samples, int& out_num_samples) {
    if (!open_) return false;

    out_num_samples = 0;
    AVFrame* frame_to_resample = nullptr;

    if (has_pending_direct_) {
        // Direct path: no pre-resample filter, use the original frame
        frame_to_resample = pending_direct_frame_;
        has_pending_direct_ = false;
        pending_direct_frame_ = nullptr;
    } else if (active_pre_filter_) {
        // Pull one frame from the pre-resample filter
        av_frame_unref(temp_frame_);
        int ret = active_pre_filter_->receive_frame(temp_frame_);
        if (ret < 0) {
            // No more output — caller should send next input frame
            return false;
        }
        frame_to_resample = temp_frame_;
    } else {
        return false;
    }

    // Resample to float32 interleaved
    Error err = resampler_.convert(frame_to_resample, out_samples, out_num_samples);
    if (err) {
        PY_LOG_ERROR(TAG, "Resample failed: %s", err.message.c_str());
        return false;
    }

    if (out_num_samples <= 0) return false;

    // Apply post-resample filters in-place
    for (auto& pf : post_resample_) {
        if (pf->enabled()) {
            pf->process(out_samples.data(), out_num_samples, out_channels_);
        }
    }

    return true;
}

} // namespace py
