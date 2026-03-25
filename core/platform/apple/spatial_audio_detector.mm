#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include "spatial_audio_detector.h"
#include "plaiy/logger.h"

static constexpr const char* TAG = "SpatialDetect";

namespace py {

struct DefaultOutputInfo {
    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 transport = 0;
};

static DefaultOutputInfo get_default_output_info() {
    DefaultOutputInfo info;
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = sizeof(info.device);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size, &info.device);
    if (status != noErr || info.device == kAudioObjectUnknown) return info;

    AudioObjectPropertyAddress transport_addr = {
        kAudioDevicePropertyTransportType,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 tsize = sizeof(info.transport);
    AudioObjectGetPropertyData(info.device, &transport_addr, 0, nullptr, &tsize, &info.transport);

    return info;
}

AudioDeviceType SpatialAudioDetector::detect_current_device() {
    auto info = get_default_output_info();

    if (info.transport == kAudioDeviceTransportTypeHDMI ||
        info.transport == kAudioDeviceTransportTypeDisplayPort) {
        PY_LOG_DEBUG(TAG, "Detected HDMI/DisplayPort output");
        return AudioDeviceType::HDMIReceiver;
    }

    if (info.transport == kAudioDeviceTransportTypeBluetooth ||
        info.transport == kAudioDeviceTransportTypeBluetoothLE) {
        // Log a warning for non-AirPods/Beats Bluetooth devices that may not
        // support HRTF rendering. AVAudioEngine handles fallback gracefully.
        AudioObjectPropertyAddress name_addr = {
            kAudioObjectPropertyName,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        CFStringRef device_name = nullptr;
        UInt32 name_size = sizeof(device_name);
        if (AudioObjectGetPropertyData(info.device, &name_addr, 0, nullptr,
                                       &name_size, &device_name) == noErr && device_name) {
            NSString* name = (__bridge NSString*)device_name;
            if (![name containsString:@"AirPods"] && ![name containsString:@"Beats"]) {
                PY_LOG_WARN(TAG, "Bluetooth device '%s' may not support spatial audio",
                            [name UTF8String]);
            }
            CFRelease(device_name);
        }

        PY_LOG_DEBUG(TAG, "Detected Bluetooth output (spatial candidate)");
        return AudioDeviceType::SpatialHeadphones;
    }

    PY_LOG_DEBUG(TAG, "Detected standard output (transport type: %u)", info.transport);
    return AudioDeviceType::StandardOutput;
}

bool SpatialAudioDetector::is_spatial_headphones_connected() {
    return detect_current_device() == AudioDeviceType::SpatialHeadphones;
}

} // namespace py
