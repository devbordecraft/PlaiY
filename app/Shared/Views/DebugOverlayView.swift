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

            section("Container") {
                row("Format", cString(stats.container_format))
                if stats.bitrate > 0 {
                    row("Bitrate", String(format: "%.1f Mbps", Double(stats.bitrate) / 1_000_000.0))
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8))
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

    private func formatTime(_ us: Int64) -> String {
        TimeFormatting.debug(us)
    }
}
