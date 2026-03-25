#include "dv_seek_decoder.h"
#include "ff_video_decoder.h"
#include "plaiy/logger.h"

#ifdef __APPLE__
#include "../../platform/apple/vt_video_decoder.h"
#endif

static constexpr const char* TAG = "DVSeekDecoder";

namespace py {

DVSeekDecoder::DVSeekDecoder() = default;
DVSeekDecoder::~DVSeekDecoder() { close(); }

Error DVSeekDecoder::open(const TrackInfo& track) {
    // Primary: FFmpeg decoder (always needed for RPU metadata)
    ff_decoder_ = std::make_unique<FFVideoDecoder>();
    Error err = ff_decoder_->open(track);
    if (err) return err;

#ifdef __APPLE__
    // Shadow: VT decoder for fast HW seek (non-fatal if it fails)
    // Create a modified track without DV flags so VT doesn't get rejected
    // by any downstream checks — we just need raw HEVC decode.
    vt_decoder_ = std::make_unique<VTVideoDecoder>();
    Error vt_err = vt_decoder_->open(track);
    if (vt_err) {
        PY_LOG_WARN(TAG, "Shadow VT decoder failed: %s — seeks will use FFmpeg skip_frame",
                    vt_err.message.c_str());
        vt_decoder_.reset();
    } else {
        PY_LOG_INFO(TAG, "Shadow VT decoder ready for fast DV seeks");
    }
#endif

    return Error::Ok();
}

void DVSeekDecoder::close() {
    mode_ = Mode::Normal;
    replay_buffer_.clear();
    if (ff_decoder_) ff_decoder_->close();
    if (vt_decoder_) vt_decoder_->close();
    ff_decoder_.reset();
    vt_decoder_.reset();
}

void DVSeekDecoder::flush() {
    if (ff_decoder_) ff_decoder_->flush();
    if (vt_decoder_) vt_decoder_->flush();
    replay_buffer_.clear();
    mode_ = Mode::Normal;
}

void DVSeekDecoder::drain() {
    if (mode_ == Mode::Normal && ff_decoder_) {
        ff_decoder_->drain();
    }
}

void DVSeekDecoder::set_seek_target(int64_t target_pts_us) {
    seek_target_us_ = target_pts_us;
}

void DVSeekDecoder::set_skip_mode(bool skip) {
    if (skip) {
        replay_buffer_.clear();
        if (vt_decoder_) {
            // Use VT for fast hardware skip-to-target
            mode_ = Mode::VTSeekSkip;
            PY_LOG_DEBUG(TAG, "Seek: VT skip mode enabled, target=%lld",
                         static_cast<long long>(seek_target_us_));
        } else {
            // No VT available — fall back to FFmpeg with AVDISCARD_NONREF
            mode_ = Mode::Normal;
            ff_decoder_->set_skip_mode(true);
        }
    } else {
        if (mode_ == Mode::Normal) {
            // Was using FFmpeg fallback path
            ff_decoder_->set_skip_mode(false);
        }
        mode_ = Mode::Normal;
    }
}

Error DVSeekDecoder::send_packet(const Packet& pkt) {
    switch (mode_) {
    case Mode::Normal:
        return ff_decoder_->send_packet(pkt);

    case Mode::VTSeekSkip: {
        // Send to VT for fast HW decode
        Error vt_err = vt_decoder_->send_packet(pkt);
        if (vt_err && vt_err.code != ErrorCode::NeedMoreInput) {
            PY_LOG_WARN(TAG, "VT send_packet error during seek: %s", vt_err.message.c_str());
            // Fall back to FFmpeg for this seek
            vt_decoder_->flush();
            mode_ = Mode::Normal;
            ff_decoder_->set_skip_mode(true);
            return ff_decoder_->send_packet(pkt);
        }

        // Buffer the packet for potential FFmpeg replay
        if (!pkt.is_flush) {
            replay_buffer_.push_back(pkt);  // copies the packet
            if (replay_buffer_.size() > REPLAY_BUFFER_SIZE) {
                replay_buffer_.pop_front();
            }
        }
        return Error::Ok();
    }

    case Mode::FFReplay:
        // During replay, new packets from demux are sent to FFmpeg directly
        return ff_decoder_->send_packet(pkt);
    }
    return {ErrorCode::InvalidState, "Unknown DVSeekDecoder mode"};
}

Error DVSeekDecoder::receive_frame(VideoFrame& out) {
    switch (mode_) {
    case Mode::Normal:
        return ff_decoder_->receive_frame(out);

    case Mode::VTSeekSkip: {
        // Drain VT frames, checking PTS
        Error err = vt_decoder_->receive_frame(out);
        if (err) {
            // OutputNotReady or other — propagate so decode loop sends more packets
            out = VideoFrame{};
            out.pts_only = true;
            return err;
        }

        // VT produced a frame — check if we've reached the target
        if (out.pts_us >= seek_target_us_) {
            PY_LOG_DEBUG(TAG, "VT found target: frame PTS=%lld >= target=%lld",
                         static_cast<long long>(out.pts_us),
                         static_cast<long long>(seek_target_us_));
            transition_to_ff_replay();

            // Drain FFmpeg replay frames to find the target
            return receive_frame(out);
        }

        // Not at target yet — return a PTS-only frame for the decode loop to skip
        int64_t pts = out.pts_us;
        out = VideoFrame{};
        out.pts_only = true;
        out.pts_us = pts;
        return Error::Ok();
    }

    case Mode::FFReplay: {
        Error err = ff_decoder_->receive_frame(out);
        if (err) return err;

        // Once we get a frame at or past the target, it has full RPU metadata.
        // Transition back to normal mode — the decode loop will push this frame.
        if (out.pts_us >= seek_target_us_) {
            mode_ = Mode::Normal;
        }
        return Error::Ok();
    }
    }
    return {ErrorCode::InvalidState, "Unknown DVSeekDecoder mode"};
}

void DVSeekDecoder::transition_to_ff_replay() {
    PY_LOG_DEBUG(TAG, "Transitioning to FFmpeg replay with %zu buffered packets",
                 replay_buffer_.size());

    // Flush FFmpeg decoder state from before the seek
    ff_decoder_->flush();

    // Replay buffered packets through FFmpeg for RPU extraction
    for (const auto& pkt : replay_buffer_) {
        Error err = ff_decoder_->send_packet(pkt);
        if (err && err.code != ErrorCode::NeedMoreInput) {
            PY_LOG_WARN(TAG, "FFmpeg replay send_packet error: %s", err.message.c_str());
        }
    }
    replay_buffer_.clear();

    // Flush the VT decoder — we're done with it for this seek
    vt_decoder_->flush();

    mode_ = Mode::FFReplay;
}

} // namespace py
