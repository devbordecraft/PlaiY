#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include "spatial_audio_detector.h"
#include "plaiy/logger.h"

static constexpr const char* TAG = "SpatialDetect";

namespace py {

static UInt32 get_default_output_transport_type() {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) return 0;

    AudioObjectPropertyAddress transport_addr = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 transport = 0;
    UInt32 tsize = sizeof(transport);
    status = AudioObjectGetPropertyData(device, &transport_addr, 0, nullptr, &tsize, &transport);
    if (status != noErr) return 0;

    return transport;
}

AudioDeviceType SpatialAudioDetector::detect_current_device() {
    UInt32 transport = get_default_output_transport_type();

    if (transport == kAudioDeviceTransportTypeHDMI ||
        transport == kAudioDeviceTransportTypeDisplayPort) {
        PY_LOG_DEBUG(TAG, "Detected HDMI/DisplayPort output");
        return AudioDeviceType::HDMIReceiver;
    }

    if (transport == kAudioDeviceTransportTypeBluetooth ||
        transport == kAudioDeviceTransportTypeBluetoothLE) {
        // Bluetooth devices that support spatial audio are typically AirPods Pro/Max
        // or Beats with the H1/H2/W1 chip. We treat all Bluetooth headphones as
        // spatial-capable — AVAudioEngine will handle the fallback gracefully if
        // the device doesn't actually support HRTF rendering.
        PY_LOG_DEBUG(TAG, "Detected Bluetooth output (spatial candidate)");
        return AudioDeviceType::SpatialHeadphones;
    }

    PY_LOG_DEBUG(TAG, "Detected standard output (transport type: %u)", transport);
    return AudioDeviceType::StandardOutput;
}

bool SpatialAudioDetector::is_spatial_headphones_connected() {
    return detect_current_device() == AudioDeviceType::SpatialHeadphones;
}

} // namespace py
