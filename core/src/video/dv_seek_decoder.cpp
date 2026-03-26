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
    // Defer FFmpeg flush to transition_to_ff_replay() where it's actually needed.
    // Only flush FFmpeg here when VT is unavailable (FFmpeg handles skip-to-target).
    if (!vt_decoder_ && ff_decoder_) ff_decoder_->flush();

    // Lightweight clear: don't block on WaitForAsynchronousFrames.
    // Stale VT callback frames will have PTS < seek_target and get discarded
    // by the VTSeekSkip receive_frame logic.
    if (vt_decoder_) vt_decoder_->clear_frames();

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
        frame_duration_us_ = 0;
        if (vt_decoder_) {
            // Use VT for fast hardware skip-to-target
            mode_ = Mode::VTSeekSkip;
            // During seek-skip we only need PTS values, not display order.
            // Zero the reorder depth so frames emit immediately without
            // waiting for the 4-frame accumulation threshold.
            vt_decoder_->set_reorder_depth(0);
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
        } else if (mode_ == Mode::FFReplay) {
            // Don't interrupt FFReplay — it will transition to Normal
            // after draining the target frame with correct RPU.
            return;
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

        if (!pkt.is_flush) {
            // Keyframe-anchored: reset buffer on each keyframe so FFmpeg
            // replay always starts from a decodable reference point.
            if (pkt.is_keyframe) {
                replay_buffer_.clear();
            }
            replay_buffer_.push_back(pkt);
            if (replay_buffer_.size() > MAX_REPLAY_PACKETS) {
                replay_buffer_.pop_front();
            }

            // Capture frame duration for RPU margin calculation
            if (frame_duration_us_ == 0 && pkt.duration > 0 && pkt.time_base_den > 0) {
                frame_duration_us_ = pkt.duration * 1000000LL * pkt.time_base_num / pkt.time_base_den;
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
    case Mode::Normal: {
        Error err = ff_decoder_->receive_frame(out);
        if (!err && out.dovi.present) {
            last_rpu_ = out.dovi;
        }
        return err;
    }

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

            if (last_rpu_.present) {
                // Stamp cached RPU onto VT frame for instant display.
                // DV metadata changes slowly — this is visually identical
                // to the correct RPU for same-scene seeks.
                out.dovi = last_rpu_;
                PY_LOG_DEBUG(TAG, "Using cached RPU for instant display");
                transition_to_ff_replay();
                return Error::Ok();
            }

            // No cached RPU (first seek after open) — fall back to
            // waiting for FFmpeg replay to produce the target with RPU.
            transition_to_ff_replay();
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
        // Drain pre-target frames in a tight loop to avoid returning each
        // one to the decode loop (saves lock contention and queue overhead).
        while (true) {
            Error err = ff_decoder_->receive_frame(out);
            if (err) return err;

            // When approaching the target, disable pts_only and fast replay
            // so the target frame gets full fill_frame with RPU metadata.
            int64_t margin = frame_duration_us_ > 0 ? frame_duration_us_ : 50000;
            if (replay_pts_only_active_ && out.pts_us >= seek_target_us_ - margin) {
                ff_decoder_->set_pts_only_output(false);
                ff_decoder_->set_fast_replay_mode(false);
                replay_pts_only_active_ = false;
                // This frame was decoded as pts_only; discard and continue
                // so the next frame gets full RPU extraction.
                continue;
            }

            if (out.pts_us >= seek_target_us_) {
                mode_ = Mode::Normal;
                return Error::Ok();
            }

            // Pre-target pts_only frame: discard and keep draining
        }
    }
    }
    return {ErrorCode::InvalidState, "Unknown DVSeekDecoder mode"};
}

void DVSeekDecoder::transition_to_ff_replay() {
    PY_LOG_DEBUG(TAG, "Transitioning to FFmpeg replay with %zu buffered packets",
                 replay_buffer_.size());

    ff_decoder_->flush();
    ff_decoder_->set_pts_only_output(true);
    ff_decoder_->set_fast_replay_mode(true);
    replay_pts_only_active_ = true;

    for (const auto& pkt : replay_buffer_) {
        Error err = ff_decoder_->send_packet(pkt);
        if (err && err.code != ErrorCode::NeedMoreInput) {
            PY_LOG_WARN(TAG, "FFmpeg replay send_packet error: %s", err.message.c_str());
        }
    }
    replay_buffer_.clear();

    // Lightweight clear — don't block on WaitForAsynchronousFrames.
    if (vt_decoder_) vt_decoder_->clear_frames();

    mode_ = Mode::FFReplay;
}

} // namespace py
