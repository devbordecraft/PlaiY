#include "audio_pipeline.h"
#include "audio/audio_passthrough.h"
#include "plaiy/logger.h"

#ifdef __APPLE__
#include "../platform/apple/ca_audio_output.h"
#include "../platform/apple/spatial_audio_output.h"
#include "../platform/apple/spatial_audio_detector.h"
#endif

extern "C" {
#include <libavcodec/avcodec.h>
}

#include <algorithm>
#include <cstring>

static constexpr const char* TAG = "AudioPipeline";

namespace py {

AudioPipeline::AudioPipeline(SharedState shared)
    : shared_(shared) {}

void AudioPipeline::setup(const TrackInfo& track,
                          std::unique_ptr<IAudioOutput>& audio_output,
                          std::unique_ptr<AudioDecoder>& audio_decoder,
                          int spatial_audio_mode,
                          bool head_tracking_enabled,
                          bool muted, float volume) {
    // Create audio output if needed
    if (!audio_output) {
#ifdef __APPLE__
        if (spatial_audio_mode != 1 /* Off */) {
            bool want_spatial = false;
            if (spatial_audio_mode == 2 /* Force */) {
                want_spatial = true;
            } else {
                auto dev_type = SpatialAudioDetector::detect_current_device();
                want_spatial = (dev_type == AudioDeviceType::SpatialHeadphones);
            }
            if (want_spatial && !passthrough_preferred_) {
                audio_output = std::make_unique<SpatialAudioOutput>();
                PY_LOG_INFO(TAG, "Using spatial audio output (HRTF)");
            }
        }
        if (!audio_output) {
            audio_output = std::make_unique<CAAudioOutput>();
        }
#endif
    }
    if (!audio_output) return;

    audio_output_ptr_ = audio_output.get();
    bool passthrough_ok = false;

    // Try passthrough if preferred and codec is eligible
    if (passthrough_preferred_ && !audio_output->is_spatial()
        && is_passthrough_eligible(track.codec_id, track.codec_profile)) {
        auto err = audio_output->open_passthrough(track.codec_id, track.codec_profile,
                                                   track.sample_rate, track.channels);
        if (!err) {
            audio_output_mode_ = AudioOutputMode::Passthrough;
            passthrough_codec_profile_ = track.codec_profile;
            passthrough_ok = true;

            int bps = passthrough_bytes_per_second(track.codec_id, track.codec_profile);
            passthrough_bytes_per_second_ = bps;
            passthrough_ring_capacity_ = static_cast<size_t>(bps * RING_SECONDS);
            passthrough_ring_buffer_.resize(passthrough_ring_capacity_);
            passthrough_ring_read_ = 0;
            passthrough_ring_write_ = 0;
            passthrough_ring_size_ = 0;

            audio_output->set_muted(muted);
            audio_output->set_volume(volume);
            audio_output->set_bitstream_pull_callback(
                [this](uint8_t* buf, int bytes) {
                    return bitstream_pull(buf, bytes);
                });

            // Create MAT framer for TrueHD (HDMI requires MAT encapsulation)
            if (track.codec_id == AV_CODEC_ID_TRUEHD) {
                mat_framer_ = std::make_unique<MATFramer>();
                auto mat_err = mat_framer_->open(track.codec_id, track.sample_rate, track.channels);
                if (mat_err) {
                    PY_LOG_WARN(TAG, "MAT framer open failed: %s", mat_err.message.c_str());
                    mat_framer_.reset();
                }
            }

            PY_LOG_INFO(TAG, "Audio passthrough: %s at %d Hz",
                        track.codec_name.c_str(), track.sample_rate);
        } else {
            PY_LOG_INFO(TAG, "Passthrough not available (%s), falling back to decode",
                        err.message.c_str());
        }
    }

    // Normal decode path (PCM or Spatial)
    if (!passthrough_ok) {
        audio_output_mode_ = audio_output->is_spatial()
            ? AudioOutputMode::Spatial : AudioOutputMode::PCM;
        audio_decoder = std::make_unique<AudioDecoder>();
        auto err = audio_decoder->open(track);
        if (err) {
            PY_LOG_WARN(TAG, "Audio decoder open failed: %s", err.message.c_str());
            audio_decoder.reset();
            audio_output.reset();
            audio_output_ptr_ = nullptr;
        } else {
            int out_rate = audio_decoder->sample_rate();
            int source_ch = audio_decoder->channels();
            int device_max = audio_output->max_device_channels();
            int out_channels = std::min(source_ch, device_max);
            PY_LOG_INFO(TAG, "Audio: source=%d ch, device_max=%d ch, output=%d ch",
                        source_ch, device_max, out_channels);

            err = audio_output->open(out_rate, out_channels);
            if (err && audio_output->is_spatial()) {
                PY_LOG_WARN(TAG, "Spatial audio output failed (%s), falling back to standard",
                            err.message.c_str());
                audio_output = std::make_unique<CAAudioOutput>();
                audio_output_ptr_ = audio_output.get();
                audio_output_mode_ = AudioOutputMode::PCM;
                out_channels = std::min(source_ch, audio_output->max_device_channels());
                err = audio_output->open(out_rate, out_channels);
            }
            if (err) {
                PY_LOG_WARN(TAG, "Audio output open failed: %s", err.message.c_str());
                audio_output.reset();
                audio_output_ptr_ = nullptr;
            } else {
                shared_.audio_ring.resize(static_cast<size_t>(
                    out_rate * out_channels * RING_SECONDS));

                audio_output->set_pull_callback(
                    [this](float* buf, int frames, int ch) {
                        return pcm_pull(buf, frames, ch);
                    });

                audio_output->set_pts_callback([](int64_t) {});
                audio_output->set_muted(muted);
                audio_output->set_volume(volume);

                if (audio_output->is_spatial()) {
                    audio_output->set_head_tracking_enabled(head_tracking_enabled);
                }
            }
        }
    }
}

void AudioPipeline::restart(const TrackInfo& track,
                            std::unique_ptr<IAudioOutput>& audio_output,
                            std::unique_ptr<AudioDecoder>& audio_decoder,
                            std::thread& audio_decode_thread,
                            std::function<void()> audio_decode_loop_fn,
                            int spatial_audio_mode,
                            bool head_tracking_enabled,
                            bool start_output,
                            bool muted, float volume) {
    PY_LOG_INFO(TAG, "Restarting audio pipeline");

    // 1. Stop audio output
    if (audio_output) {
        audio_output->stop();
    }

    // 2. Signal audio decode thread to exit
    shared_.audio_restart_requested.store(true);
    shared_.audio_packet_queue.abort();
    shared_.pause_cv.notify_all();
    shared_.audio_ring_not_full.notify_all();

    // 3. Join the audio decode thread
    if (audio_decode_thread.joinable()) {
        audio_decode_thread.join();
    }

    // 4. Close and tear down audio components
    if (audio_output) {
        audio_output->close();
        audio_output.reset();
    }
    audio_output_ptr_ = nullptr;
    audio_decoder.reset();
    mat_framer_.reset();
    audio_output_mode_ = AudioOutputMode::PCM;
    passthrough_codec_profile_ = -1;
    shared_.audio_ring.reset();
    passthrough_ring_buffer_.clear();
    passthrough_ring_read_ = 0;
    passthrough_ring_write_ = 0;
    passthrough_ring_size_ = 0;
    passthrough_ring_capacity_ = 0;
    passthrough_bytes_per_second_ = 0;
    passthrough_pts_for_ring_ = 0;

    // 5. Re-open in the new mode
    setup(track, audio_output, audio_decoder,
          spatial_audio_mode, head_tracking_enabled, muted, volume);

    // 6. Re-enable packet queue and start new audio decode thread
    shared_.audio_restart_requested.store(false);
    shared_.audio_packet_queue.reset();
    audio_decode_thread = std::thread(audio_decode_loop_fn);

    // 7. Start audio output
    if (audio_output && start_output) {
        audio_output->start();
    }

    // 8. Reset PTS to current clock position for A-V sync recovery
    int64_t now = shared_.clock.now_us();
    shared_.audio_pts_for_ring.store(now);
    passthrough_pts_for_ring_ = now;

    PY_LOG_INFO(TAG, "Audio pipeline restarted in %s mode",
                audio_output_mode_ == AudioOutputMode::Passthrough ? "passthrough" : "PCM");
}

bool AudioPipeline::wait_if_paused() {
    if (!shared_.pause_requested.load(std::memory_order_acquire)) {
        return shared_.running.load(std::memory_order_relaxed) &&
               !shared_.audio_restart_requested.load(std::memory_order_relaxed);
    }

    std::unique_lock lock(shared_.pause_mutex);
    shared_.pause_cv.wait(lock, [&] {
        return !shared_.pause_requested.load(std::memory_order_acquire) ||
               !shared_.running.load(std::memory_order_relaxed) ||
               shared_.audio_restart_requested.load(std::memory_order_relaxed);
    });

    return shared_.running.load(std::memory_order_relaxed) &&
           !shared_.audio_restart_requested.load(std::memory_order_relaxed);
}

bool AudioPipeline::wait_for_drain() {
    while (shared_.running.load(std::memory_order_relaxed) &&
           !shared_.audio_restart_requested.load(std::memory_order_relaxed)) {
        if (!wait_if_paused()) return false;

        std::unique_lock lock(shared_.audio_ring_flush_mutex);
        shared_.audio_ring_not_full.wait(lock, [&] {
            bool drained = false;
            if (audio_output_mode_ == AudioOutputMode::Passthrough) {
                drained = (passthrough_ring_size_ == 0);
            } else {
                drained = (shared_.audio_ring.available_read() == 0);
            }
            return drained ||
                   shared_.pause_requested.load(std::memory_order_acquire) ||
                   !shared_.running.load(std::memory_order_relaxed) ||
                   shared_.audio_restart_requested.load(std::memory_order_relaxed);
        });

        bool drained = false;
        if (audio_output_mode_ == AudioOutputMode::Passthrough) {
            drained = (passthrough_ring_size_ == 0);
        } else {
            drained = (shared_.audio_ring.available_read() == 0);
        }
        if (drained) return true;
    }

    return false;
}

int AudioPipeline::pcm_pull(float* buffer, int frames, int channels) {
    if (shared_.waiting_for_first_frame.load()) return 0;

    size_t needed = static_cast<size_t>(frames * channels);
    size_t to_read = shared_.audio_ring.read(buffer, needed);

    shared_.audio_ring_not_full.notify_one();

    if (to_read > 0 && audio_output_ptr_ && audio_output_ptr_->sample_rate() > 0) {
        int64_t samples_behind = static_cast<int64_t>(shared_.audio_ring.available_read()) / channels;
        int64_t offset_us = samples_behind * 1000000LL / audio_output_ptr_->sample_rate();
        shared_.clock.set_audio_pts(
            shared_.audio_pts_for_ring.load(std::memory_order_acquire) - offset_us);
    }

    return static_cast<int>(to_read / static_cast<size_t>(channels));
}

int AudioPipeline::bitstream_pull(uint8_t* buffer, int bytes) {
    if (shared_.waiting_for_first_frame.load()) return 0;

    std::unique_lock lock(shared_.audio_ring_flush_mutex, std::try_to_lock);
    if (!lock.owns_lock()) return 0;

    size_t available = passthrough_ring_size_;
    size_t to_read = std::min(static_cast<size_t>(bytes), available);
    size_t capacity = passthrough_ring_buffer_.size();

    size_t first_chunk = std::min(to_read, capacity - passthrough_ring_read_);
    memcpy(buffer, &passthrough_ring_buffer_[passthrough_ring_read_], first_chunk);
    if (to_read > first_chunk) {
        memcpy(buffer + first_chunk, &passthrough_ring_buffer_[0],
               to_read - first_chunk);
    }
    passthrough_ring_read_ = (passthrough_ring_read_ + to_read) % capacity;
    passthrough_ring_size_ -= to_read;

    shared_.audio_ring_not_full.notify_one();

    if (to_read > 0 && passthrough_bytes_per_second_ > 0) {
        int64_t bytes_behind = static_cast<int64_t>(passthrough_ring_size_);
        int64_t offset_us = bytes_behind * 1000000LL / passthrough_bytes_per_second_;
        shared_.clock.set_audio_pts(passthrough_pts_for_ring_ - offset_us);
    }

    return static_cast<int>(to_read);
}

bool AudioPipeline::passthrough_write_loop() {
    PY_LOG_INFO(TAG, "Audio passthrough loop started");

    if (!audio_output_ptr_) return false;

    std::vector<uint8_t> mat_buf;

    while (shared_.running.load(std::memory_order_relaxed)) {
        if (!wait_if_paused()) break;

        Packet pkt;
        if (!shared_.audio_packet_queue.pop(pkt)) break;

        if (pkt.is_flush) {
            if (pkt.is_eof) {
                PY_LOG_INFO(TAG, "Audio passthrough EOF: waiting for buffered audio to drain");
                bool drained = wait_for_drain();
                PY_LOG_INFO(TAG, "Audio passthrough EOF drain %s",
                            drained ? "completed" : "cancelled");
                return drained;
            }

            {
                std::lock_guard lock(shared_.audio_ring_flush_mutex);
                passthrough_ring_read_ = 0;
                passthrough_ring_write_ = 0;
                passthrough_ring_size_ = 0;
            }

            if (shared_.running.load(std::memory_order_relaxed) == false) break;
            continue;
        }

        int64_t pts_us = pkt.pts_us();

        // For TrueHD, run through MAT framer for HDMI encapsulation
        const uint8_t* write_data = pkt.data.data();
        size_t write_size = pkt.data.size();
        mat_buf.clear();
        if (mat_framer_) {
            auto mat_err = mat_framer_->frame_packet(pkt.data.data(), pkt.data.size(), pkt.pts, mat_buf);
            if (mat_err) {
                PY_LOG_WARN(TAG, "MAT framing failed: %s", mat_err.message.c_str());
                continue;
            }
            if (mat_buf.empty()) continue;
            write_data = mat_buf.data();
            write_size = mat_buf.size();
        }

        // Write compressed packet data to byte ring buffer
        while (shared_.running.load(std::memory_order_relaxed) &&
               !shared_.audio_restart_requested.load(std::memory_order_relaxed)) {
            if (!wait_if_paused()) return false;

            std::unique_lock lock(shared_.audio_ring_flush_mutex);
            size_t to_write = write_size;
            size_t capacity = passthrough_ring_buffer_.size();

            if (to_write > capacity) {
                PY_LOG_WARN(TAG, "Passthrough packet too large: %zu > %zu", to_write, capacity);
                break;
            }

            shared_.audio_ring_not_full.wait(lock, [&] {
                return passthrough_ring_size_ + to_write <= capacity ||
                       shared_.pause_requested.load(std::memory_order_acquire) ||
                       !shared_.running.load(std::memory_order_relaxed) ||
                       shared_.audio_restart_requested.load(std::memory_order_relaxed);
            });
            if (!shared_.running.load(std::memory_order_relaxed) ||
                shared_.audio_restart_requested.load(std::memory_order_relaxed)) break;
            if (shared_.pause_requested.load(std::memory_order_acquire)) continue;

            const uint8_t* src = write_data;
            size_t first_chunk = std::min(to_write, capacity - passthrough_ring_write_);
            memcpy(&passthrough_ring_buffer_[passthrough_ring_write_], src, first_chunk);
            if (to_write > first_chunk) {
                memcpy(&passthrough_ring_buffer_[0], src + first_chunk,
                       to_write - first_chunk);
            }
            passthrough_ring_write_ = (passthrough_ring_write_ + to_write) % capacity;
            passthrough_ring_size_ += to_write;

            int64_t pkt_duration_us = 0;
            if (pkt.duration > 0 && pkt.time_base_den > 0) {
                pkt_duration_us = pkt.duration * 1000000LL * pkt.time_base_num / pkt.time_base_den;
            }
            passthrough_pts_for_ring_ = pts_us + pkt_duration_us;
            break;
        }
    }

    PY_LOG_INFO(TAG, "Audio passthrough loop ended");
    return false;
}

void AudioPipeline::flush_ring(int64_t pts_us) {
    std::lock_guard lock(shared_.audio_ring_flush_mutex);
    if (audio_output_mode_ == AudioOutputMode::Passthrough) {
        passthrough_ring_read_ = 0;
        passthrough_ring_write_ = 0;
        passthrough_ring_size_ = 0;
        passthrough_pts_for_ring_ = pts_us;
    } else {
        shared_.audio_ring.reset();
        shared_.audio_pts_for_ring.store(pts_us, std::memory_order_release);
    }
}

void AudioPipeline::teardown() {
    mat_framer_.reset();
    audio_output_mode_ = AudioOutputMode::PCM;
    passthrough_codec_profile_ = -1;
    passthrough_ring_buffer_.clear();
    passthrough_ring_read_ = 0;
    passthrough_ring_write_ = 0;
    passthrough_ring_size_ = 0;
    passthrough_ring_capacity_ = 0;
    passthrough_bytes_per_second_ = 0;
    passthrough_pts_for_ring_ = 0;
    audio_output_ptr_ = nullptr;
}

} // namespace py
