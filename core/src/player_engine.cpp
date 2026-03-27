#include "plaiy/player_engine.h"
#include "plaiy/clock.h"
#include "plaiy/frame_queue.h"
#include "plaiy/logger.h"
#include "plaiy/packet_queue.h"
#include "plaiy/spsc_ring_buffer.h"
#include "plaiy/subtitle_manager.h"

#include "demuxer/ff_demuxer.h"
#include "video/video_decoder_factory.h"
#include "audio/audio_decoder.h"
#include "audio/audio_resampler.h"
#include "audio/audio_tempo_filter.h"
#include "audio/audio_passthrough.h"
#include "playback_stats.h"

#ifdef __APPLE__
#include "../platform/apple/ca_audio_output.h"
#endif
#include "frame_presenter.h"
#include "audio_pipeline.h"


extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include <algorithm>
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
    std::unique_ptr<AudioResampler> audio_resampler;
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

    // Open video decoder
    if (impl_->active_video_stream >= 0) {
        const auto& track = impl_->media_info.tracks[static_cast<size_t>(impl_->active_video_stream)];
        impl_->video_decoder = VideoDecoderFactory::create(track, impl_->hw_decode_pref);
        if (!impl_->video_decoder) {
            return {ErrorCode::DecoderInitFailed, "No video decoder available"};
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

    // Create frame presenter for A-V sync
    impl_->frame_presenter = std::make_unique<FramePresenter>(
        impl_->video_frame_queue,
        impl_->clock,
        impl_->presented_frame_mutex,
        impl_->presented_frame,
        impl_->waiting_for_first_frame,
        impl_->frames_rendered,
        impl_->frames_dropped);

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
    impl_->set_state(PlaybackState::Playing);
}

void PlayerEngine::pause() {
    if (impl_->state.load() != PlaybackState::Playing) return;

    impl_->clock.set_paused(true);
    if (impl_->audio_output) impl_->audio_output->stop();
    impl_->set_state(PlaybackState::Paused);
}

void PlayerEngine::seek(int64_t timestamp_us) {
    impl_->seek_target_us.store(timestamp_us, std::memory_order_relaxed);
    impl_->seeking.store(true);

    // Freeze clock and hold audio until the video renderer presents its first
    // post-seek frame (prevents the clock from running ahead of video).
    // For audio-only files, just set the PTS without freezing.
    if (impl_->active_video_stream >= 0) {
        impl_->waiting_for_first_frame.store(true);
        impl_->clock.seek_to(timestamp_us);
    } else {
        impl_->clock.set_audio_pts(timestamp_us);
    }

    // Reset audio output position tracking
    if (impl_->audio_output) impl_->audio_output->reset_position();

    // Flush queues
    impl_->video_packet_queue.flush();
    impl_->audio_packet_queue.flush();
    impl_->video_frame_queue.flush();

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
    impl_->audio_resampler.reset();
    impl_->audio_pipeline->teardown();
    impl_->audio_ring.release();
    impl_->subtitle_manager->close();
    impl_->demuxer->close();

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
                                  impl_->audio_decoder, impl_->audio_resampler,
                                  impl_->spatial_audio_mode,
                                  impl_->head_tracking_enabled,
                                  impl_->muted, impl_->volume);
}

void PlayerEngine::restart_audio_pipeline() {
    if (impl_->active_audio_stream < 0) return;

    const auto& track = impl_->media_info.tracks[static_cast<size_t>(impl_->active_audio_stream)];
    impl_->audio_pipeline->restart(track, impl_->audio_output,
                                    impl_->audio_decoder, impl_->audio_resampler,
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
    return gather_playback_stats(ctx);
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

void PlayerEngine::Impl::video_decode_loop() {
    PY_LOG_INFO(TAG, "Video decode thread started");

    if (!video_decoder) return;

    bool skip_to_target = false;

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

    // Set up resampler
    AudioResampler resampler;
    int out_rate = audio_output->sample_rate();
    int out_channels = audio_output->channels();
    // We'll init the resampler after first frame decode when we know the actual format

    AVFrame* av_frame = av_frame_alloc();
    AVFrame* tempo_frame = av_frame_alloc();
    AVPacket* av_pkt = av_packet_alloc();
    bool resampler_initialized = false;
    bool resampler_fatal = false;
    bool timebase_initialized = false;
    bool skip_to_target = false;
    std::vector<float> resample_buf; // reused across frames
    AudioTempoFilter tempo_filter;

    while (running.load(std::memory_order_relaxed)) {
        Packet pkt;
        if (!audio_packet_queue.pop(pkt)) break;

        // Handle speed change from the main thread
        if (speed_changed.load(std::memory_order_relaxed)) {
            speed_changed.store(false);
            double new_speed = playback_speed.load();
            tempo_filter.close();
            if (std::abs(new_speed - 1.0) > 0.001 && resampler_initialized) {
                tempo_filter.open(ctx, new_speed);
            }
        }

        if (pkt.is_flush) {
            {
                std::lock_guard lock(audio_ring_flush_mutex);
                audio_ring.reset();
            }
            tempo_filter.flush();

            if (audio_track_changed.load(std::memory_order_relaxed)) {
                audio_track_changed.store(false);

                int new_stream;
                {
                    std::lock_guard lock(audio_ring_flush_mutex);
                    new_stream = pending_audio_stream;
                }

                // Close old decoder
                avcodec_free_context(&ctx);
                resampler.close();
                resampler_initialized = false;
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

            // Lazy init resampler
            if (!resampler_initialized) {
                Error err = resampler.open(ctx, out_rate, out_channels);
                if (err) {
                    PY_LOG_ERROR(TAG, "Resampler init failed: %s", err.message.c_str());
                    resampler_fatal = true;
                    break;
                }
                resampler_initialized = true;
                resample_buf.reserve(static_cast<size_t>(out_rate) * static_cast<size_t>(out_channels) / 10); // 100ms
                // Init tempo filter if speed != 1.0
                double spd = playback_speed.load();
                if (std::abs(spd - 1.0) > 0.001) {
                    tempo_filter.open(ctx, spd);
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

            // Lambda to resample a frame and write to ring buffer
            auto resample_and_write = [&](AVFrame* frame, int64_t frame_pts_us) {
                int num_samples = 0;
                Error err = resampler.convert(frame, resample_buf, num_samples);
                if (err) return;

                size_t to_write = static_cast<size_t>(num_samples) * static_cast<size_t>(out_channels);
                {
                    std::unique_lock lock(audio_ring_flush_mutex);
                    audio_ring_not_full.wait(lock, [&] {
                        return audio_ring.available_write() >= to_write ||
                               !running.load(std::memory_order_relaxed) || audio_restart_requested.load(std::memory_order_relaxed);
                    });
                }
                if (!running.load(std::memory_order_relaxed) || audio_restart_requested.load(std::memory_order_relaxed)) return;

                audio_ring.write(resample_buf.data(), to_write);

                int64_t chunk_duration_us = static_cast<int64_t>(num_samples) * 1000000LL / out_rate;
                audio_pts_for_ring.store(frame_pts_us + chunk_duration_us, std::memory_order_release);
            };

            // Route through tempo filter if active, otherwise direct resample
            if (tempo_filter.tempo() != 1.0) {
                tempo_filter.send_frame(av_frame);
                while (running.load(std::memory_order_relaxed)) {
                    int tret = tempo_filter.receive_frame(tempo_frame);
                    if (tret < 0) break;

                    int64_t tempo_pts_us = 0;
                    if (tempo_frame->pts != AV_NOPTS_VALUE && ctx->pkt_timebase.den > 0) {
                        tempo_pts_us = av_rescale_q(tempo_frame->pts, ctx->pkt_timebase, {1, 1000000});
                    }
                    resample_and_write(tempo_frame, tempo_pts_us);
                    av_frame_unref(tempo_frame);
                }
            } else {
                resample_and_write(av_frame, pts_us);
            }

            av_frame_unref(av_frame);
        }

        if (resampler_fatal) break;

        // If send_packet returned EAGAIN, the packet was NOT consumed.
        // Retry now that we've drained output frames.
        if (send_ret == AVERROR(EAGAIN)) {
            avcodec_send_packet(ctx, av_pkt);
        }
    }

    av_frame_free(&av_frame);
    av_frame_free(&tempo_frame);
    av_packet_free(&av_pkt);
    tempo_filter.close();
    resampler.close();
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
