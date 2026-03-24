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
#include "audio/mat_framer.h"

#ifdef __APPLE__
#include "../platform/apple/ca_audio_output.h"
#endif

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

    // Passthrough state
    AudioOutputMode audio_output_mode = AudioOutputMode::PCM;
    bool passthrough_preferred = false;
    int passthrough_codec_profile = -1;

    // Settings
    HWDecodePreference hw_decode_pref = HWDecodePreference::Auto;
    bool muted = false;
    float volume = 1.0f;

    // Playback speed
    std::atomic<double> playback_speed{1.0};
    std::atomic<bool> speed_changed{false};

    // Byte ring buffer for passthrough mode
    std::vector<uint8_t> passthrough_ring_buffer;
    size_t passthrough_ring_read = 0;
    size_t passthrough_ring_write = 0;
    size_t passthrough_ring_size = 0;
    size_t passthrough_ring_capacity = 0;
    int64_t passthrough_pts_for_ring = 0;
    int passthrough_bytes_per_second = 0;
    std::unique_ptr<MATFramer> mat_framer;

    // Track indices
    int active_video_stream = -1;
    int active_audio_stream = -1;
    int active_subtitle_stream = -1;

    // For seek
    std::atomic<bool> seeking{false};
    int64_t seek_target_us = 0;

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
    int audio_pull(float* buffer, int frames, int channels);
    void passthrough_write_loop();
    int bitstream_pull(uint8_t* buffer, int bytes);
    void stop_threads();

    // For audio pipeline restart (live toggle / track change)
    std::atomic<bool> audio_restart_requested{false};
};

PlayerEngine::PlayerEngine() : impl_(std::make_unique<Impl>()) {
    impl_->demuxer = std::make_unique<FFDemuxer>();
    impl_->subtitle_manager = std::make_unique<SubtitleManager>();
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
        const auto& track = impl_->media_info.tracks[impl_->active_video_stream];
        impl_->video_decoder = VideoDecoderFactory::create(track, impl_->hw_decode_pref);
        if (!impl_->video_decoder) {
            return {ErrorCode::DecoderInitFailed, "No video decoder available"};
        }
        impl_->subtitle_manager->set_video_size(track.width, track.height);
    }

    // Open audio decoder + resampler + output
    if (impl_->active_audio_stream >= 0) {
        setup_audio_output(impl_->media_info.tracks[impl_->active_audio_stream]);
    }

    // Open subtitle track
    if (impl_->active_subtitle_stream >= 0) {
        const auto& track = impl_->media_info.tracks[impl_->active_subtitle_stream];
        impl_->subtitle_manager->set_embedded_track(track);
    }

    impl_->set_state(PlaybackState::Ready);
    PY_LOG_INFO(TAG, "File opened: %s (%.1fs)",
                path.c_str(), impl_->media_info.duration_us / 1e6);
    return Error::Ok();
}

void PlayerEngine::play() {
    auto s = impl_->state.load();
    if (s != PlaybackState::Ready && s != PlaybackState::Paused) return;

    if (!impl_->running.load()) {
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
        if (impl_->active_video_stream >= 0) {
            impl_->waiting_for_first_frame.store(true);
            impl_->clock.seek_to(0);
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
    impl_->seek_target_us = timestamp_us;
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
    {
        std::lock_guard lock(impl_->audio_ring_flush_mutex);
        if (impl_->audio_output_mode == AudioOutputMode::Passthrough) {
            impl_->passthrough_ring_read = 0;
            impl_->passthrough_ring_write = 0;
            impl_->passthrough_ring_size = 0;
            impl_->passthrough_pts_for_ring = timestamp_us;
        } else {
            impl_->audio_ring.reset();
            impl_->audio_pts_for_ring.store(timestamp_us, std::memory_order_release);
        }
    }
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
    impl_->audio_output_mode = AudioOutputMode::PCM;
    impl_->passthrough_codec_profile = -1;
    impl_->mat_framer.reset();
    impl_->audio_ring.release();
    impl_->passthrough_ring_buffer.clear();
    impl_->passthrough_ring_buffer.shrink_to_fit();
    impl_->subtitle_manager->close();
    impl_->demuxer->close();

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
         impl_->media_info.tracks[stream_index].type != MediaType::Audio)) {
        PY_LOG_WARN(TAG, "Invalid audio stream index: %d", stream_index);
        return;
    }

    auto s = impl_->state.load();
    bool is_playing = (s == PlaybackState::Playing || s == PlaybackState::Paused);

    // If in passthrough mode, or switching to a track that requires a mode change,
    // use the full restart path for clean teardown/rebuild.
    bool needs_restart = false;
    if (is_playing && impl_->audio_output_mode == AudioOutputMode::Passthrough) {
        needs_restart = true;  // Always restart when leaving passthrough
    } else if (is_playing && impl_->passthrough_preferred && stream_index >= 0) {
        const auto& new_track = impl_->media_info.tracks[stream_index];
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
    impl_->active_subtitle_stream = stream_index;
    if (stream_index >= 0 && stream_index < static_cast<int>(impl_->media_info.tracks.size())) {
        impl_->subtitle_manager->set_embedded_track(impl_->media_info.tracks[stream_index]);
    } else {
        impl_->subtitle_manager->close();
    }
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
    return impl_->active_subtitle_stream;
}

void PlayerEngine::setup_audio_output(const TrackInfo& track) {
    // Create audio output if needed
    if (!impl_->audio_output) {
#ifdef __APPLE__
        impl_->audio_output = std::make_unique<CAAudioOutput>();
#endif
    }
    if (!impl_->audio_output) return;

    bool passthrough_ok = false;

    // Try passthrough if preferred and codec is eligible
    if (impl_->passthrough_preferred && is_passthrough_eligible(track.codec_id, track.codec_profile)) {
        auto err = impl_->audio_output->open_passthrough(track.codec_id, track.codec_profile, track.sample_rate, track.channels);
        if (!err) {
            impl_->audio_output_mode = AudioOutputMode::Passthrough;
            impl_->passthrough_codec_profile = track.codec_profile;
            passthrough_ok = true;

            // Set up byte ring buffer for passthrough
            int bps = passthrough_bytes_per_second(track.codec_id, track.codec_profile);
            impl_->passthrough_bytes_per_second = bps;
            impl_->passthrough_ring_capacity = static_cast<size_t>(bps * Impl::AUDIO_RING_SECONDS);
            impl_->passthrough_ring_buffer.resize(impl_->passthrough_ring_capacity);
            impl_->passthrough_ring_read = 0;
            impl_->passthrough_ring_write = 0;
            impl_->passthrough_ring_size = 0;

            impl_->audio_output->set_muted(impl_->muted);
            impl_->audio_output->set_volume(impl_->volume);
            impl_->audio_output->set_bitstream_pull_callback(
                [this](uint8_t* buf, int bytes) {
                    return impl_->bitstream_pull(buf, bytes);
                });

            // Create MAT framer for TrueHD (HDMI requires MAT encapsulation)
            if (track.codec_id == AV_CODEC_ID_TRUEHD) {
                impl_->mat_framer = std::make_unique<MATFramer>();
                auto mat_err = impl_->mat_framer->open(track.codec_id, track.sample_rate, track.channels);
                if (mat_err) {
                    PY_LOG_WARN(TAG, "MAT framer open failed: %s", mat_err.message.c_str());
                    impl_->mat_framer.reset();
                }
            }

            PY_LOG_INFO(TAG, "Audio passthrough: %s at %d Hz",
                        track.codec_name.c_str(), track.sample_rate);
        } else {
            PY_LOG_INFO(TAG, "Passthrough not available (%s), falling back to decode",
                        err.message.c_str());
        }
    }

    // Normal PCM decode path
    if (!passthrough_ok) {
        impl_->audio_output_mode = AudioOutputMode::PCM;
        impl_->audio_decoder = std::make_unique<AudioDecoder>();
        auto err = impl_->audio_decoder->open(track);
        if (err) {
            PY_LOG_WARN(TAG, "Audio decoder open failed: %s", err.message.c_str());
            impl_->audio_decoder.reset();
            impl_->audio_output.reset();
        } else {
            int out_rate = impl_->audio_decoder->sample_rate();
            int source_ch = impl_->audio_decoder->channels();
            int device_max = impl_->audio_output->max_device_channels();
            int out_channels = std::min(source_ch, device_max);
            PY_LOG_INFO(TAG, "Audio: source=%d ch, device_max=%d ch, output=%d ch",
                        source_ch, device_max, out_channels);

            err = impl_->audio_output->open(out_rate, out_channels);
            if (err) {
                PY_LOG_WARN(TAG, "Audio output open failed: %s", err.message.c_str());
                impl_->audio_output.reset();
            } else {
                // Set up ring buffer sized for the actual audio format
                impl_->audio_ring.resize(static_cast<size_t>(
                    out_rate * out_channels * Impl::AUDIO_RING_SECONDS));

                // Audio pull callback
                impl_->audio_output->set_pull_callback(
                    [this](float* buf, int frames, int ch) {
                        return impl_->audio_pull(buf, frames, ch);
                    });

                // PTS callback for clock sync (ring buffer PTS tracking handles this)
                impl_->audio_output->set_pts_callback([](int64_t) {});
                impl_->audio_output->set_muted(impl_->muted);
                impl_->audio_output->set_volume(impl_->volume);
            }
        }
    }
}

void PlayerEngine::restart_audio_pipeline() {
    if (impl_->active_audio_stream < 0) return;

    PY_LOG_INFO(TAG, "Restarting audio pipeline");

    // 1. Stop audio output
    if (impl_->audio_output) {
        impl_->audio_output->stop();
    }

    // 2. Signal audio decode thread to exit
    impl_->audio_restart_requested.store(true);
    impl_->audio_packet_queue.abort();
    impl_->audio_ring_not_full.notify_all();

    // 3. Join the audio decode thread
    if (impl_->audio_decode_thread.joinable()) {
        impl_->audio_decode_thread.join();
    }

    // 4. Close and tear down audio components
    if (impl_->audio_output) {
        impl_->audio_output->close();
        impl_->audio_output.reset();
    }
    impl_->audio_decoder.reset();
    impl_->audio_resampler.reset();
    impl_->mat_framer.reset();
    impl_->audio_output_mode = AudioOutputMode::PCM;
    impl_->passthrough_codec_profile = -1;
    impl_->audio_ring.reset();
    impl_->passthrough_ring_buffer.clear();
    impl_->passthrough_ring_read = 0;
    impl_->passthrough_ring_write = 0;
    impl_->passthrough_ring_size = 0;

    // 5. Re-open in the new mode
    const auto& track = impl_->media_info.tracks[impl_->active_audio_stream];
    setup_audio_output(track);

    // 6. Re-enable packet queue and start new audio decode thread
    impl_->audio_restart_requested.store(false);
    impl_->audio_packet_queue.reset();
    impl_->audio_decode_thread = std::thread([this] { impl_->audio_decode_loop(); });

    // 7. Start audio output
    if (impl_->audio_output) {
        impl_->audio_output->start();
    }

    // 8. Reset PTS to current clock position for A-V sync recovery
    int64_t now = impl_->clock.now_us();
    impl_->audio_pts_for_ring.store(now);
    impl_->passthrough_pts_for_ring = now;

    PY_LOG_INFO(TAG, "Audio pipeline restarted in %s mode",
                impl_->audio_output_mode == AudioOutputMode::Passthrough ? "passthrough" : "PCM");
}

void PlayerEngine::set_audio_passthrough(bool enabled) {
    if (impl_->passthrough_preferred == enabled) return;
    impl_->passthrough_preferred = enabled;

    // If currently playing, restart the audio pipeline in the new mode
    auto s = impl_->state.load();
    if (s == PlaybackState::Playing || s == PlaybackState::Paused) {
        restart_audio_pipeline();
    }
}

bool PlayerEngine::is_passthrough_active() const {
    return impl_->audio_output_mode == AudioOutputMode::Passthrough;
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
    {
        std::lock_guard lock(impl_->audio_ring_flush_mutex);
        if (impl_->audio_output_mode == AudioOutputMode::Passthrough) {
            // Can't tempo-filter compressed bitstreams — mute audio at non-1x
            if (impl_->audio_output) {
                impl_->audio_output->set_muted(
                    std::abs(speed - 1.0) > 0.001 || impl_->muted);
            }
        } else {
            impl_->audio_ring.reset();
        }
    }
    impl_->audio_ring_not_full.notify_one();

    PY_LOG_INFO(TAG, "Playback speed set to %.2fx", speed);
}

double PlayerEngine::playback_speed() const {
    return impl_->playback_speed.load();
}

void PlayerEngine::set_hw_decode_preference(HWDecodePreference pref) {
    impl_->hw_decode_pref = pref;
}

void PlayerEngine::set_subtitle_font_scale(double scale) {
    impl_->subtitle_manager->set_ass_font_scale(scale);
}

PlaybackStats PlayerEngine::get_playback_stats() const {
    PlaybackStats s = {};

    // Video info
    if (impl_->active_video_stream >= 0 &&
        impl_->active_video_stream < static_cast<int>(impl_->media_info.tracks.size())) {
        const auto& vt = impl_->media_info.tracks[impl_->active_video_stream];
        s.video_width = vt.width;
        s.video_height = vt.height;
        s.video_codec_id = vt.codec_id;
        snprintf(s.video_codec_name, sizeof(s.video_codec_name), "%s", vt.codec_name.c_str());
        s.video_fps = vt.frame_rate;
        s.hdr_type = static_cast<int>(vt.hdr_metadata.type);
        s.color_space = vt.color_space;
        s.transfer_func = vt.color_trc;
    }

    // Audio info
    if (impl_->active_audio_stream >= 0 &&
        impl_->active_audio_stream < static_cast<int>(impl_->media_info.tracks.size())) {
        const auto& at = impl_->media_info.tracks[impl_->active_audio_stream];
        s.audio_codec_id = at.codec_id;
        snprintf(s.audio_codec_name, sizeof(s.audio_codec_name), "%s", at.codec_name.c_str());
        s.audio_sample_rate = at.sample_rate;
        s.audio_channels = at.channels;
    }

    if (impl_->audio_output) {
        s.audio_output_channels = impl_->audio_output->channels();
    }
    s.audio_passthrough = (impl_->audio_output_mode == AudioOutputMode::Passthrough);

    if (impl_->active_audio_stream >= 0 &&
        impl_->active_audio_stream < static_cast<int>(impl_->media_info.tracks.size())) {
        const auto& at = impl_->media_info.tracks[impl_->active_audio_stream];
        s.audio_codec_profile = at.codec_profile;
        s.audio_atmos = is_atmos_stream(at.codec_id, at.codec_profile);
        s.audio_dts_hd = is_dts_hd_stream(at.codec_id, at.codec_profile);
    }

    // Hardware decode — check from presented frame
    {
        std::lock_guard lock(impl_->presented_frame_mutex);
        if (impl_->presented_frame) {
            s.hardware_decode = impl_->presented_frame->hardware_frame;
            s.video_pts_us = impl_->presented_frame->pts_us;
        }
    }

    // Frame stats
    s.frames_rendered = impl_->frames_rendered.load(std::memory_order_relaxed);
    s.frames_dropped = impl_->frames_dropped.load(std::memory_order_relaxed);

    // Queue sizes
    s.video_queue_size = static_cast<int>(impl_->video_frame_queue.size());
    s.video_packet_queue_size = static_cast<int>(impl_->video_packet_queue.size());
    s.audio_packet_queue_size = static_cast<int>(impl_->audio_packet_queue.size());

    // Audio ring buffer fill (lock-free for PCM path)
    if (impl_->audio_output_mode == AudioOutputMode::Passthrough) {
        std::unique_lock lock(impl_->audio_ring_flush_mutex, std::try_to_lock);
        if (lock.owns_lock()) {
            size_t cap = impl_->passthrough_ring_capacity;
            s.audio_ring_fill_pct = cap > 0 ? static_cast<int>(impl_->passthrough_ring_size * 100 / cap) : 0;
        }
    } else {
        size_t cap = impl_->audio_ring.capacity();
        s.audio_ring_fill_pct = cap > 0 ? static_cast<int>(impl_->audio_ring.available_read() * 100 / cap) : 0;
    }

    // Sync
    s.audio_pts_us = impl_->clock.now_us();
    s.av_drift_us = s.audio_pts_us - s.video_pts_us;

    // Container
    snprintf(s.container_format, sizeof(s.container_format), "%s",
             impl_->media_info.container_format.c_str());
    s.bitrate = impl_->media_info.bit_rate;
    s.playback_speed = impl_->playback_speed.load();

    return s;
}

VideoFrame* PlayerEngine::acquire_video_frame(int64_t target_pts_us) {
    // Use peek_fields() to read PTS/duration under lock without holding a raw
    // pointer that could be invalidated by a concurrent pop().
    auto fields = impl_->video_frame_queue.peek_fields();
    if (!fields.valid) {
        std::lock_guard lock(impl_->presented_frame_mutex);
        return impl_->presented_frame.get();
    }

    int64_t clock_us = impl_->clock.now_us();

    // When waiting for the first frame after play/seek, always accept it
    // regardless of PTS — the clock may not match the stream's start PTS.
    bool force = impl_->waiting_for_first_frame.load();

    // Pop when the frame's presentation time is within half a frame duration.
    // This adapts to the content's framerate and avoids presenting a full
    // vsync too early (which creates uneven frame cadence).
    int64_t tolerance_us = fields.duration_us > 0 ? fields.duration_us / 2 : 8000;

    if (!force && fields.pts_us > clock_us + tolerance_us) {
        std::lock_guard lock(impl_->presented_frame_mutex);
        return impl_->presented_frame.get();
    }

    std::lock_guard lock(impl_->presented_frame_mutex);

    // Lazily create the presented frame storage once
    if (!impl_->presented_frame) {
        impl_->presented_frame = std::make_unique<VideoFrame>();
    }

    // Pop directly into the existing frame (release old data via move-assign)
    if (!impl_->video_frame_queue.try_pop(*impl_->presented_frame)) {
        return impl_->presented_frame.get();
    }

    impl_->frames_rendered.fetch_add(1, std::memory_order_relaxed);

    // Video has a frame — release the audio gate and unfreeze the clock.
    // Audio and clock start together with video, ensuring A-V sync.
    if (force) {
        impl_->waiting_for_first_frame.store(false);
        impl_->clock.unfreeze();
    }

    // Skip frames that are already late (PTS behind the clock).
    // This catches up when the decoder falls behind without showing stale frames.
    VideoFrame skip_frame;
    while (true) {
        auto next = impl_->video_frame_queue.peek_fields();
        if (!next.valid || next.pts_us > clock_us) break;
        impl_->video_frame_queue.try_pop(skip_frame);
        *impl_->presented_frame = std::move(skip_frame);
        impl_->frames_dropped.fetch_add(1, std::memory_order_relaxed);
    }

    return impl_->presented_frame.get();
}

void PlayerEngine::release_video_frame(VideoFrame* frame) {
    // Frame is owned by presented_frame_, released when next frame is acquired
    (void)frame;
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

    while (running.load()) {
        // Handle seek
        if (seeking.load()) {
            demuxer->seek(seek_target_us);

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
        } else if (pkt.stream_index == active_subtitle_stream) {
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
        while (running.load()) {
            VideoFrame frame;
            Error err = video_decoder->receive_frame(frame);
            if (err.code == ErrorCode::OutputNotReady) break;
            if (err.code == ErrorCode::EndOfFile) break;
            if (err) {
                PY_LOG_WARN(TAG, "Video receive_frame error: %s", err.message.c_str());
                break;
            }

            if (skip_to_target) {
                if (frame.pts_us < seek_target_us) continue;
                skip_to_target = false;
            }

            if (!video_frame_queue.push(std::move(frame))) return false;
        }
        return true;
    };

    while (running.load()) {
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

    if (audio_output_mode == AudioOutputMode::Passthrough) {
        passthrough_write_loop();
        return;
    }

    if (!audio_decoder || !audio_output) return;

    AVCodecContext* ctx = open_audio_codec(media_info.tracks[active_audio_stream]);
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
    bool timebase_initialized = false;
    bool skip_to_target = false;
    std::vector<float> resample_buf; // reused across frames
    AudioTempoFilter tempo_filter;

    while (running.load()) {
        Packet pkt;
        if (!audio_packet_queue.pop(pkt)) break;

        // Handle speed change from the main thread
        if (speed_changed.load()) {
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

            if (audio_track_changed.load()) {
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
                const auto& new_track = media_info.tracks[new_stream];
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
                            return audio_pull(buf, frames, ch);
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
        while (running.load()) {
            int ret = avcodec_receive_frame(ctx, av_frame);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            // Lazy init resampler
            if (!resampler_initialized) {
                Error err = resampler.open(ctx, out_rate, out_channels);
                if (err) {
                    PY_LOG_ERROR(TAG, "Resampler init failed: %s", err.message.c_str());
                    break;
                }
                resampler_initialized = true;
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
                if (pts_us < seek_target_us) {
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

                size_t to_write = resample_buf.size();
                {
                    std::unique_lock lock(audio_ring_flush_mutex);
                    audio_ring_not_full.wait(lock, [&] {
                        return audio_ring.available_write() >= to_write ||
                               !running.load() || audio_restart_requested.load();
                    });
                }
                if (!running.load() || audio_restart_requested.load()) return;

                audio_ring.write(resample_buf.data(), to_write);

                int64_t chunk_duration_us = static_cast<int64_t>(num_samples) * 1000000LL / out_rate;
                audio_pts_for_ring.store(frame_pts_us + chunk_duration_us, std::memory_order_release);
            };

            // Route through tempo filter if active, otherwise direct resample
            if (tempo_filter.tempo() != 1.0) {
                tempo_filter.send_frame(av_frame);
                while (running.load()) {
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

int PlayerEngine::Impl::audio_pull(float* buffer, int frames, int channels) {
    // Hold audio silent until the first video frame is presented.
    // This prevents the clock from advancing ahead of the video pipeline.
    if (waiting_for_first_frame.load()) return 0;

    // Lock-free read from SPSC ring buffer — no mutex, no contention.
    size_t needed = static_cast<size_t>(frames * channels);
    size_t to_read = audio_ring.read(buffer, needed);

    // Signal the decode thread that space is available
    audio_ring_not_full.notify_one();

    // Update clock based on audio position
    if (to_read > 0 && audio_output && audio_output->sample_rate() > 0) {
        int64_t samples_behind = static_cast<int64_t>(audio_ring.available_read()) / channels;
        int64_t offset_us = samples_behind * 1000000LL / audio_output->sample_rate();
        clock.set_audio_pts(audio_pts_for_ring.load(std::memory_order_acquire) - offset_us);
    }

    return static_cast<int>(to_read / channels);
}

void PlayerEngine::Impl::passthrough_write_loop() {
    PY_LOG_INFO(TAG, "Audio passthrough loop started");

    if (!audio_output) return;

    while (running.load()) {
        Packet pkt;
        if (!audio_packet_queue.pop(pkt)) break;

        if (pkt.is_flush) {
            {
                std::lock_guard lock(audio_ring_flush_mutex);
                passthrough_ring_read = 0;
                passthrough_ring_write = 0;
                passthrough_ring_size = 0;
            }

            if (audio_track_changed.load()) {
                audio_track_changed.store(false);
                PY_LOG_WARN(TAG, "Track change during passthrough — exiting passthrough loop");
                break;
            }
            continue;
        }

        // Calculate PTS for this packet
        int64_t pts_us = pkt.pts_us();

        // For TrueHD, run through MAT framer for HDMI encapsulation
        const uint8_t* write_data = pkt.data.data();
        size_t write_size = pkt.data.size();
        std::vector<uint8_t> mat_buf;
        if (mat_framer) {
            auto mat_err = mat_framer->frame_packet(pkt.data.data(), pkt.data.size(), pkt.pts, mat_buf);
            if (mat_err) {
                PY_LOG_WARN(TAG, "MAT framing failed: %s", mat_err.message.c_str());
                continue;
            }
            if (mat_buf.empty()) continue;  // Muxer is still buffering
            write_data = mat_buf.data();
            write_size = mat_buf.size();
        }

        // Write compressed packet data to byte ring buffer
        {
            std::unique_lock lock(audio_ring_flush_mutex);
            size_t to_write = write_size;
            size_t capacity = passthrough_ring_buffer.size();

            if (to_write > capacity) {
                PY_LOG_WARN(TAG, "Passthrough packet too large: %zu > %zu", to_write, capacity);
                continue;
            }

            audio_ring_not_full.wait(lock, [&] {
                return passthrough_ring_size + to_write <= capacity ||
                       !running.load() || audio_restart_requested.load();
            });
            if (!running.load() || audio_restart_requested.load()) break;

            const uint8_t* src = write_data;
            size_t first_chunk = std::min(to_write, capacity - passthrough_ring_write);
            memcpy(&passthrough_ring_buffer[passthrough_ring_write], src, first_chunk);
            if (to_write > first_chunk) {
                memcpy(&passthrough_ring_buffer[0], src + first_chunk,
                       to_write - first_chunk);
            }
            passthrough_ring_write = (passthrough_ring_write + to_write) % capacity;
            passthrough_ring_size += to_write;

            // Track PTS at the end of written data
            int64_t pkt_duration_us = 0;
            if (pkt.duration > 0 && pkt.time_base_den > 0) {
                pkt_duration_us = pkt.duration * 1000000LL * pkt.time_base_num / pkt.time_base_den;
            }
            passthrough_pts_for_ring = pts_us + pkt_duration_us;
        }
    }

    PY_LOG_INFO(TAG, "Audio passthrough loop ended");
}

int PlayerEngine::Impl::bitstream_pull(uint8_t* buffer, int bytes) {
    if (waiting_for_first_frame.load()) return 0;

    std::unique_lock lock(audio_ring_flush_mutex, std::try_to_lock);
    if (!lock.owns_lock()) return 0;

    size_t available = passthrough_ring_size;
    size_t to_read = std::min(static_cast<size_t>(bytes), available);
    size_t capacity = passthrough_ring_buffer.size();

    size_t first_chunk = std::min(to_read, capacity - passthrough_ring_read);
    memcpy(buffer, &passthrough_ring_buffer[passthrough_ring_read], first_chunk);
    if (to_read > first_chunk) {
        memcpy(buffer + first_chunk, &passthrough_ring_buffer[0],
               to_read - first_chunk);
    }
    passthrough_ring_read = (passthrough_ring_read + to_read) % capacity;
    passthrough_ring_size -= to_read;

    audio_ring_not_full.notify_one();

    // Update clock from passthrough PTS
    if (to_read > 0 && passthrough_bytes_per_second > 0) {
        int64_t bytes_behind = static_cast<int64_t>(passthrough_ring_size);
        int64_t offset_us = bytes_behind * 1000000LL / passthrough_bytes_per_second;
        clock.set_audio_pts(passthrough_pts_for_ring - offset_us);
    }

    return static_cast<int>(to_read);
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
