#include "playback_stats.h"
#include "audio/audio_passthrough.h"

#include <cstdio>

namespace py {

PlaybackStats gather_playback_stats(const StatsContext& ctx) {
    PlaybackStats s = {};

    // Video info
    if (ctx.active_video_stream >= 0 &&
        ctx.active_video_stream < static_cast<int>(ctx.media_info.tracks.size())) {
        const auto& vt = ctx.media_info.tracks[static_cast<size_t>(ctx.active_video_stream)];
        s.video_width = vt.width;
        s.video_height = vt.height;
        s.video_codec_id = vt.codec_id;
        snprintf(s.video_codec_name, sizeof(s.video_codec_name), "%s", vt.codec_name.c_str());
        s.video_fps = vt.frame_rate;
        s.hdr_type = static_cast<int>(vt.hdr_metadata.type);
        s.color_space = vt.color_space;
        s.transfer_func = vt.color_trc;
        s.dv_profile = vt.dv_profile;
        s.dv_level = vt.dv_level;
        s.dv_bl_compatibility_id = vt.dv_bl_signal_compatibility_id;
    }

    // Audio info
    if (ctx.active_audio_stream >= 0 &&
        ctx.active_audio_stream < static_cast<int>(ctx.media_info.tracks.size())) {
        const auto& at = ctx.media_info.tracks[static_cast<size_t>(ctx.active_audio_stream)];
        s.audio_codec_id = at.codec_id;
        snprintf(s.audio_codec_name, sizeof(s.audio_codec_name), "%s", at.codec_name.c_str());
        s.audio_sample_rate = at.sample_rate;
        s.audio_channels = at.channels;
    }

    if (ctx.audio_output) {
        s.audio_output_channels = ctx.audio_output->channels();
    }
    s.audio_passthrough = (ctx.audio_output_mode == AudioOutputMode::Passthrough);
    s.audio_spatial = (ctx.audio_output_mode == AudioOutputMode::Spatial);
    if (ctx.audio_output) {
        s.audio_head_tracking = ctx.audio_output->is_head_tracking_enabled();
    }

    if (ctx.active_audio_stream >= 0 &&
        ctx.active_audio_stream < static_cast<int>(ctx.media_info.tracks.size())) {
        const auto& at = ctx.media_info.tracks[static_cast<size_t>(ctx.active_audio_stream)];
        s.audio_codec_profile = at.codec_profile;
        s.audio_atmos = is_atmos_stream(at.codec_id, at.codec_profile);
        s.audio_dts_hd = is_dts_hd_stream(at.codec_id, at.codec_profile);
    }

    // Hardware decode and per-frame metadata — check from presented frame
    {
        std::lock_guard lock(ctx.presented_frame_mutex);
        if (ctx.presented_frame) {
            s.hardware_decode = ctx.presented_frame->hardware_frame;
            s.video_pts_us = ctx.presented_frame->pts_us;

            const auto& dovi = ctx.presented_frame->dovi;
            s.dv_rpu_present = dovi.present;
            if (dovi.present) {
                s.dv_min_pq = dovi.min_pq;
                s.dv_max_pq = dovi.max_pq;
                s.dv_avg_pq = dovi.avg_pq;
                s.dv_source_min_pq = dovi.source_min_pq;
                s.dv_source_max_pq = dovi.source_max_pq;
                s.dv_trim_slope = dovi.trim_slope;
                s.dv_trim_offset = dovi.trim_offset;
                s.dv_trim_power = dovi.trim_power;
                s.dv_trim_chroma_weight = dovi.trim_chroma_weight;
                s.dv_trim_saturation_gain = dovi.trim_saturation_gain;
            }
        }
    }

    // Frame stats
    s.frames_rendered = ctx.frames_rendered.load(std::memory_order_relaxed);
    s.frames_dropped = ctx.frames_dropped.load(std::memory_order_relaxed);

    // Queue sizes
    s.video_queue_size = static_cast<int>(ctx.video_frame_queue.size());
    s.video_packet_queue_size = static_cast<int>(ctx.video_packet_queue.size());
    s.audio_packet_queue_size = static_cast<int>(ctx.audio_packet_queue.size());

    // Audio ring buffer fill (lock-free for PCM path)
    if (ctx.audio_output_mode == AudioOutputMode::Passthrough) {
        std::unique_lock lock(ctx.audio_ring_flush_mutex, std::try_to_lock);
        if (lock.owns_lock()) {
            size_t cap = ctx.passthrough_ring_capacity;
            s.audio_ring_fill_pct = cap > 0 ? static_cast<int>(ctx.passthrough_ring_size * 100 / cap) : 0;
        }
    } else {
        size_t cap = ctx.audio_ring.capacity();
        s.audio_ring_fill_pct = cap > 0 ? static_cast<int>(ctx.audio_ring.available_read() * 100 / cap) : 0;
    }

    // Sync
    s.audio_pts_us = ctx.clock.now_us();
    s.av_drift_us = s.audio_pts_us - s.video_pts_us;

    // Container
    snprintf(s.container_format, sizeof(s.container_format), "%s",
             ctx.media_info.container_format.c_str());
    s.bitrate = ctx.media_info.bit_rate;
    s.playback_speed = ctx.playback_speed.load();

    return s;
}

} // namespace py
