#include "plaiy/player_engine.h"
#include "plaiy/clock.h"
#include "plaiy/frame_queue.h"
#include "plaiy/logger.h"
#include "plaiy/packet_queue.h"
#include "plaiy/spsc_ring_buffer.h"
#include "plaiy/subtitle_manager.h"

#include "demuxer/ff_demuxer.h"
#include "video/video_decoder_factory.h"
#include "video/deinterlace_filter.h"
#include "audio/audio_decoder.h"
#include "audio/audio_filter_chain.h"
#include "audio/audio_tempo_filter.h"
#include "audio/equalizer_filter.h"
#include "audio/compressor_filter.h"
#include "audio/dialogue_boost_filter.h"
#include "audio/audio_passthrough.h"
#include "playback_stats.h"

#ifdef __APPLE__
#include "../platform/apple/ca_audio_output.h"
#endif
#include "frame_presenter.h"
#include "audio_pipeline.h"

#ifdef __APPLE__
#include "../platform/apple/dv_video_output.h"
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include <algorithm>
#include <array>
#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

static constexpr const char* TAG = "PlayerEngine";

// Open an FFmpeg audio decoder context for the given track.
// Returns nullptr on failure.
static AVCodecContext* open_audio_codec(const py::TrackInfo& track) {
    const AVCodec* codec = avcodec_find_decoder(
        static_cast<AVCodecID>(track.codec_id));
    if (!codec) return nullptr;

    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) return nullptr;

    ctx->sample_rate = track.sample_rate;
    av_channel_layout_default(&ctx->ch_layout, track.channels);

    if (!track.extradata.empty()) {
        ctx->extradata_size = static_cast<int>(track.extradata.size());
        ctx->extradata = static_cast<uint8_t*>(
            av_mallocz(track.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
        memcpy(ctx->extradata, track.extradata.data(), track.extradata.size());
    }

    if (avcodec_open2(ctx, codec, nullptr) < 0) {
        avcodec_free_context(&ctx);
        return nullptr;
    }
    return ctx;
}

namespace py {

struct PlayerEngine::Impl {
    // State
    std::atomic<PlaybackState> state{PlaybackState::Idle};
    MediaInfo media_info;
    StateCallback state_callback;
    ErrorCallback error_callback;

    // Components
    std::unique_ptr<FFDemuxer> demuxer;
    std::unique_ptr<IVideoDecoder> video_decoder;
    std::unique_ptr<AudioDecoder> audio_decoder;
    std::unique_ptr<IAudioOutput> audio_output;
    std::unique_ptr<SubtitleManager> subtitle_manager;
    Clock clock;

    // Queues
    PacketQueue video_packet_queue{32, 50 * 1024 * 1024};  // 32 packets, 50 MB cap
    PacketQueue audio_packet_queue{32, 10 * 1024 * 1024};  // 32 packets, 10 MB cap
    FrameQueue video_frame_queue{8};

    // Lock-free SPSC audio ring buffer for the pull callback.
    // Producer: audio decode thread. Consumer: CoreAudio real-time thread.
    SPSCRingBuffer<float> audio_ring;
    std::mutex audio_ring_flush_mutex;           // protects reset() during seek/switch
    std::condition_variable audio_ring_not_full;  // backpressure for decode thread
    static constexpr int AUDIO_RING_SECONDS = 2;

    std::atomic<int64_t> audio_pts_for_ring{0}; // PTS at ring write position

    // Audio pipeline (owns passthrough ring buffer, callbacks, setup/restart)
    std::unique_ptr<AudioPipeline> audio_pipeline;

    // Settings
    HWDecodePreference hw_decode_pref = HWDecodePreference::Auto;
    bool muted = false;
    float volume = 1.0f;

    // Spatial audio
    int spatial_audio_mode = 0;  // 0=Auto, 1=Off, 2=Force
    bool head_tracking_enabled = false;

    // Playback speed
    std::atomic<double> playback_speed{1.0};
    std::atomic<bool> speed_changed{false};

    // Audio filter desired state (set by main thread, read by decode thread)
    std::atomic<bool> eq_enabled{false};
    std::array<std::atomic<float>, 10> eq_bands{};
    std::atomic<int> eq_preset{0};
    std::atomic<bool> compressor_enabled{false};
    std::atomic<float> compressor_threshold{-24.0f};
    std::atomic<float> compressor_ratio{4.0f};
    std::atomic<float> compressor_attack{20.0f};
    std::atomic<float> compressor_release{250.0f};
    std::atomic<float> compressor_makeup{0.0f};
    std::atomic<bool> dialogue_boost_enabled{false};
    std::atomic<float> dialogue_boost_amount{0.5f};

    // Deinterlace
    std::atomic<bool> deinterlace_enabled{false};
    std::atomic<int> deinterlace_mode{0}; // 0=yadif, 1=bwdif

    // Video filter parameters (GPU-side, read by Swift via bridge)
    std::atomic<bool> deband_enabled{false};
    std::atomic<bool> lanczos_upscaling{false};
    std::atomic<bool> film_grain_enabled{true}; // ON by default for authentic grain
    std::atomic<float> video_brightness{0.0f};
    std::atomic<float> video_contrast{1.0f};
    std::atomic<float> video_saturation{1.0f};
    std::atomic<float> video_sharpness{0.0f};

    // Track indices
    int active_video_stream = -1;
    int active_audio_stream = -1;
    std::atomic<int> active_subtitle_stream{-1};

    // For seek
    std::atomic<bool> seeking{false};
    std::atomic<int64_t> seek_target_us{0};

    // For audio track switching
    std::atomic<bool> audio_track_changed{false};
    int pending_audio_stream = -1; // protected by audio_ring_flush_mutex

    // Hold audio silent until video presents its first frame after play/seek.
    // Prevents audio from driving the clock ahead of video.
    std::atomic<bool> waiting_for_first_frame{false};

    // Threads
    std::thread demux_thread;
    std::thread video_decode_thread;
    std::thread audio_decode_thread;
    std::atomic<bool> running{false};

    // Currently presented frame
    std::mutex presented_frame_mutex;
    std::unique_ptr<VideoFrame> presented_frame;

    // Frame presentation / A-V sync
    std::unique_ptr<FramePresenter> frame_presenter;

    // Stats counters
    std::atomic<int> frames_rendered{0};
    std::atomic<int> frames_dropped{0};

    // FFmpeg codec context for audio (needed by resampler)
    AVCodecContext* audio_codec_ctx = nullptr;

    void set_state(PlaybackState new_state) {
        state.store(new_state);
        if (state_callback) state_callback(new_state);
    }

    void report_error(Error err) {
        PY_LOG_ERROR(TAG, "Error: %s", err.message.c_str());
        if (error_callback) error_callback(err);
    }

    void demux_loop();
    void video_decode_loop();
    void audio_decode_loop();
    void stop_threads();

    // For audio pipeline restart (live toggle / track change)
    std::atomic<bool> audio_restart_requested{false};

    // Dolby Vision output (ASBDL-based, replaces decoder + frame queue for DV)
#ifdef __APPLE__
    std::unique_ptr<DVVideoOutput> dv_output;
#endif
    bool is_dv_output = false;
    std::atomic<bool> dv_fallback_needed{false};
    int64_t last_dv_sync_us = 0; // periodic ASBDL timebase re-sync

    void dv_video_decode_loop();
};

PlayerEngine::PlayerEngine() : impl_(std::make_unique<Impl>()) {
    impl_->demuxer = std::make_unique<FFDemuxer>();
    impl_->subtitle_manager = std::make_unique<SubtitleManager>();
    impl_->audio_pipeline = std::make_unique<AudioPipeline>(
        AudioPipeline::SharedState{
            .audio_ring = impl_->audio_ring,
            .audio_ring_flush_mutex = impl_->audio_ring_flush_mutex,
            .audio_ring_not_full = impl_->audio_ring_not_full,
            .audio_pts_for_ring = impl_->audio_pts_for_ring,
            .waiting_for_first_frame = impl_->waiting_for_first_frame,
            .clock = impl_->clock,
            .running = impl_->running,
            .audio_restart_requested = impl_->audio_restart_requested,
            .audio_packet_queue = impl_->audio_packet_queue,
        });
}

PlayerEngine::~PlayerEngine() {
    stop();
}

Error PlayerEngine::open_file(const std::string& path) {
    stop();
    impl_->set_state(PlaybackState::Opening);

    Error err = impl_->demuxer->open(path);
    if (err) {
        impl_->set_state(PlaybackState::Idle);
        return err;
    }

    impl_->media_info = impl_->demuxer->media_info();
    impl_->active_video_stream = impl_->media_info.best_video_index;
    impl_->active_audio_stream = impl_->media_info.best_audio_index;
    impl_->active_subtitle_stream = impl_->media_info.best_subtitle_index;

    // Open video decoder (or DV output for Dolby Vision Profile 5/8/10)
    if (impl_->active_video_stream >= 0) {
        const auto& track = impl_->media_info.tracks[static_cast<size_t>(impl_->active_video_stream)];

#ifdef __APPLE__
        if (track.hdr_metadata.type == HDRType::DolbyVision &&
            (track.dv_profile == 8 || track.dv_profile == 10)) {
            // DV Profile 8/10: use AVSampleBufferDisplayLayer for decoding + display.
            // ASBDL handles RPU reshaping, tone mapping, and color management.
            // Profile 5 (IPTPQc2): ASBDL silently accepts but doesn't render on macOS —
            // use FFmpeg + Metal with RPU metadata extraction instead.
            // Profile 7: dual-layer, not supported — falls through to VT + Metal.
            impl_->dv_output = std::make_unique<DVVideoOutput>();
            Error dv_err = impl_->dv_output->open(track);
            if (dv_err.ok()) {
                impl_->is_dv_output = true;
                PY_LOG_INFO(TAG, "DV Profile %d: using ASBDL output", track.dv_profile);
            } else {
                PY_LOG_WARN(TAG, "DV output failed: %s, falling back to decoder",
                            dv_err.message.c_str());
                impl_->dv_output.reset();
                impl_->is_dv_output = false;
            }
        }
#endif

        if (!impl_->is_dv_output) {
            impl_->video_decoder = VideoDecoderFactory::create(track, impl_->hw_decode_pref);
            if (!impl_->video_decoder) {
                return {ErrorCode::DecoderInitFailed, "No video decoder available"};
            }
        }
        impl_->subtitle_manager->set_video_size(track.width, track.height);
    }

    // Open audio decoder + resampler + output
    if (impl_->active_audio_stream >= 0) {
        setup_audio_output(impl_->media_info.tracks[static_cast<size_t>(impl_->active_audio_stream)]);
    }

    // Open subtitle track
    if (impl_->active_subtitle_stream >= 0) {
        const auto& track = impl_->media_info.tracks[static_cast<size_t>(impl_->active_subtitle_stream)];
        impl_->subtitle_manager->set_embedded_track(track);
    }

    // Create frame presenter for A-V sync (not needed for DV — ASBDL manages timing)
    if (!impl_->is_dv_output) {
        impl_->frame_presenter = std::make_unique<FramePresenter>(
            impl_->video_frame_queue,
            impl_->clock,
            impl_->presented_frame_mutex,
            impl_->presented_frame,
            impl_->waiting_for_first_frame,
            impl_->frames_rendered,
            impl_->frames_dropped);
    }

    impl_->set_state(PlaybackState::Ready);
    PY_LOG_INFO(TAG, "File opened: %s (%.1fs)",
                path.c_str(), static_cast<double>(impl_->media_info.duration_us) / 1e6);
    return Error::Ok();
}

void PlayerEngine::play() {
    auto s = impl_->state.load();
    if (s != PlaybackState::Ready && s != PlaybackState::Paused) return;

    if (!impl_->running.load(std::memory_order_relaxed)) {
        // Start threads
        impl_->running.store(true);
        impl_->video_packet_queue.reset();
        impl_->audio_packet_queue.reset();
        impl_->video_frame_queue.reset();

        impl_->demux_thread = std::thread([this] { impl_->demux_loop(); });
        impl_->video_decode_thread = std::thread([this] { impl_->video_decode_loop(); });
        impl_->audio_decode_thread = std::thread([this] { impl_->audio_decode_loop(); });

        // Freeze clock and hold audio until first video frame is presented,
        // preventing the clock from running ahead of the video pipeline.
        // If a seek is already pending (e.g. resume), use that target instead
        // of 0 so the clock matches where the demuxer will seek to.
        if (impl_->active_video_stream >= 0) {
            impl_->waiting_for_first_frame.store(true);
            int64_t start_pts = impl_->seeking.load(std::memory_order_relaxed) ? impl_->seek_target_us.load(std::memory_order_relaxed) : 0;
            impl_->clock.seek_to(start_pts);
        }
    }

    impl_->clock.set_paused(false);
    if (impl_->audio_output) impl_->audio_output->start();
#ifdef __APPLE__
    if (impl_->is_dv_output && impl_->dv_output) {
        impl_->dv_output->set_rate(impl_->playback_speed.load());
    }
#endif
    impl_->set_state(PlaybackState::Playing);
}

void PlayerEngine::pause() {
    if (impl_->state.load() != PlaybackState::Playing) return;

    impl_->clock.set_paused(true);
    if (impl_->audio_output) impl_->audio_output->stop();
#ifdef __APPLE__
    if (impl_->is_dv_output && impl_->dv_output) {
        impl_->dv_output->set_rate(0);
    }
#endif
    impl_->set_state(PlaybackState::Paused);
}

void PlayerEngine::seek(int64_t timestamp_us) {
    impl_->seek_target_us.store(timestamp_us, std::memory_order_relaxed);
    impl_->seeking.store(true);

    // Freeze clock and hold audio until the video renderer presents its first
    // post-seek frame (prevents the clock from running ahead of video).
    // For DV output, we don't freeze — ASBDL manages its own timing.
    // For audio-only files, just set the PTS without freezing.
    if (impl_->active_video_stream >= 0) {
        if (impl_->is_dv_output) {
#ifdef __APPLE__
            if (impl_->dv_output) impl_->dv_output->set_time(timestamp_us);
#endif
            impl_->clock.seek_to(timestamp_us);
            // Release first-frame gate immediately — ASBDL handles display timing
            impl_->waiting_for_first_frame.store(false);
        } else {
            impl_->waiting_for_first_frame.store(true);
            impl_->clock.seek_to(timestamp_us);
        }
    } else {
        impl_->clock.set_audio_pts(timestamp_us);
    }

    // Reset audio output position tracking
    if (impl_->audio_output) impl_->audio_output->reset_position();

    // Flush queues
    impl_->video_packet_queue.flush();
    impl_->audio_packet_queue.flush();
    if (!impl_->is_dv_output) impl_->video_frame_queue.flush();

    // Flush ring buffer and wake decode thread
    impl_->audio_pipeline->flush_ring(timestamp_us);
    impl_->audio_ring_not_full.notify_one();

    impl_->subtitle_manager->flush();
}

void PlayerEngine::stop() {
    // Stop audio output FIRST so CoreAudio stops pulling samples immediately
    if (impl_->audio_output) {
        impl_->audio_output->stop();
    }

    impl_->stop_threads();
    impl_->clock.reset();
    impl_->playback_speed.store(1.0);
    impl_->speed_changed.store(false);

    if (impl_->audio_output) {
        impl_->audio_output->close();
        impl_->audio_output.reset();
    }

    impl_->video_decoder.reset();
    impl_->audio_decoder.reset();
    impl_->audio_pipeline->teardown();
    impl_->audio_ring.release();
    impl_->subtitle_manager->close();
    impl_->demuxer->close();

#ifdef __APPLE__
    if (impl_->dv_output) {
        impl_->dv_output->close();
        impl_->dv_output.reset();
    }
    impl_->is_dv_output = false;
#endif

    {
        std::lock_guard lock(impl_->presented_frame_mutex);
        impl_->presented_frame.reset();
    }

    impl_->media_info = {};
    impl_->set_state(PlaybackState::Idle);
}

PlaybackState PlayerEngine::state() const {
    return impl_->state.load();
}

int64_t PlayerEngine::current_position_us() const {
    return impl_->clock.now_us();
}

int64_t PlayerEngine::duration_us() const {
    return impl_->media_info.duration_us;
}

const MediaInfo& PlayerEngine::media_info() const {
    return impl_->media_info;
}

void PlayerEngine::select_audio_track(int stream_index) {
    if (stream_index == impl_->active_audio_stream) return;

    // Validate it's a valid audio track
    if (stream_index >= 0 &&
        (stream_index >= static_cast<int>(impl_->media_info.tracks.size()) ||
         impl_->media_info.tracks[static_cast<size_t>(stream_index)].type != MediaType::Audio)) {
        PY_LOG_WARN(TAG, "Invalid audio stream index: %d", stream_index);
        return;
    }

    auto s = impl_->state.load();
    bool is_playing = (s == PlaybackState::Playing || s == PlaybackState::Paused);

    // If in passthrough mode, or switching to a track that requires a mode change,
    // use the full restart path for clean teardown/rebuild.
    bool needs_restart = false;
    if (is_playing && impl_->audio_pipeline->output_mode() == AudioOutputMode::Passthrough) {
        needs_restart = true;  // Always restart when leaving passthrough
    } else if (is_playing && impl_->audio_pipeline->is_passthrough_preferred() && stream_index >= 0) {
        const auto& new_track = impl_->media_info.tracks[static_cast<size_t>(stream_index)];
        if (is_passthrough_eligible(new_track.codec_id, new_track.codec_profile)) {
            needs_restart = true;  // Need to switch from PCM to passthrough
        }
    }

    impl_->active_audio_stream = stream_index;

    if (needs_restart) {
        restart_audio_pipeline();
    } else {
        // Use the existing in-place track switch for PCM-to-PCM changes
        {
            std::lock_guard lock(impl_->audio_ring_flush_mutex);
            impl_->pending_audio_stream = stream_index;
        }
        impl_->audio_track_changed.store(true);

        impl_->audio_packet_queue.flush();
        Packet flush_pkt;
        flush_pkt.is_flush = true;
        impl_->audio_packet_queue.push(flush_pkt);
    }

    PY_LOG_INFO(TAG, "Audio track switched to stream %d", stream_index);
}

void PlayerEngine::select_subtitle_track(int stream_index) {
    // Disable routing first so the demux thread stops feeding the old track
    impl_->active_subtitle_stream.store(-1, std::memory_order_release);

    // Flush stale state from the previous track
    impl_->subtitle_manager->flush();

    if (stream_index >= 0 && stream_index < static_cast<int>(impl_->media_info.tracks.size())) {
        impl_->subtitle_manager->set_embedded_track(impl_->media_info.tracks[static_cast<size_t>(stream_index)]);
    } else {
        impl_->subtitle_manager->close();
    }

    // Enable routing for the new track
    impl_->active_subtitle_stream.store(stream_index, std::memory_order_release);
}

int PlayerEngine::audio_track_count() const {
    int count = 0;
    for (const auto& t : impl_->media_info.tracks) {
        if (t.type == MediaType::Audio) count++;
    }
    return count;
}

int PlayerEngine::subtitle_track_count() const {
    int count = 0;
    for (const auto& t : impl_->media_info.tracks) {
        if (t.type == MediaType::Subtitle) count++;
    }
    return count;
}

int PlayerEngine::active_audio_stream() const {
    return impl_->active_audio_stream;
}

int PlayerEngine::active_subtitle_stream() const {
    return impl_->active_subtitle_stream.load(std::memory_order_relaxed);
}

void PlayerEngine::setup_audio_output(const TrackInfo& track) {
    impl_->audio_pipeline->setup(track, impl_->audio_output,
                                  impl_->audio_decoder,
                                  impl_->spatial_audio_mode,
                                  impl_->head_tracking_enabled,
                                  impl_->muted, impl_->volume);
}

void PlayerEngine::restart_audio_pipeline() {
    if (impl_->active_audio_stream < 0) return;

    const auto& track = impl_->media_info.tracks[static_cast<size_t>(impl_->active_audio_stream)];
    impl_->audio_pipeline->restart(track, impl_->audio_output,
                                    impl_->audio_decoder,
                                    impl_->audio_decode_thread,
                                    [this] { impl_->audio_decode_loop(); },
                                    impl_->spatial_audio_mode,
                                    impl_->head_tracking_enabled,
                                    impl_->muted, impl_->volume);
}

void PlayerEngine::set_audio_passthrough(bool enabled) {
    if (impl_->audio_pipeline->is_passthrough_preferred() == enabled) return;
    impl_->audio_pipeline->set_passthrough_preferred(enabled);

    auto s = impl_->state.load();
    if (s == PlaybackState::Playing || s == PlaybackState::Paused) {
        restart_audio_pipeline();
    }
}

bool PlayerEngine::is_passthrough_active() const {
    return impl_->audio_pipeline->output_mode() == AudioOutputMode::Passthrough;
}

PlayerEngine::PassthroughCapability PlayerEngine::query_passthrough_support() const {
    PassthroughCapability result;
    if (impl_->audio_output) {
        auto caps = impl_->audio_output->query_passthrough_support();
        result.ac3 = caps.ac3;
        result.eac3 = caps.eac3;
        result.dts = caps.dts;
        result.dts_hd_ma = caps.dts_hd_ma;
        result.truehd = caps.truehd;
    } else {
        // Create a temporary audio output to probe device capabilities
#ifdef __APPLE__
        CAAudioOutput temp;
        auto caps = temp.query_passthrough_support();
        result.ac3 = caps.ac3;
        result.eac3 = caps.eac3;
        result.dts = caps.dts;
        result.dts_hd_ma = caps.dts_hd_ma;
        result.truehd = caps.truehd;
#endif
    }
    return result;
}

void PlayerEngine::set_device_change_callback(DeviceChangeCallback cb) {
    if (impl_->audio_output) {
        impl_->audio_output->set_device_change_callback(std::move(cb));
    }
}

void PlayerEngine::set_muted(bool muted) {
    impl_->muted = muted;
    if (impl_->audio_output) impl_->audio_output->set_muted(muted);
}

bool PlayerEngine::is_muted() const {
    return impl_->muted;
}

void PlayerEngine::set_volume(float v) {
    impl_->volume = std::clamp(v, 0.0f, 1.0f);
    if (impl_->audio_output) impl_->audio_output->set_volume(impl_->volume);
}

float PlayerEngine::volume() const {
    return impl_->volume;
}

void PlayerEngine::set_dv_display_layer(void* layer) {
#ifdef __APPLE__
    if (impl_->dv_output) {
        impl_->dv_output->set_display_layer(layer);
    }
#else
    (void)layer;
#endif
}

bool PlayerEngine::is_dolby_vision() const {
    return impl_->is_dv_output;
}

void PlayerEngine::set_playback_speed(double speed) {
    speed = std::max(0.25, std::min(4.0, speed));

    impl_->clock.set_rate(speed);
    impl_->playback_speed.store(speed);
    impl_->speed_changed.store(true);

    // Flush audio ring buffer so stale-speed samples clear immediately
    if (impl_->audio_pipeline->output_mode() == AudioOutputMode::Passthrough) {
        // Can't tempo-filter compressed bitstreams — mute audio at non-1x
        if (impl_->audio_output) {
            impl_->audio_output->set_muted(
                std::abs(speed - 1.0) > 0.001 || impl_->muted);
        }
    } else {
        std::lock_guard lock(impl_->audio_ring_flush_mutex);
        impl_->audio_ring.reset();
    }
    impl_->audio_ring_not_full.notify_one();

#ifdef __APPLE__
    if (impl_->is_dv_output && impl_->dv_output &&
        impl_->state.load() == PlaybackState::Playing) {
        impl_->dv_output->set_rate(speed);
    }
#endif

    PY_LOG_INFO(TAG, "Playback speed set to %.2fx", speed);
}

double PlayerEngine::playback_speed() const {
    return impl_->playback_speed.load();
}

void PlayerEngine::set_spatial_audio_mode(int mode) {
    impl_->spatial_audio_mode = std::clamp(mode, 0, 2);
}

int PlayerEngine::spatial_audio_mode() const {
    return impl_->spatial_audio_mode;
}

bool PlayerEngine::is_spatial_active() const {
    return impl_->audio_pipeline->output_mode() == AudioOutputMode::Spatial;
}

void PlayerEngine::set_head_tracking_enabled(bool enabled) {
    impl_->head_tracking_enabled = enabled;
    if (impl_->audio_output) {
        impl_->audio_output->set_head_tracking_enabled(enabled);
    }
}

bool PlayerEngine::is_head_tracking_enabled() const {
    if (impl_->audio_output) {
        return impl_->audio_output->is_head_tracking_enabled();
    }
    return impl_->head_tracking_enabled;
}

void PlayerEngine::set_hw_decode_preference(HWDecodePreference pref) {
    impl_->hw_decode_pref = pref;
}

void PlayerEngine::set_subtitle_font_scale(double scale) {
    impl_->subtitle_manager->set_ass_font_scale(scale);
}

// Deinterlace
void PlayerEngine::set_deinterlace_enabled(bool e) { impl_->deinterlace_enabled.store(e, std::memory_order_relaxed); }
bool PlayerEngine::is_deinterlace_enabled() const { return impl_->deinterlace_enabled.load(std::memory_order_relaxed); }
void PlayerEngine::set_deinterlace_mode(int m) { impl_->deinterlace_mode.store(m, std::memory_order_relaxed); }
int PlayerEngine::deinterlace_mode() const { return impl_->deinterlace_mode.load(std::memory_order_relaxed); }

// Video filter getters/setters (GPU — atomic read/write, lock-free)
void PlayerEngine::set_deband_enabled(bool e) { impl_->deband_enabled.store(e, std::memory_order_relaxed); }
bool PlayerEngine::is_deband_enabled() const { return impl_->deband_enabled.load(std::memory_order_relaxed); }
void PlayerEngine::set_lanczos_upscaling(bool e) { impl_->lanczos_upscaling.store(e, std::memory_order_relaxed); }
bool PlayerEngine::lanczos_upscaling() const { return impl_->lanczos_upscaling.load(std::memory_order_relaxed); }
void PlayerEngine::set_film_grain_enabled(bool e) { impl_->film_grain_enabled.store(e, std::memory_order_relaxed); }
bool PlayerEngine::film_grain_enabled() const { return impl_->film_grain_enabled.load(std::memory_order_relaxed); }
void PlayerEngine::set_brightness(float v) { impl_->video_brightness.store(v, std::memory_order_relaxed); }
float PlayerEngine::brightness() const { return impl_->video_brightness.load(std::memory_order_relaxed); }
void PlayerEngine::set_contrast(float v) { impl_->video_contrast.store(v, std::memory_order_relaxed); }
float PlayerEngine::contrast() const { return impl_->video_contrast.load(std::memory_order_relaxed); }
void PlayerEngine::set_saturation(float v) { impl_->video_saturation.store(v, std::memory_order_relaxed); }
float PlayerEngine::saturation() const { return impl_->video_saturation.load(std::memory_order_relaxed); }
void PlayerEngine::set_sharpness(float v) { impl_->video_sharpness.store(v, std::memory_order_relaxed); }
float PlayerEngine::sharpness() const { return impl_->video_sharpness.load(std::memory_order_relaxed); }

void PlayerEngine::reset_video_adjustments() {
    impl_->video_brightness.store(0.0f, std::memory_order_relaxed);
    impl_->video_contrast.store(1.0f, std::memory_order_relaxed);
    impl_->video_saturation.store(1.0f, std::memory_order_relaxed);
    impl_->video_sharpness.store(0.0f, std::memory_order_relaxed);
}

// Audio filter methods
void PlayerEngine::set_eq_enabled(bool e) { impl_->eq_enabled.store(e, std::memory_order_relaxed); }
bool PlayerEngine::is_eq_enabled() const { return impl_->eq_enabled.load(std::memory_order_relaxed); }
void PlayerEngine::set_eq_band(int band, float gain_db) {
    if (band >= 0 && band < 10) impl_->eq_bands[static_cast<size_t>(band)].store(gain_db, std::memory_order_relaxed);
}
float PlayerEngine::eq_band(int band) const {
    if (band >= 0 && band < 10) return impl_->eq_bands[static_cast<size_t>(band)].load(std::memory_order_relaxed);
    return 0.0f;
}
void PlayerEngine::set_eq_preset(int preset) { impl_->eq_preset.store(preset, std::memory_order_relaxed); }
int PlayerEngine::eq_preset() const { return impl_->eq_preset.load(std::memory_order_relaxed); }

void PlayerEngine::set_compressor_enabled(bool e) { impl_->compressor_enabled.store(e, std::memory_order_relaxed); }
bool PlayerEngine::is_compressor_enabled() const { return impl_->compressor_enabled.load(std::memory_order_relaxed); }
void PlayerEngine::set_compressor_threshold(float db) { impl_->compressor_threshold.store(db, std::memory_order_relaxed); }
void PlayerEngine::set_compressor_ratio(float r) { impl_->compressor_ratio.store(r, std::memory_order_relaxed); }
void PlayerEngine::set_compressor_attack(float ms) { impl_->compressor_attack.store(ms, std::memory_order_relaxed); }
void PlayerEngine::set_compressor_release(float ms) { impl_->compressor_release.store(ms, std::memory_order_relaxed); }
void PlayerEngine::set_compressor_makeup(float db) { impl_->compressor_makeup.store(db, std::memory_order_relaxed); }

void PlayerEngine::set_dialogue_boost_enabled(bool e) { impl_->dialogue_boost_enabled.store(e, std::memory_order_relaxed); }
bool PlayerEngine::is_dialogue_boost_enabled() const { return impl_->dialogue_boost_enabled.load(std::memory_order_relaxed); }
void PlayerEngine::set_dialogue_boost_amount(float a) { impl_->dialogue_boost_amount.store(a, std::memory_order_relaxed); }
float PlayerEngine::dialogue_boost_amount() const { return impl_->dialogue_boost_amount.load(std::memory_order_relaxed); }

PlaybackStats PlayerEngine::get_playback_stats() const {
    StatsContext ctx {
        .media_info = impl_->media_info,
        .active_video_stream = impl_->active_video_stream,
        .active_audio_stream = impl_->active_audio_stream,
        .audio_output = impl_->audio_output.get(),
        .audio_output_mode = impl_->audio_pipeline->output_mode(),
        .presented_frame_mutex = impl_->presented_frame_mutex,
        .presented_frame = impl_->presented_frame,
        .frames_rendered = impl_->frames_rendered,
        .frames_dropped = impl_->frames_dropped,
        .video_frame_queue = impl_->video_frame_queue,
        .video_packet_queue = impl_->video_packet_queue,
        .audio_packet_queue = impl_->audio_packet_queue,
        .audio_ring = impl_->audio_ring,
        .audio_ring_flush_mutex = impl_->audio_ring_flush_mutex,
        .passthrough_ring_size = impl_->audio_pipeline->passthrough_ring_size(),
        .passthrough_ring_capacity = impl_->audio_pipeline->passthrough_ring_capacity(),
        .clock = impl_->clock,
        .playback_speed = impl_->playback_speed,
    };
    auto stats = gather_playback_stats(ctx);
    stats.dv_asbdl_active = impl_->is_dv_output;
    return stats;
}

VideoFrame* PlayerEngine::acquire_video_frame(int64_t target_pts_us) {
    if (!impl_->frame_presenter) return nullptr;
    return impl_->frame_presenter->acquire(target_pts_us);
}

void PlayerEngine::release_video_frame(VideoFrame* frame) {
    if (impl_->frame_presenter) impl_->frame_presenter->release(frame);
}

SubtitleFrame PlayerEngine::get_subtitle_frame(int64_t timestamp_us) {
    return impl_->subtitle_manager->get_frame_at(timestamp_us);
}

void PlayerEngine::set_state_callback(StateCallback cb) {
    impl_->state_callback = std::move(cb);
}

void PlayerEngine::set_error_callback(ErrorCallback cb) {
    impl_->error_callback = std::move(cb);
}

// ---- Thread implementations ----

void PlayerEngine::Impl::demux_loop() {
    PY_LOG_INFO(TAG, "Demux thread started");

    while (running.load(std::memory_order_relaxed)) {
        // Handle full seek
        if (seeking.load(std::memory_order_relaxed)) {
            demuxer->seek(seek_target_us.load(std::memory_order_relaxed));

            // Flush subtitles again after demuxer has seeked, to discard any
            // stale packets that were fed between the main thread's flush and
            // the demuxer actually repositioning.
            subtitle_manager->flush();

            // Send flush packets
            Packet flush_pkt;
            flush_pkt.is_flush = true;

            if (active_video_stream >= 0) {
                flush_pkt.stream_index = active_video_stream;
                video_packet_queue.push(flush_pkt);
            }
            if (active_audio_stream >= 0) {
                flush_pkt.stream_index = active_audio_stream;
                audio_packet_queue.push(flush_pkt);
            }

            seeking.store(false);
        }

        Packet pkt;
        Error err = demuxer->read_packet(pkt);

        if (err.code == ErrorCode::EndOfFile) {
            PY_LOG_INFO(TAG, "Demux: end of file");
            // Send EOF flush packets (marked so decode loops can
            // drain reorder buffers instead of discarding them)
            Packet eof_pkt;
            eof_pkt.is_flush = true;
            eof_pkt.is_eof = true;
            if (active_video_stream >= 0) video_packet_queue.push(eof_pkt);
            if (active_audio_stream >= 0) audio_packet_queue.push(eof_pkt);
            break;
        }
        if (err) {
            report_error(err);
            break;
        }

        // Route packet to the correct queue
        if (pkt.stream_index == active_video_stream) {
            if (!video_packet_queue.push(std::move(pkt))) break;
        } else if (pkt.stream_index == active_audio_stream) {
            if (!audio_packet_queue.push(std::move(pkt))) break;
        } else if (pkt.stream_index == active_subtitle_stream.load(std::memory_order_acquire)) {
            subtitle_manager->feed_packet(pkt);
        }
    }

    PY_LOG_INFO(TAG, "Demux thread ended");
}

void PlayerEngine::Impl::dv_video_decode_loop() {
#ifdef __APPLE__
    PY_LOG_INFO(TAG, "DV video output thread started");

    // Wait for the display layer to be set from Swift before consuming packets.
    // The layer is created asynchronously by SwiftUI after open() returns.
    PY_LOG_INFO(TAG, "DV output: waiting for display layer...");
    while (!dv_output->has_display_layer() && running.load(std::memory_order_relaxed)) {
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    if (!running.load(std::memory_order_relaxed)) return;
    PY_LOG_INFO(TAG, "DV output: display layer ready, starting packet feed");

    bool first_packet = true;

    while (running.load(std::memory_order_relaxed)) {
        Packet pkt;
        if (!video_packet_queue.pop(pkt)) break;

        if (pkt.is_flush) {
            dv_output->flush();
            first_packet = true;
            if (pkt.is_eof) {
                PY_LOG_INFO(TAG, "DV output: end of file");
                break;
            }
            continue;
        }

        if (pkt.data.empty()) continue;

        // Wait until the display layer is ready for more data
        int wait_count = 0;
        while (!dv_output->is_ready() && running.load(std::memory_order_relaxed)) {
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
            if (++wait_count > 1000) {
                PY_LOG_WARN(TAG, "DV output: layer not ready for >1s");
                wait_count = 0;
            }
        }
        if (!running.load(std::memory_order_relaxed)) break;

        Error err = dv_output->submit_packet(pkt);
        if (err) {
            PY_LOG_WARN(TAG, "DV output submit failed: %s", err.message.c_str());
        }

        // Periodically re-sync ASBDL timebase with player clock (~every 5s)
        // to prevent drift between the video display layer and audio output.
        int64_t now_us = clock.now_us();
        if (now_us - last_dv_sync_us > 5000000) {
            dv_output->set_time(now_us);
            last_dv_sync_us = now_us;
        }

        // Release first-frame gate after first successful packet submission
        if (first_packet && err.ok()) {
            first_packet = false;
            waiting_for_first_frame.store(false, std::memory_order_release);

            // Check ASBDL renderer status after a brief delay to detect
            // silent failures (e.g., Profile 5 not supported by ASBDL).
            std::this_thread::sleep_for(std::chrono::milliseconds(50));
            if (!dv_output->is_ready()) {
                PY_LOG_WARN(TAG, "DV ASBDL: renderer failed after first packet, requesting fallback");
                dv_fallback_needed.store(true, std::memory_order_release);
                break;
            }
        }
    }

    PY_LOG_INFO(TAG, "DV video output thread ended");
#endif
}

void PlayerEngine::Impl::video_decode_loop() {
    // DV content: route to ASBDL output loop instead
    if (is_dv_output) {
        dv_video_decode_loop();

        // If ASBDL failed (e.g., Profile 5 unsupported), fall back to FFmpeg + Metal
        if (dv_fallback_needed.load(std::memory_order_acquire)) {
            PY_LOG_INFO(TAG, "DV ASBDL fallback: switching to FFmpeg + Metal");
#ifdef __APPLE__
            dv_output->close();
            dv_output.reset();
#endif
            is_dv_output = false;
            dv_fallback_needed.store(false, std::memory_order_release);

            // Create FFmpeg decoder and restart
            const auto& track = media_info.tracks[static_cast<size_t>(active_video_stream)];
            video_decoder = VideoDecoderFactory::create(track, hw_decode_pref);
            if (!video_decoder) {
                PY_LOG_ERROR(TAG, "DV fallback: no decoder available");
                return;
            }
            // Fall through to normal decode loop below
        } else {
            return;
        }
    }

    PY_LOG_INFO(TAG, "Video decode thread started");

    if (!video_decoder) return;

    bool skip_to_target = false;

    // Deinterlace filter (SW decode path only)
    DeinterlaceFilter deint;
    bool deint_initialized = false;

    // Helper: drain completed frames from the decoder into the frame queue.
    // Uses blocking push — with a 64-frame queue, blocks are brief (~1 frame
    // time) and the audio pipeline has its own 128-packet + 4-second ring
    // buffer to survive without the demux thread.
    // IMPORTANT: try_push was tried before but silently DROPS frames when the
    // queue is full (the moved-from VideoFrame is destroyed). This caused
    // periodic stuttering every ~2 seconds.
    auto drain_frames = [&]() -> bool {
        while (running.load(std::memory_order_relaxed)) {
            VideoFrame frame;
            Error err = video_decoder->receive_frame(frame);
            if (err.code == ErrorCode::OutputNotReady) break;
            if (err.code == ErrorCode::EndOfFile) break;
            if (err) {
                PY_LOG_WARN(TAG, "Video receive_frame error: %s", err.message.c_str());
                break;
            }
            if (skip_to_target) {
                if (frame.pts_us < seek_target_us.load(std::memory_order_relaxed)) continue;
                skip_to_target = false;
                video_decoder->set_skip_mode(false);
                if (frame.pts_only) continue; // PTS-only from skip mode; next will be full
                // Full frame from DVSeekDecoder replay — push it directly
                if (!video_frame_queue.push(std::move(frame))) return false;
                continue;
            }

            // CPU deinterlace: only for SW-decoded frames with plane data (not CVPixelBuffer)
            if (deinterlace_enabled.load(std::memory_order_relaxed) &&
                !frame.hardware_frame && frame.planes[0] != nullptr && !frame.pts_only) {
                // Lazy-init deinterlace filter
                if (!deint_initialized) {
                    int pix_fmt_id = 0; // AV_PIX_FMT_NV12
                    if (frame.pixel_format == PixelFormat::YUV420P) pix_fmt_id = 0; // AV_PIX_FMT_YUV420P
                    else if (frame.pixel_format == PixelFormat::NV12) pix_fmt_id = 23; // AV_PIX_FMT_NV12
                    else if (frame.pixel_format == PixelFormat::P010) pix_fmt_id = 166; // AV_PIX_FMT_P010
                    else if (frame.pixel_format == PixelFormat::YUV420P10) pix_fmt_id = 66; // AV_PIX_FMT_YUV420P10LE

                    deint.set_mode(static_cast<DeinterlaceFilter::Mode>(
                        deinterlace_mode.load(std::memory_order_relaxed)));
                    Error di_err = deint.open(frame.width, frame.height, pix_fmt_id, 1, 25);
                    if (!di_err) deint_initialized = true;
                }

                if (deint_initialized) {
                    // Build a temporary AVFrame from VideoFrame plane data
                    AVFrame* av_frame = av_frame_alloc();
                    av_frame->width = frame.width;
                    av_frame->height = frame.height;
                    av_frame->format = (frame.pixel_format == PixelFormat::YUV420P) ? 0 :
                                       (frame.pixel_format == PixelFormat::NV12) ? 23 :
                                       (frame.pixel_format == PixelFormat::P010) ? 166 : 66;
                    av_frame->pts = frame.pts_us;
                    for (int i = 0; i < 4; i++) {
                        av_frame->data[i] = const_cast<uint8_t*>(frame.planes[i]);
                        av_frame->linesize[i] = frame.strides[i];
                    }

                    if (deint.send_frame(av_frame) >= 0) {
                        AVFrame* out = av_frame_alloc();
                        if (deint.receive_frame(out) >= 0) {
                            // Update frame plane pointers to the filtered data.
                            // Allocate new plane_data to own the deinterlaced output.
                            size_t total = 0;
                            for (int i = 0; i < 4 && out->linesize[i] > 0; i++) {
                                total += static_cast<size_t>(out->linesize[i]) *
                                         static_cast<size_t>(i == 0 ? out->height : out->height / 2);
                            }
                            std::shared_ptr<uint8_t[]> new_data(new uint8_t[total]);
                            size_t offset = 0;
                            for (int i = 0; i < 4 && out->data[i]; i++) {
                                int h = (i == 0) ? out->height : out->height / 2;
                                size_t plane_size = static_cast<size_t>(out->linesize[i]) * static_cast<size_t>(h);
                                memcpy(new_data.get() + offset, out->data[i], plane_size);
                                frame.planes[i] = new_data.get() + offset;
                                frame.strides[i] = out->linesize[i];
                                offset += plane_size;
                            }
                            frame.plane_data = new_data;
                            frame.pts_us = out->pts;
                        }
                        av_frame_free(&out);
                    }

                    // Clear references to our non-owned data before freeing
                    for (int i = 0; i < 4; i++) av_frame->data[i] = nullptr;
                    av_frame_free(&av_frame);
                }
            }

            if (!video_frame_queue.push(std::move(frame))) return false;
        }
        return true;
    };

    while (running.load(std::memory_order_relaxed)) {
        // Drain any frames completed by the async decoder from previous iterations.
        // This is critical for VT: after send_packet, the GPU decodes asynchronously
        // and frames arrive via callback. We must collect them before blocking on
        // the packet queue, otherwise the frame queue starves.
        if (!drain_frames()) break;

        Packet pkt;
        // Use timed wait: if VT has packets in flight, we need to wake up
        // periodically to drain completed frames even if no new packets arrive.
        // 16ms (~1 vsync) balances responsiveness vs CPU/power usage.
        if (!video_packet_queue.try_pop_for(pkt, std::chrono::milliseconds(16))) {
            continue; // No packet yet — loop back to drain any completed frames
        }

        if (pkt.is_flush) {
            if (pkt.is_eof) {
                // End of stream: drain the reorder buffer so the last
                // few frames reach the output queue instead of being lost.
                video_decoder->drain();
                drain_frames();
                PY_LOG_INFO(TAG, "Video EOF: final frames drained");
                set_state(PlaybackState::Stopped);
                break;
            }
            // Seek: discard stale frames and start fresh
            video_decoder->flush();
            video_frame_queue.flush();
            skip_to_target = true;
            video_decoder->set_seek_target(seek_target_us.load(std::memory_order_relaxed));
            video_decoder->set_skip_mode(true);
            continue;
        }

        Error send_err = video_decoder->send_packet(pkt);
        if (send_err && send_err.code != ErrorCode::NeedMoreInput) {
            PY_LOG_WARN(TAG, "Video send_packet error: %s", send_err.message.c_str());
            continue;
        }

        // Drain frames that may have completed during or after send_packet
        if (!drain_frames()) break;

        if (send_err.code == ErrorCode::NeedMoreInput) {
            video_decoder->send_packet(pkt);
        }
    }

    PY_LOG_INFO(TAG, "Video decode thread ended");
}

void PlayerEngine::Impl::audio_decode_loop() {
    PY_LOG_INFO(TAG, "Audio decode thread started");

    if (audio_pipeline->output_mode() == AudioOutputMode::Passthrough) {
        audio_pipeline->passthrough_write_loop();
        return;
    }

    if (!audio_decoder || !audio_output) return;

    AVCodecContext* ctx = open_audio_codec(media_info.tracks[static_cast<size_t>(active_audio_stream)]);
    if (!ctx) return;

    // Audio filter chain: tempo (pre-resample) → resampler → EQ → compressor → dialogue boost
    AudioFilterChain filter_chain;
    auto* tempo = new AudioTempoFilter();
    filter_chain.add(std::unique_ptr<IAudioFilter>(tempo));
    auto eq_ptr = std::make_unique<EqualizerFilter>();
    auto* eq = eq_ptr.get();
    filter_chain.add(std::move(eq_ptr));
    auto comp_ptr = std::make_unique<CompressorFilter>();
    auto* comp = comp_ptr.get();
    filter_chain.add(std::move(comp_ptr));
    auto db_ptr = std::make_unique<DialogueBoostFilter>();
    auto* dialogue = db_ptr.get();
    filter_chain.add(std::move(db_ptr));

    // Sync initial filter state from PlayerEngine settings
    auto sync_filter_state = [&]() {
        eq->set_enabled(eq_enabled.load(std::memory_order_relaxed));
        for (int i = 0; i < 10; i++)
            eq->set_band_gain(i, eq_bands[static_cast<size_t>(i)].load(std::memory_order_relaxed));
        comp->set_enabled(compressor_enabled.load(std::memory_order_relaxed));
        comp->set_threshold(compressor_threshold.load(std::memory_order_relaxed));
        comp->set_ratio(compressor_ratio.load(std::memory_order_relaxed));
        comp->set_attack(compressor_attack.load(std::memory_order_relaxed));
        comp->set_release(compressor_release.load(std::memory_order_relaxed));
        comp->set_makeup(compressor_makeup.load(std::memory_order_relaxed));
        dialogue->set_enabled(dialogue_boost_enabled.load(std::memory_order_relaxed));
        dialogue->set_amount(dialogue_boost_amount.load(std::memory_order_relaxed));
    };
    sync_filter_state();

    int out_rate = audio_output->sample_rate();
    int out_channels = audio_output->channels();

    AVFrame* av_frame = av_frame_alloc();
    AVPacket* av_pkt = av_packet_alloc();
    bool chain_initialized = false;
    bool chain_fatal = false;
    bool timebase_initialized = false;
    bool skip_to_target = false;
    std::vector<float> resample_buf; // reused across frames

    while (running.load(std::memory_order_relaxed)) {
        Packet pkt;
        if (!audio_packet_queue.pop(pkt)) break;

        // Handle speed change from the main thread
        if (speed_changed.load(std::memory_order_relaxed)) {
            speed_changed.store(false);
            double new_speed = playback_speed.load();
            tempo->set_tempo(new_speed);
            tempo->set_enabled(std::abs(new_speed - 1.0) > 0.001);
        }

        // Sync audio filter state from main thread settings
        sync_filter_state();

        if (pkt.is_flush) {
            {
                std::lock_guard lock(audio_ring_flush_mutex);
                audio_ring.reset();
            }
            filter_chain.flush();

            if (audio_track_changed.load(std::memory_order_relaxed)) {
                audio_track_changed.store(false);

                int new_stream;
                {
                    std::lock_guard lock(audio_ring_flush_mutex);
                    new_stream = pending_audio_stream;
                }

                // Close old decoder and filter chain
                avcodec_free_context(&ctx);
                filter_chain.close();
                chain_initialized = false;
                timebase_initialized = false;

                // Open new decoder
                const auto& new_track = media_info.tracks[static_cast<size_t>(new_stream)];
                ctx = open_audio_codec(new_track);
                if (!ctx) {
                    PY_LOG_ERROR(TAG, "Failed to open new audio decoder");
                    break;
                }

                // Handle channel count change: reconfigure audio output
                int new_source_ch = new_track.channels;
                int new_device_max = audio_output->max_device_channels();
                int new_out_channels = std::min(new_source_ch, new_device_max);
                if (new_out_channels != out_channels || new_track.sample_rate != out_rate) {
                    audio_output->stop();
                    audio_output->close();
                    out_rate = new_track.sample_rate;
                    out_channels = new_out_channels;
                    Error ao_err = audio_output->open(out_rate, out_channels);
                    if (ao_err) {
                        PY_LOG_ERROR(TAG, "Failed to reopen audio output: %s", ao_err.message.c_str());
                        break;
                    }
                    // Resize ring buffer (safe: audio output is stopped)
                    audio_ring.resize(static_cast<size_t>(
                        out_rate * out_channels * AUDIO_RING_SECONDS));
                    audio_output->set_pull_callback(
                        [this](float* buf, int frames, int ch) {
                            return audio_pipeline->pcm_pull(buf, frames, ch);
                        });
                    audio_output->set_pts_callback([](int64_t) {});
                    audio_output->set_muted(muted);
                    audio_output->set_volume(volume);
                    audio_output->start();
                    PY_LOG_INFO(TAG, "Audio output reconfigured: %d Hz, %d ch", out_rate, out_channels);
                }

                PY_LOG_INFO(TAG, "Audio decoder switched to stream %d (%s)",
                            new_stream, new_track.codec_name.c_str());
            } else {
                avcodec_flush_buffers(ctx);
                skip_to_target = true;
            }
            continue;
        }

        // Set pkt_timebase from the first real packet so PTS conversion works
        if (!timebase_initialized && pkt.time_base_den > 0) {
            ctx->pkt_timebase = AVRational{pkt.time_base_num, pkt.time_base_den};
            timebase_initialized = true;
        }

        av_pkt->data = const_cast<uint8_t*>(pkt.data.data());
        av_pkt->size = static_cast<int>(pkt.data.size());
        av_pkt->pts = pkt.pts;
        av_pkt->dts = pkt.dts;
        av_pkt->duration = pkt.duration;

        int send_ret = avcodec_send_packet(ctx, av_pkt);
        if (send_ret < 0 && send_ret != AVERROR(EAGAIN)) continue;

        // Drain all available decoded frames
        while (running.load(std::memory_order_relaxed)) {
            int ret = avcodec_receive_frame(ctx, av_frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            // Lazy init filter chain (needs actual codec format from first decoded frame)
            if (!chain_initialized) {
                Error err = filter_chain.open(ctx, out_rate, out_channels);
                if (err) {
                    PY_LOG_ERROR(TAG, "Filter chain init failed: %s", err.message.c_str());
                    chain_fatal = true;
                    break;
                }
                chain_initialized = true;
                resample_buf.reserve(static_cast<size_t>(out_rate) * static_cast<size_t>(out_channels) / 10); // 100ms
                // Init tempo if speed != 1.0
                double spd = playback_speed.load();
                if (std::abs(spd - 1.0) > 0.001) {
                    tempo->set_tempo(spd);
                    tempo->set_enabled(true);
                }
            }

            // Calculate PTS for this audio chunk
            int64_t pts_us = 0;
            if (av_frame->pts != AV_NOPTS_VALUE && ctx->pkt_timebase.den > 0) {
                pts_us = av_rescale_q(av_frame->pts, ctx->pkt_timebase, {1, 1000000});
            }

            // After seek, skip audio before the target so the clock
            // unfreezes at the right position instead of jumping backward.
            if (skip_to_target) {
                if (pts_us < seek_target_us.load(std::memory_order_relaxed)) {
                    av_frame_unref(av_frame);
                    continue;
                }
                skip_to_target = false;
            }

            // Push frame through the filter chain and drain all output chunks.
            // Pre-resample filters (tempo) may produce multiple output frames per input.
            filter_chain.send_frame(av_frame);

            int num_samples = 0;
            while (filter_chain.drain(resample_buf, num_samples)) {
                if (num_samples <= 0) break;
                if (!running.load(std::memory_order_relaxed) || audio_restart_requested.load(std::memory_order_relaxed)) break;

                size_t to_write = static_cast<size_t>(num_samples) * static_cast<size_t>(out_channels);
                {
                    std::unique_lock lock(audio_ring_flush_mutex);
                    audio_ring_not_full.wait(lock, [&] {
                        return audio_ring.available_write() >= to_write ||
                               !running.load(std::memory_order_relaxed) || audio_restart_requested.load(std::memory_order_relaxed);
                    });
                }
                if (!running.load(std::memory_order_relaxed) || audio_restart_requested.load(std::memory_order_relaxed)) break;

                audio_ring.write(resample_buf.data(), to_write);

                int64_t chunk_duration_us = static_cast<int64_t>(num_samples) * 1000000LL / out_rate;
                audio_pts_for_ring.store(pts_us + chunk_duration_us, std::memory_order_release);
            }

            av_frame_unref(av_frame);
        }

        if (chain_fatal) break;

        // If send_packet returned EAGAIN, the packet was NOT consumed.
        // Retry now that we've drained output frames.
        if (send_ret == AVERROR(EAGAIN)) {
            avcodec_send_packet(ctx, av_pkt);
        }
    }

    av_frame_free(&av_frame);
    av_packet_free(&av_pkt);
    filter_chain.close();
    avcodec_free_context(&ctx);

    PY_LOG_INFO(TAG, "Audio decode thread ended");
}

void PlayerEngine::Impl::stop_threads() {
    running.store(false);
    video_packet_queue.abort();
    audio_packet_queue.abort();
    video_frame_queue.abort();

    // Wake the audio decode thread if it's blocked waiting for ring buffer space
    audio_ring_not_full.notify_all();

    if (demux_thread.joinable()) demux_thread.join();
    if (video_decode_thread.joinable()) video_decode_thread.join();
    if (audio_decode_thread.joinable()) audio_decode_thread.join();
}

} // namespace py
