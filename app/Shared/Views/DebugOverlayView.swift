import SwiftUI

struct DebugOverlayView: View {
    let stats: PYPlaybackStats

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            section("Video") {
                row("Codec", "\(cString(stats.video_codec_name))\(stats.hardware_decode ? " (HW)" : " (SW)")")
                row("Resolution", "\(stats.video_width)x\(stats.video_height)")
                row("FPS", String(format: "%.3f", stats.video_fps))
                row("HDR", hdrLabel)
                row("Frames", "\(stats.frames_rendered) rendered, \(stats.frames_dropped) dropped")
                row("Frame Queue", "\(stats.video_queue_size) frames")
                row("Packet Queue", "\(stats.video_packet_queue_size) packets")
            }

            section("Audio") {
                let codecLabel = audioCodecLabel
                if stats.audio_passthrough {
                    row("Codec", "\(codecLabel) (passthrough)")
                } else {
                    row("Codec", codecLabel)
                }
                row("Sample Rate", "\(stats.audio_sample_rate) Hz")
                row("Channels", "\(stats.audio_channels) source → \(stats.audio_output_channels) output")
                if stats.audio_spatial {
                    row("Spatial", stats.audio_head_tracking ? "HRTF + Head Tracking" : "HRTF")
                }
                row("Ring Buffer", "\(stats.audio_ring_fill_pct)%")
                row("Packet Queue", "\(stats.audio_packet_queue_size) packets")
            }

            section("Sync") {
                row("A-V Drift", String(format: "%+.1f ms", Double(stats.av_drift_us) / 1000.0))
                row("Audio PTS", formatTime(stats.audio_pts_us))
                row("Video PTS", formatTime(stats.video_pts_us))
                row("Speed", String(format: "%.2gx", stats.playback_speed))
            }

            if stats.hdr_type == 4 {
                section("Dolby Vision") {
                    row("Profile", "P\(stats.dv_profile).\(stats.dv_level) (BL compat \(stats.dv_bl_compatibility_id))")
                    row("RPU", stats.dv_rpu_present ? "Active" : "None")
                    if stats.dv_rpu_present {
                        row("L1 Min", String(format: "%.1f nits", pqToNits(stats.dv_min_pq)))
                        row("L1 Max", String(format: "%.0f nits", pqToNits(stats.dv_max_pq)))
                        row("L1 Avg", String(format: "%.1f nits", pqToNits(stats.dv_avg_pq)))
                        row("Source", String(format: "%.2f–%.0f nits",
                                             pqToNits(stats.dv_source_min_pq),
                                             pqToNits(stats.dv_source_max_pq)))
                        if stats.dv_trim_slope != 0 {
                            row("L2 Trim", String(format: "S%.2f O%.2f P%.2f",
                                                  stats.dv_trim_slope,
                                                  stats.dv_trim_offset,
                                                  stats.dv_trim_power))
                            row("L2 Chroma", String(format: "W%.2f Sat%.2f",
                                                    stats.dv_trim_chroma_weight,
                                                    stats.dv_trim_saturation_gain))
                        }
                    }
                }
            }

            section("Container") {
                row("Format", cString(stats.container_format))
                if stats.bitrate > 0 {
                    row("Bitrate", String(format: "%.1f Mbps", Double(stats.bitrate) / 1_000_000.0))
                }
            }
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(.white)
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.green)
            content()
        }
        .padding(.bottom, 2)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .frame(width: 100, alignment: .leading)
                .foregroundStyle(.gray)
            Text(value)
        }
    }

    private var audioCodecLabel: String {
        let name = cString(stats.audio_codec_name)
        if stats.audio_atmos { return "E-AC3 (Atmos)" }
        if stats.audio_dts_hd { return "DTS-HD MA" }
        return name
    }

    private var hdrLabel: String {
        switch stats.hdr_type {
        case 1: return "HDR10"
        case 2: return "HDR10+"
        case 3: return "HLG"
        case 4: return "Dolby Vision"
        default: return "SDR"
        }
    }

    private func cString(_ tuple: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                                    CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar)) -> String {
        withUnsafePointer(to: tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 32) { cstr in
                String(cString: cstr)
            }
        }
    }

    private func pqToNits(_ pq: Float) -> Double {
        // ST.2084 EOTF: PQ-normalized [0,1] → nits [0, 10000]
        let p = pow(Double(pq), 1.0 / 78.84375)
        let num = max(p - 0.8359375, 0.0)
        let den = 18.8515625 - 18.6875 * p
        let linear = den > 0 ? pow(num / den, 1.0 / 0.1593017578125) : 0.0
        return linear * 10000.0
    }

    private func formatTime(_ us: Int64) -> String {
        TimeFormatting.debug(us)
    }
}
