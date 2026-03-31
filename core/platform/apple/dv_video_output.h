#pragma once

#include "plaiy/types.h"
#include "plaiy/error.h"
#include <atomic>
#include <memory>

namespace py {

// Dolby Vision video output using AVSampleBufferDisplayLayer.
// Receives compressed HEVC packets and feeds them to ASBDL, which handles
// DV decoding, RPU reshaping, tone mapping, and display internally.
// Used for DV Profile 5, 8, and 10; other profiles fall back to VT + Metal.
class DVVideoOutput {
public:
    DVVideoOutput();
    ~DVVideoOutput();

    // Initialize from video track info (creates CMFormatDescription with DV codec type)
    Error open(const TrackInfo& track);

    // Set the AVSampleBufferDisplayLayer (called from Swift via bridge).
    // The layer is NOT retained — caller must ensure it outlives this object.
    void set_display_layer(void* layer);

    // Submit a compressed video packet for display
    Error submit_packet(const Packet& pkt);

    // Flush the display layer (called on seek)
    void flush();

    // Set playback rate on the CMTimebase (0 = paused, 1 = normal, etc.)
    void set_rate(double rate);

    // Set current time on the CMTimebase (called on seek)
    void set_time(int64_t pts_us);

    // Check if the display layer is ready for more data
    bool is_ready() const;

    // Block until the display layer is ready or the running flag is cleared.
    // Uses requestMediaDataWhenReady for event-driven wake-up instead of polling.
    // Returns true if ready, false if stopped.
    bool wait_until_ready(const std::atomic<bool>& running);

    // Check if a display layer has been set
    bool has_display_layer() const;

    void close();

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

} // namespace py
