#pragma once

#include "plaiy/video_decoder.h"
#include <deque>
#include <memory>

namespace py {

class FFVideoDecoder;
class VTVideoDecoder;

// Composite decoder for Dolby Vision Profile 8 content.
// Normal playback uses FFmpeg (preserves RPU metadata).
// During seeks, a shadow VT decoder handles the skip-to-target phase
// at hardware speed, then packets near the target are replayed through
// FFmpeg for RPU on the displayed frame.
class DVSeekDecoder : public IVideoDecoder {
public:
    DVSeekDecoder();
    ~DVSeekDecoder() override;

    Error open(const TrackInfo& track) override;
    void close() override;
    void flush() override;
    void drain() override;
    void set_skip_mode(bool skip) override;
    void set_seek_target(int64_t target_pts_us) override;
    Error send_packet(const Packet& pkt) override;
    Error receive_frame(VideoFrame& out) override;

private:
    enum class Mode {
        Normal,       // FFmpeg for RPU-aware decoding
        VTSeekSkip,   // VT for fast skip-to-target
        FFReplay,     // FFmpeg replay for RPU on target frame
    };

    Mode mode_ = Mode::Normal;
    std::unique_ptr<FFVideoDecoder> ff_decoder_;
    std::unique_ptr<VTVideoDecoder> vt_decoder_;  // nullptr if VT init fails

    // Keyframe-anchored replay buffer: cleared on each keyframe so FFmpeg
    // replay always starts from a decodable point. Sized for the largest
    // common HEVC GOP (~5s at 24fps = 120 frames).
    static constexpr size_t MAX_REPLAY_PACKETS = 128;
    std::deque<Packet> replay_buffer_;

    int64_t seek_target_us_ = 0;
    int64_t frame_duration_us_ = 0;
    bool replay_pts_only_active_ = false;

    DoviMetadata last_rpu_;  // Cached RPU from most recent Normal-mode frame

    void transition_to_ff_replay();
};

} // namespace py
