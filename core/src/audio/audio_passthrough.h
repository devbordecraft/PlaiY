#pragma once

namespace py {

// Returns true if the codec_id is eligible for bitstream passthrough.
bool is_passthrough_eligible(int codec_id, int codec_profile = -1);

// Returns an approximate byte rate for the passthrough transport.
// Used to size the ring buffer and compute clock offsets.
int passthrough_bytes_per_second(int codec_id, int codec_profile = -1);

// Returns true if this codec/profile requires HDMI (not available over SPDIF).
// TrueHD, DTS-HD MA, and DTS-HD HRA all require HDMI bandwidth.
bool requires_hdmi(int codec_id, int codec_profile = -1);

// Returns true if the stream carries Dolby Atmos spatial metadata (E-AC3 JOC).
bool is_atmos_stream(int codec_id, int codec_profile);

// Returns true if the stream is DTS-HD (Master Audio or High Resolution).
bool is_dts_hd_stream(int codec_id, int codec_profile);

} // namespace py
