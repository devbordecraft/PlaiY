#pragma once

namespace py {

// Returns true if the codec_id is eligible for bitstream passthrough.
bool is_passthrough_eligible(int codec_id);

// Returns an approximate byte rate for the passthrough transport.
// Used to size the ring buffer and compute clock offsets.
int passthrough_bytes_per_second(int codec_id);

} // namespace py
