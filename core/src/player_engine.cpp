#include "plaiy/player_engine.h"
#include "plaiy/clock.h"
#include "plaiy/frame_queue.h"
#include "plaiy/logger.h"
#include "plaiy/packet_queue.h"
#include "plaiy/subtitle_manager.h"

#include "demuxer/ff_demuxer.h"
#include "video/video_decoder_factory.h"
#include "audio/audio_decoder.h"
#include "audio/audio_resampler.h"

#ifdef __APPLE__
#include "../platform/apple/ca_audio_output.h"
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

#include <atomic>
#include <condition_variable>
#include <mutex>
#include <thread>
#include <vector>

static constexpr const char* TAG = "PlayerEngine";

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
    PacketQueue video_packet_queue{128};
    PacketQueue audio_packet_queue{128};
    FrameQueue video_frame_queue{5};

    // Audio ring buffer for the pull callback
    std::mutex audio_buf_mutex;
    std::condition_variable audio_buf_not_full;
    std::vector<float> audio_ring_buffer;
    size_t audio_ring_read = 0;
    size_t audio_ring_write = 0;
    size_t audio_ring_size = 0;
    static constexpr size_t AUDIO_RING_CAPACITY = 48000 * 2 * 4; // ~4 seconds stereo

    int64_t audio_pts_for_ring = 0; // PTS of the audio at ring write position

    // Track indices
    int active_video_stream = -1;
    int active_audio_stream = -1;
    int active_subtitle_stream = -1;

    // For seek
    std::atomic<bool> seeking{false};
    int64_t seek_target_us = 0;

    // For audio track switching
    std::atomic<bool> audio_track_changed{false};
    int pending_audio_stream = -1; // protected by audio_buf_mutex

    // Threads
    std::thread demux_thread;
    std::thread video_decode_thread;
    std::thread audio_decode_thread;
    std::atomic<bool> running{false};

    // Currently presented frame
    std::mutex presented_frame_mutex;
    std::unique_ptr<VideoFrame> presented_frame;

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
    void stop_threads();
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
        impl_->video_decoder = VideoDecoderFactory::create(track);
        if (!impl_->video_decoder) {
            return {ErrorCode::DecoderInitFailed, "No video decoder available"};
        }
        impl_->subtitle_manager->set_video_size(track.width, track.height);
    }

    // Open audio decoder + resampler + output
    if (impl_->active_audio_stream >= 0) {
        const auto& track = impl_->media_info.tracks[impl_->active_audio_stream];

        impl_->audio_decoder = std::make_unique<AudioDecoder>();
        err = impl_->audio_decoder->open(track);
        if (err) {
            PY_LOG_WARN(TAG, "Audio decoder open failed: %s", err.message.c_str());
            impl_->audio_decoder.reset();
        } else {
            // Create audio output
#ifdef __APPLE__
            impl_->audio_output = std::make_unique<CAAudioOutput>();
#endif
            if (impl_->audio_output) {
                int out_rate = impl_->audio_decoder->sample_rate();
                int out_channels = std::min(impl_->audio_decoder->channels(), 2); // Stereo for Phase 1

                err = impl_->audio_output->open(out_rate, out_channels);
                if (err) {
                    PY_LOG_WARN(TAG, "Audio output open failed: %s", err.message.c_str());
                    impl_->audio_output.reset();
                } else {
                    // Set up ring buffer
                    impl_->audio_ring_buffer.resize(Impl::AUDIO_RING_CAPACITY);
                    impl_->audio_ring_read = 0;
                    impl_->audio_ring_write = 0;
                    impl_->audio_ring_size = 0;

                    // Audio pull callback
                    impl_->audio_output->set_pull_callback(
                        [this](float* buf, int frames, int ch) {
                            return impl_->audio_pull(buf, frames, ch);
                        });

                    // PTS callback for clock sync
                    impl_->audio_output->set_pts_callback(
                        [this](int64_t pts_us) {
                            // The audio output reports its playback position
                            // We offset by the PTS of the audio data being played
                            // This is approximate; we use the ring buffer's PTS tracking
                        });
                }
            }
        }
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

    // Flush queues
    impl_->video_packet_queue.flush();
    impl_->audio_packet_queue.flush();
    impl_->video_frame_queue.flush();

    // Flush ring buffer and wake decode thread
    {
        std::lock_guard lock(impl_->audio_buf_mutex);
        impl_->audio_ring_read = 0;
        impl_->audio_ring_write = 0;
        impl_->audio_ring_size = 0;
    }
    impl_->audio_buf_not_full.notify_one();

    impl_->subtitle_manager->flush();
}

void PlayerEngine::stop() {
    impl_->stop_threads();
    impl_->clock.reset();

    if (impl_->audio_output) {
        impl_->audio_output->stop();
        impl_->audio_output->close();
        impl_->audio_output.reset();
    }

    impl_->video_decoder.reset();
    impl_->audio_decoder.reset();
    impl_->audio_resampler.reset();
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

    {
        std::lock_guard lock(impl_->audio_buf_mutex);
        impl_->pending_audio_stream = stream_index;
    }
    impl_->active_audio_stream = stream_index;
    impl_->audio_track_changed.store(true);

    // Flush queued packets and signal the decode thread
    impl_->audio_packet_queue.flush();
    Packet flush_pkt;
    flush_pkt.is_flush = true;
    impl_->audio_packet_queue.push(flush_pkt);

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

VideoFrame* PlayerEngine::acquire_video_frame(int64_t target_pts_us) {
    VideoFrame* front = impl_->video_frame_queue.peek();
    if (!front) {
        std::lock_guard lock(impl_->presented_frame_mutex);
        return impl_->presented_frame.get();
    }

    int64_t clock_us = impl_->clock.now_us();
    int64_t threshold_us = 40000; // 40ms tolerance

    if (front->pts_us > clock_us + threshold_us) {
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

    // Skip late frames
    VideoFrame skip_frame;
    while (true) {
        VideoFrame* next = impl_->video_frame_queue.peek();
        if (!next || next->pts_us > clock_us + threshold_us) break;
        impl_->video_frame_queue.try_pop(skip_frame);
        *impl_->presented_frame = std::move(skip_frame);
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
            // Send EOF flush packets
            Packet eof_pkt;
            eof_pkt.is_flush = true;
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

    while (running.load()) {
        Packet pkt;
        if (!video_packet_queue.pop(pkt)) break;

        if (pkt.is_flush) {
            video_decoder->flush();
            video_frame_queue.flush();
            continue;
        }

        Error err = video_decoder->send_packet(pkt);
        if (err && err.code != ErrorCode::NeedMoreInput) {
            PY_LOG_WARN(TAG, "Video send_packet error: %s", err.message.c_str());
            continue;
        }

        // Drain all available frames
        while (running.load()) {
            VideoFrame frame;
            err = video_decoder->receive_frame(frame);
            if (err.code == ErrorCode::OutputNotReady) break;
            if (err.code == ErrorCode::EndOfFile) break;
            if (err) {
                PY_LOG_WARN(TAG, "Video receive_frame error: %s", err.message.c_str());
                break;
            }
            if (!video_frame_queue.push(std::move(frame))) break;
        }
    }

    PY_LOG_INFO(TAG, "Video decode thread ended");
}

void PlayerEngine::Impl::audio_decode_loop() {
    PY_LOG_INFO(TAG, "Audio decode thread started");

    if (!audio_decoder || !audio_output) return;

    // We need the AVCodecContext for the resampler — but our AudioDecoder
    // hides it. We'll create a resampler-compatible path.
    // For a cleaner design, we integrate decoding + resampling here directly.

    // Re-open codec for this thread to get the AVCodecContext
    // Actually, let's use FFmpeg directly here for the audio decode+resample pipeline
    const AVCodec* codec = avcodec_find_decoder(
        static_cast<AVCodecID>(media_info.tracks[active_audio_stream].codec_id));
    if (!codec) return;

    AVCodecContext* ctx = avcodec_alloc_context3(codec);
    if (!ctx) return;

    const auto& track = media_info.tracks[active_audio_stream];
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
        return;
    }

    // Set up resampler
    AudioResampler resampler;
    int out_rate = audio_output->sample_rate();
    int out_channels = audio_output->channels();
    // We'll init the resampler after first frame decode when we know the actual format

    AVFrame* av_frame = av_frame_alloc();
    AVPacket* av_pkt = av_packet_alloc();
    bool resampler_initialized = false;
    bool timebase_initialized = false;
    std::vector<float> resample_buf; // reused across frames

    while (running.load()) {
        Packet pkt;
        if (!audio_packet_queue.pop(pkt)) break;

        if (pkt.is_flush) {
            {
                std::lock_guard lock(audio_buf_mutex);
                audio_ring_read = 0;
                audio_ring_write = 0;
                audio_ring_size = 0;
            }

            if (audio_track_changed.load()) {
                audio_track_changed.store(false);

                int new_stream;
                {
                    std::lock_guard lock(audio_buf_mutex);
                    new_stream = pending_audio_stream;
                }

                // Close old decoder
                avcodec_free_context(&ctx);
                resampler.close();
                resampler_initialized = false;
                timebase_initialized = false;

                // Open new decoder
                const auto& new_track = media_info.tracks[new_stream];
                const AVCodec* new_codec = avcodec_find_decoder(
                    static_cast<AVCodecID>(new_track.codec_id));
                if (!new_codec) {
                    PY_LOG_ERROR(TAG, "No decoder for new audio track");
                    break;
                }

                ctx = avcodec_alloc_context3(new_codec);
                if (!ctx) break;

                ctx->sample_rate = new_track.sample_rate;
                av_channel_layout_default(&ctx->ch_layout, new_track.channels);

                if (!new_track.extradata.empty()) {
                    ctx->extradata_size = static_cast<int>(new_track.extradata.size());
                    ctx->extradata = static_cast<uint8_t*>(
                        av_mallocz(new_track.extradata.size() + AV_INPUT_BUFFER_PADDING_SIZE));
                    memcpy(ctx->extradata, new_track.extradata.data(), new_track.extradata.size());
                }

                if (avcodec_open2(ctx, new_codec, nullptr) < 0) {
                    PY_LOG_ERROR(TAG, "Failed to open new audio decoder");
                    avcodec_free_context(&ctx);
                    break;
                }

                PY_LOG_INFO(TAG, "Audio decoder switched to stream %d (%s)",
                            new_stream, new_track.codec_name.c_str());
            } else {
                avcodec_flush_buffers(ctx);
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

        int ret = avcodec_send_packet(ctx, av_pkt);
        if (ret < 0 && ret != AVERROR(EAGAIN)) continue;

        while (running.load()) {
            ret = avcodec_receive_frame(ctx, av_frame);
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
            }

            // Resample to float32 interleaved (reuse buffer)
            int num_samples = 0;
            Error err = resampler.convert(av_frame, resample_buf, num_samples);
            if (err) continue;

            // Calculate PTS for this audio chunk
            int64_t pts_us = 0;
            if (av_frame->pts != AV_NOPTS_VALUE && ctx->pkt_timebase.den > 0) {
                pts_us = av_rescale_q(av_frame->pts, ctx->pkt_timebase, {1, 1000000});
            }

            // Write to ring buffer with proper condition variable wait
            {
                std::unique_lock lock(audio_buf_mutex);
                size_t to_write = resample_buf.size();
                size_t capacity = audio_ring_buffer.size();

                audio_buf_not_full.wait(lock, [&] {
                    return audio_ring_size + to_write <= capacity || !running.load();
                });
                if (!running.load()) break;

                // Bulk memcpy into ring buffer (up to 2 segments for wrap-around)
                const float* src = resample_buf.data();
                size_t first_chunk = std::min(to_write, capacity - audio_ring_write);
                memcpy(&audio_ring_buffer[audio_ring_write], src, first_chunk * sizeof(float));
                if (to_write > first_chunk) {
                    memcpy(&audio_ring_buffer[0], src + first_chunk,
                           (to_write - first_chunk) * sizeof(float));
                }
                audio_ring_write = (audio_ring_write + to_write) % capacity;
                audio_ring_size += to_write;
                audio_pts_for_ring = pts_us;
            }

            av_frame_unref(av_frame);
        }
    }

    av_frame_free(&av_frame);
    av_packet_free(&av_pkt);
    resampler.close();
    avcodec_free_context(&ctx);

    PY_LOG_INFO(TAG, "Audio decode thread ended");
}

int PlayerEngine::Impl::audio_pull(float* buffer, int frames, int channels) {
    std::lock_guard lock(audio_buf_mutex);
    size_t needed = static_cast<size_t>(frames * channels);
    size_t available = audio_ring_size;
    size_t to_read = std::min(needed, available);
    size_t capacity = audio_ring_buffer.size();

    // Bulk memcpy from ring buffer (up to 2 segments for wrap-around)
    size_t first_chunk = std::min(to_read, capacity - audio_ring_read);
    memcpy(buffer, &audio_ring_buffer[audio_ring_read], first_chunk * sizeof(float));
    if (to_read > first_chunk) {
        memcpy(buffer + first_chunk, &audio_ring_buffer[0],
               (to_read - first_chunk) * sizeof(float));
    }
    audio_ring_read = (audio_ring_read + to_read) % capacity;
    audio_ring_size -= to_read;

    // Signal the decode thread that space is available
    audio_buf_not_full.notify_one();

    // Update clock based on audio position
    if (to_read > 0 && audio_output && audio_output->sample_rate() > 0) {
        int64_t samples_behind = static_cast<int64_t>(audio_ring_size) / channels;
        int64_t offset_us = samples_behind * 1000000LL / audio_output->sample_rate();
        clock.set_audio_pts(audio_pts_for_ring - offset_us);
    }

    return static_cast<int>(to_read / channels);
}

void PlayerEngine::Impl::stop_threads() {
    running.store(false);
    video_packet_queue.abort();
    audio_packet_queue.abort();
    video_frame_queue.abort();

    if (demux_thread.joinable()) demux_thread.join();
    if (video_decode_thread.joinable()) video_decode_thread.join();
    if (audio_decode_thread.joinable()) audio_decode_thread.join();
}

} // namespace py
