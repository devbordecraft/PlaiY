#pragma once

#include "plaiy/types.h"
#include "plaiy/audio_engine.h"
#include "plaiy/clock.h"
#include "plaiy/frame_queue.h"
#include "plaiy/packet_queue.h"
#include "plaiy/spsc_ring_buffer.h"

#include <atomic>
#include <memory>
#include <mutex>

namespace py {

// Read-only snapshot of all state needed to build PlaybackStats.
// Passed by const reference to gather_playback_stats().
struct StatsContext {
    const MediaInfo& media_info;
    int active_video_stream;
    int active_audio_stream;

    const IAudioOutput* audio_output;
    AudioOutputMode audio_output_mode;

    // Presented frame (requires mutex lock)
    std::mutex& presented_frame_mutex;
    const std::unique_ptr<VideoFrame>& presented_frame;

    const std::atomic<int>& frames_rendered;
    const std::atomic<int>& frames_dropped;

    const FrameQueue& video_frame_queue;
    const PacketQueue& video_packet_queue;
    const PacketQueue& audio_packet_queue;

    // PCM ring buffer
    const SPSCRingBuffer<float>& audio_ring;

    // Passthrough ring buffer (read under try_lock of presented_frame's mutex)
    std::mutex& audio_ring_flush_mutex;
    size_t passthrough_ring_size;
    size_t passthrough_ring_capacity;

    const Clock& clock;
    const std::atomic<double>& playback_speed;

    // DV ASBDL stats (only meaningful when is_dv_output is true)
    bool is_dv_output = false;
    int dv_packets_submitted = 0;
    int64_t dv_video_pts_us = 0;
};

PlaybackStats gather_playback_stats(const StatsContext& ctx);

} // namespace py
