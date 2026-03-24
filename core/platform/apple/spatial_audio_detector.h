#pragma once

#include <functional>

namespace py {

enum class AudioDeviceType {
    SpatialHeadphones,  // Bluetooth headphones with spatial audio support (AirPods Pro/Max, etc.)
    HDMIReceiver,       // HDMI or DisplayPort audio output
    StandardOutput,     // Built-in speakers, wired headphones, etc.
};

class SpatialAudioDetector {
public:
    // Query the current default output device type.
    static AudioDeviceType detect_current_device();

    // Returns true if the current output device supports spatial audio rendering.
    static bool is_spatial_headphones_connected();
};

} // namespace py
