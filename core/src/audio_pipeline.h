#pragma once

#include "plaiy/types.h"
#include "plaiy/audio_engine.h"
#include "plaiy/clock.h"
#include "plaiy/packet_queue.h"
#include "plaiy/spsc_ring_buffer.h"

#include "audio/audio_decoder.h"
#include "audio/mat_framer.h"

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

namespace py {

// Manages the audio output lifecycle: setup, teardown, restart,
// passthrough ring buffer, and real-time pull callbacks.
class AudioPipeline {
public:
    // Shared state owned by PlayerEngine::Impl, passed by reference.
    struct SharedState {
        SPSCRingBuffer<float>& audio_ring;
        std::mutex& audio_ring_flush_mutex;
        std::condition_variable& audio_ring_not_full;
        std::atomic<bool>& pause_requested;
        std::mutex& pause_mutex;
        std::condition_variable& pause_cv;
        std::atomic<int64_t>& audio_pts_for_ring;
        std::atomic<bool>& waiting_for_first_frame;
        Clock& clock;
        std::atomic<bool>& running;
        std::atomic<bool>& audio_restart_requested;
        PacketQueue& audio_packet_queue;
    };

    explicit AudioPipeline(SharedState shared);

    // Set up audio output for the given track. Creates audio_output, opens
    // passthrough or decode path, configures ring buffers and callbacks.
    void setup(const TrackInfo& track,
               std::unique_ptr<IAudioOutput>& audio_output,
               std::unique_ptr<AudioDecoder>& audio_decoder,
               int spatial_audio_mode,
               bool head_tracking_enabled,
               bool muted, float volume);

    // Full teardown and rebuild of the audio pipeline (for mode switches).
    // Joins the audio decode thread, tears down, rebuilds, and starts a new thread.
    void restart(const TrackInfo& track,
                 std::unique_ptr<IAudioOutput>& audio_output,
                 std::unique_ptr<AudioDecoder>& audio_decoder,
                 std::thread& audio_decode_thread,
                 std::function<void()> audio_decode_loop_fn,
                 int spatial_audio_mode,
                 bool head_tracking_enabled,
                 bool start_output,
                 bool muted, float volume);

    // Real-time audio pull callback (called from CoreAudio thread).
    int pcm_pull(float* buffer, int frames, int channels);

    // Real-time bitstream pull callback (called from CoreAudio thread).
    int bitstream_pull(uint8_t* buffer, int bytes);

    // Thread entry for passthrough mode (called from audio decode thread).
    // Returns true when end-of-stream drained normally.
    bool passthrough_write_loop();

    // Blocks decode work while paused. Returns false if playback stops or the
    // audio pipeline is being restarted.
    bool wait_if_paused();

    // Wait for the active output ring to drain. Returns false if playback stops
    // or the pipeline restarts before the ring empties.
    bool wait_for_drain();

    // Flush ring buffers during seek or speed change.
    void flush_ring(int64_t pts_us);

    // Tear down passthrough state on stop.
    void teardown();

    AudioOutputMode output_mode() const { return audio_output_mode_; }
    bool is_passthrough_preferred() const { return passthrough_preferred_; }
    void set_passthrough_preferred(bool enabled) { passthrough_preferred_ = enabled; }
    int passthrough_codec_profile() const { return passthrough_codec_profile_; }

    // Expose passthrough ring state for stats gathering
    size_t passthrough_ring_size() const { return passthrough_ring_size_; }
    size_t passthrough_ring_capacity() const { return passthrough_ring_capacity_; }

    // For direct access by audio_decode_loop (still in player_engine.cpp)
    void set_output_mode(AudioOutputMode mode) { audio_output_mode_ = mode; }

private:
    SharedState shared_;

    // Passthrough ring buffer (owned by AudioPipeline)
    std::vector<uint8_t> passthrough_ring_buffer_;
    size_t passthrough_ring_read_ = 0;
    size_t passthrough_ring_write_ = 0;
    size_t passthrough_ring_size_ = 0;
    size_t passthrough_ring_capacity_ = 0;
    int64_t passthrough_pts_for_ring_ = 0;
    int passthrough_bytes_per_second_ = 0;

    std::unique_ptr<MATFramer> mat_framer_;
    AudioOutputMode audio_output_mode_ = AudioOutputMode::PCM;
    bool passthrough_preferred_ = false;
    int passthrough_codec_profile_ = -1;

    // Reference to audio output — not owned, but needed by callbacks
    IAudioOutput* audio_output_ptr_ = nullptr;

    static constexpr int RING_SECONDS = 2;
};

} // namespace py
