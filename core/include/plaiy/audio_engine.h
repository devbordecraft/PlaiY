#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <functional>

namespace py {

class IAudioOutput {
public:
    virtual ~IAudioOutput() = default;

    // Configure the output for the given sample rate and channel count
    virtual Error open(int sample_rate, int channels) = 0;
    virtual void close() = 0;

    virtual void start() = 0;
    virtual void stop() = 0;

    // Reset internal position tracking (call on seek)
    virtual void reset_position() = 0;

    // Set the callback that the audio output calls to pull PCM samples.
    // The callback fills the buffer and returns the number of frames written.
    // buffer: interleaved float32, frames * channels floats
    using PullCallback = std::function<int(float* buffer, int frames, int channels)>;
    virtual void set_pull_callback(PullCallback cb) = 0;

    // Callback to report the current audio PTS for A-V sync
    using PtsCallback = std::function<void(int64_t pts_us)>;
    virtual void set_pts_callback(PtsCallback cb) = 0;

    virtual int sample_rate() const = 0;
    virtual int channels() const = 0;

    // Query the maximum channel count supported by the output device.
    // Default returns 2 (stereo) for platforms without device introspection.
    virtual int max_device_channels() const { return 2; }

    // Open in passthrough mode for compressed bitstream output.
    // Returns an error if the output device doesn't support the format.
    virtual Error open_passthrough(int codec_id, int codec_profile, int sample_rate, int channels) {
        return {ErrorCode::AudioOutputError, "Passthrough not supported"};
    }

    virtual void set_muted(bool muted) = 0;
    virtual bool is_muted() const = 0;

    virtual void set_volume(float v) = 0;
    virtual float volume() const = 0;

    virtual bool is_passthrough() const { return false; }

    // Callback for passthrough mode: pulls raw compressed bytes.
    // Returns the number of bytes written to buffer.
    using BitstreamPullCallback = std::function<int(uint8_t* buffer, int bytes)>;
    virtual void set_bitstream_pull_callback(BitstreamPullCallback cb) {}

    // Probe which passthrough codecs the current output device supports.
    struct PassthroughCapability {
        bool ac3 = false;
        bool eac3 = false;
        bool dts = false;
        bool dts_hd_ma = false;
        bool truehd = false;
    };
    virtual PassthroughCapability query_passthrough_support() const { return {}; }

    // Callback invoked when the audio output device changes (HDMI plug/unplug).
    using DeviceChangeCallback = std::function<void()>;
    virtual void set_device_change_callback(DeviceChangeCallback cb) {}

    // Spatial audio support (optional, override in spatial implementation)
    virtual void set_head_tracking_enabled(bool enabled) {}
    virtual bool is_head_tracking_enabled() const { return false; }
    virtual bool is_spatial() const { return false; }
};

} // namespace py
