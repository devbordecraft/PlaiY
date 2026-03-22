#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

#include "ca_audio_output.h"
#include "plaiy/logger.h"

#include <mutex>
#include <vector>

extern "C" {
#include <libavcodec/avcodec.h>
}

static constexpr const char* TAG = "CAAudioOutput";

namespace py {

struct CAAudioOutput::Impl {
    AudioComponentInstance audio_unit = nullptr;
    int sample_rate = 0;
    int channels = 0;
    bool running = false;
    bool passthrough_mode = false;
    int passthrough_codec_id = 0;

    std::mutex callback_mutex;
    IAudioOutput::PullCallback pull_callback;
    IAudioOutput::PtsCallback pts_callback;
    IAudioOutput::BitstreamPullCallback bitstream_pull_callback;

    int64_t samples_played = 0;

    // For HDMI passthrough: the device and stream we configured
    AudioDeviceID hdmi_device = kAudioObjectUnknown;
    AudioStreamID hdmi_stream = kAudioObjectUnknown;
    AudioStreamBasicDescription hdmi_original_format = {};

    static OSStatus renderCallback(
        void* inRefCon,
        AudioUnitRenderActionFlags* ioActionFlags,
        const AudioTimeStamp* inTimeStamp,
        UInt32 inBusNumber,
        UInt32 inNumberFrames,
        AudioBufferList* ioData);

    static OSStatus passthroughRenderCallback(
        void* inRefCon,
        AudioUnitRenderActionFlags* ioActionFlags,
        const AudioTimeStamp* inTimeStamp,
        UInt32 inBusNumber,
        UInt32 inNumberFrames,
        AudioBufferList* ioData);
};

CAAudioOutput::CAAudioOutput() : impl_(std::make_unique<Impl>()) {}

CAAudioOutput::~CAAudioOutput() {
    close();
}

// ---- Device channel query ----

int CAAudioOutput::max_device_channels() const {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    AudioDeviceID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size, &device);
    if (status != noErr || device == kAudioObjectUnknown) return 2;

    addr.mSelector = kAudioDevicePropertyStreamConfiguration;
    addr.mScope = kAudioDevicePropertyScopeOutput;

    UInt32 buf_size = 0;
    status = AudioObjectGetPropertyDataSize(device, &addr, 0, nullptr, &buf_size);
    if (status != noErr || buf_size == 0) return 2;

    std::vector<uint8_t> buf(buf_size);
    auto* abl = reinterpret_cast<AudioBufferList*>(buf.data());
    status = AudioObjectGetPropertyData(device, &addr, 0, nullptr, &buf_size, abl);
    if (status != noErr) return 2;

    int total = 0;
    for (UInt32 i = 0; i < abl->mNumberBuffers; i++) {
        total += static_cast<int>(abl->mBuffers[i].mNumberChannels);
    }

    // Cap at 8 (7.1) to avoid exotic configurations
    int result = std::min(std::max(total, 2), 8);
    PY_LOG_INFO(TAG, "Default output device max channels: %d", result);
    return result;
}

// ---- Channel layout helper ----

static AudioChannelLayoutTag channel_layout_tag(int channels) {
    switch (channels) {
        case 1: return kAudioChannelLayoutTag_Mono;
        case 2: return kAudioChannelLayoutTag_Stereo;
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1;
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1;
        default: return kAudioChannelLayoutTag_DiscreteInOrder | static_cast<UInt32>(channels);
    }
}

// ---- PCM open ----

Error CAAudioOutput::open(int sample_rate, int channels) {
    close();
    impl_->sample_rate = sample_rate;
    impl_->channels = channels;
    impl_->passthrough_mode = false;

    // Find the default output audio component
    AudioComponentDescription desc = {};
    desc.componentType = kAudioUnitType_Output;
#if TARGET_OS_OSX
    desc.componentSubType = kAudioUnitSubType_DefaultOutput;
#else
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
#endif
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;

    AudioComponent component = AudioComponentFindNext(nullptr, &desc);
    if (!component) {
        return {ErrorCode::AudioOutputError, "No audio output component found"};
    }

    OSStatus status = AudioComponentInstanceNew(component, &impl_->audio_unit);
    if (status != noErr) {
        return {ErrorCode::AudioOutputError, "Failed to create audio unit: " + std::to_string(status)};
    }

    // Set the stream format: interleaved float32
    AudioStreamBasicDescription format = {};
    format.mSampleRate = sample_rate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    format.mBitsPerChannel = 32;
    format.mChannelsPerFrame = static_cast<UInt32>(channels);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = format.mChannelsPerFrame * sizeof(float);
    format.mBytesPerPacket = format.mBytesPerFrame;

    status = AudioUnitSetProperty(impl_->audio_unit,
        kAudioUnitProperty_StreamFormat,
        kAudioUnitScope_Input,
        0, // output bus
        &format, sizeof(format));

    if (status != noErr) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to set audio format: " + std::to_string(status)};
    }

    // Set channel layout for multichannel output
    if (channels > 2) {
        AudioChannelLayout layout = {};
        layout.mChannelLayoutTag = channel_layout_tag(channels);
        layout.mChannelBitmap = 0;
        layout.mNumberChannelDescriptions = 0;

        status = AudioUnitSetProperty(impl_->audio_unit,
            kAudioUnitProperty_AudioChannelLayout,
            kAudioUnitScope_Input,
            0,
            &layout, sizeof(layout));
        if (status != noErr) {
            PY_LOG_WARN(TAG, "Failed to set channel layout (status %d), continuing anyway", (int)status);
        }
    }

    // Set the render callback
    AURenderCallbackStruct callback;
    callback.inputProc = Impl::renderCallback;
    callback.inputProcRefCon = impl_.get();

    status = AudioUnitSetProperty(impl_->audio_unit,
        kAudioUnitProperty_SetRenderCallback,
        kAudioUnitScope_Input,
        0,
        &callback, sizeof(callback));

    if (status != noErr) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to set render callback"};
    }

    status = AudioUnitInitialize(impl_->audio_unit);
    if (status != noErr) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to initialize audio unit"};
    }

    PY_LOG_INFO(TAG, "Audio output opened: %d Hz, %d channels", sample_rate, channels);
    return Error::Ok();
}

// ---- Passthrough open ----

#if TARGET_OS_OSX

static bool find_hdmi_device(AudioDeviceID& out_device) {
    AudioObjectPropertyAddress addr = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    OSStatus status = AudioObjectGetPropertyDataSize(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size);
    if (status != noErr || size == 0) return false;

    int count = static_cast<int>(size / sizeof(AudioDeviceID));
    std::vector<AudioDeviceID> devices(count);
    status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject, &addr, 0, nullptr, &size, devices.data());
    if (status != noErr) return false;

    for (auto dev : devices) {
        AudioObjectPropertyAddress transport_addr = {
            kAudioDevicePropertyTransportType,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 transport = 0;
        UInt32 tsize = sizeof(transport);
        if (AudioObjectGetPropertyData(dev, &transport_addr, 0, nullptr, &tsize, &transport) == noErr) {
            if (transport == kAudioDeviceTransportTypeHDMI ||
                transport == kAudioDeviceTransportTypeDisplayPort) {
                out_device = dev;
                return true;
            }
        }
    }
    return false;
}

static bool find_hdmi_stream_format(AudioDeviceID device, int codec_id,
                                     AudioStreamID& out_stream,
                                     AudioStreamBasicDescription& out_format,
                                     AudioStreamBasicDescription& out_original) {
    AudioObjectPropertyAddress addr = {
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyScopeOutput,
        kAudioObjectPropertyElementMain
    };

    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(device, &addr, 0, nullptr, &size) != noErr || size == 0)
        return false;

    int count = static_cast<int>(size / sizeof(AudioStreamID));
    std::vector<AudioStreamID> streams(count);
    if (AudioObjectGetPropertyData(device, &addr, 0, nullptr, &size, streams.data()) != noErr)
        return false;

    // Determine which format IDs to look for
    UInt32 target_format_id = 0;
    if (codec_id == AV_CODEC_ID_TRUEHD) {
        target_format_id = kAudioFormatMPEGLayer3; // Placeholder — see note below
    } else if (codec_id == AV_CODEC_ID_DTS) {
        target_format_id = 'dtsh'; // DTS-HD
    }

    for (auto stream : streams) {
        // Save current physical format for restoration later
        AudioObjectPropertyAddress phys_addr = {
            kAudioStreamPropertyPhysicalFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 fsize = sizeof(out_original);
        AudioObjectGetPropertyData(stream, &phys_addr, 0, nullptr, &fsize, &out_original);

        // Get available physical formats
        AudioObjectPropertyAddress avail_addr = {
            kAudioStreamPropertyAvailablePhysicalFormats,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        UInt32 avail_size = 0;
        if (AudioObjectGetPropertyDataSize(stream, &avail_addr, 0, nullptr, &avail_size) != noErr)
            continue;

        int fmt_count = static_cast<int>(avail_size / sizeof(AudioStreamRangedDescription));
        std::vector<AudioStreamRangedDescription> formats(fmt_count);
        if (AudioObjectGetPropertyData(stream, &avail_addr, 0, nullptr, &avail_size, formats.data()) != noErr)
            continue;

        for (auto& ranged : formats) {
            auto& fmt = ranged.mFormat;
            // Look for encoded digital audio formats
            bool match = false;
            if (codec_id == AV_CODEC_ID_TRUEHD) {
                // TrueHD: look for 'mlp ' or any encoded AC3 variant on HDMI that supports high bitrate
                match = (fmt.mFormatID == 'truE' || fmt.mFormatID == 'mlp ' ||
                         fmt.mFormatID == kAudioFormatEnhancedAC3);
            } else if (codec_id == AV_CODEC_ID_DTS) {
                // DTS-HD: look for DTS formats on HDMI
                match = (fmt.mFormatID == 'dtsh' || fmt.mFormatID == 'DTS ' ||
                         fmt.mFormatID == kAudioFormat60958AC3);
            }
            if (match) {
                out_stream = stream;
                out_format = fmt;
                return true;
            }
        }
    }
    return false;
}

#endif // TARGET_OS_OSX

Error CAAudioOutput::open_passthrough(int codec_id, int sample_rate, int channels) {
    close();
    impl_->passthrough_mode = true;
    impl_->passthrough_codec_id = codec_id;
    impl_->sample_rate = sample_rate;
    impl_->channels = 2; // SPDIF transport is always 2ch

#if !TARGET_OS_OSX
    return {ErrorCode::AudioOutputError, "Passthrough not supported on this platform"};
#else

    bool is_spdif = (codec_id == AV_CODEC_ID_AC3 ||
                     codec_id == AV_CODEC_ID_EAC3 ||
                     codec_id == AV_CODEC_ID_DTS);
    bool is_hdmi_only = (codec_id == AV_CODEC_ID_TRUEHD);

    // For SPDIF-compatible codecs, try the default output device
    if (is_spdif) {
        AudioComponentDescription desc = {};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_DefaultOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent component = AudioComponentFindNext(nullptr, &desc);
        if (!component) {
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "No audio output component"};
        }

        OSStatus status = AudioComponentInstanceNew(component, &impl_->audio_unit);
        if (status != noErr) {
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to create audio unit"};
        }

        AudioStreamBasicDescription format = {};
        format.mSampleRate = 48000;
        format.mChannelsPerFrame = 2;

        if (codec_id == AV_CODEC_ID_AC3) {
            format.mFormatID = kAudioFormatAC3;
            format.mFramesPerPacket = 1536;
            format.mBytesPerFrame = 0;
            format.mBytesPerPacket = 0; // Variable
            format.mBitsPerChannel = 0;
        } else if (codec_id == AV_CODEC_ID_EAC3) {
            format.mFormatID = kAudioFormatEnhancedAC3;
            format.mFramesPerPacket = 6144;
            format.mBytesPerFrame = 0;
            format.mBytesPerPacket = 0;
            format.mBitsPerChannel = 0;
        } else if (codec_id == AV_CODEC_ID_DTS) {
            format.mFormatID = 'DTS ';
            format.mFramesPerPacket = 512;
            format.mBytesPerFrame = 0;
            format.mBytesPerPacket = 0;
            format.mBitsPerChannel = 0;
        }

        status = AudioUnitSetProperty(impl_->audio_unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &format, sizeof(format));

        if (status != noErr) {
            PY_LOG_WARN(TAG, "Device doesn't support passthrough format (status %d)", (int)status);
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Device doesn't support passthrough for this codec"};
        }

        AURenderCallbackStruct callback;
        callback.inputProc = Impl::passthroughRenderCallback;
        callback.inputProcRefCon = impl_.get();

        status = AudioUnitSetProperty(impl_->audio_unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &callback, sizeof(callback));

        if (status != noErr) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to set passthrough callback"};
        }

        status = AudioUnitInitialize(impl_->audio_unit);
        if (status != noErr) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to initialize passthrough audio unit"};
        }

        PY_LOG_INFO(TAG, "Passthrough opened (SPDIF): codec_id=%d, 48000 Hz", codec_id);
        return Error::Ok();
    }

    // For HDMI-only codecs (TrueHD, DTS-HD), need HAL-level access
    if (is_hdmi_only) {
        AudioDeviceID hdmi_device = kAudioObjectUnknown;
        if (!find_hdmi_device(hdmi_device)) {
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "No HDMI audio device found for TrueHD passthrough"};
        }

        AudioStreamID stream = kAudioObjectUnknown;
        AudioStreamBasicDescription target_format = {};
        AudioStreamBasicDescription original_format = {};

        if (!find_hdmi_stream_format(hdmi_device, codec_id, stream, target_format, original_format)) {
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "HDMI device doesn't support TrueHD/DTS-HD format"};
        }

        // Set the physical format on the HDMI stream
        AudioObjectPropertyAddress phys_addr = {
            kAudioStreamPropertyPhysicalFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        OSStatus status = AudioObjectSetPropertyData(
            stream, &phys_addr, 0, nullptr, sizeof(target_format), &target_format);
        if (status != noErr) {
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to set HDMI stream format"};
        }

        impl_->hdmi_device = hdmi_device;
        impl_->hdmi_stream = stream;
        impl_->hdmi_original_format = original_format;

        // Create HAL output unit targeting the HDMI device
        AudioComponentDescription desc = {};
        desc.componentType = kAudioUnitType_Output;
        desc.componentSubType = kAudioUnitSubType_HALOutput;
        desc.componentManufacturer = kAudioUnitManufacturer_Apple;

        AudioComponent component = AudioComponentFindNext(nullptr, &desc);
        if (!component) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "No HAL output component"};
        }

        status = AudioComponentInstanceNew(component, &impl_->audio_unit);
        if (status != noErr) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to create HAL audio unit"};
        }

        // Target the HDMI device
        status = AudioUnitSetProperty(impl_->audio_unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0,
            &hdmi_device, sizeof(hdmi_device));
        if (status != noErr) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to set HDMI device on audio unit"};
        }

        // Set stream format matching the physical format
        status = AudioUnitSetProperty(impl_->audio_unit,
            kAudioUnitProperty_StreamFormat,
            kAudioUnitScope_Input, 0,
            &target_format, sizeof(target_format));
        if (status != noErr) {
            PY_LOG_WARN(TAG, "Failed to set HDMI stream format on audio unit (status %d)", (int)status);
        }

        AURenderCallbackStruct callback;
        callback.inputProc = Impl::passthroughRenderCallback;
        callback.inputProcRefCon = impl_.get();

        status = AudioUnitSetProperty(impl_->audio_unit,
            kAudioUnitProperty_SetRenderCallback,
            kAudioUnitScope_Input, 0,
            &callback, sizeof(callback));

        if (status != noErr) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to set HDMI passthrough callback"};
        }

        status = AudioUnitInitialize(impl_->audio_unit);
        if (status != noErr) {
            close();
            impl_->passthrough_mode = false;
            return {ErrorCode::AudioOutputError, "Failed to initialize HDMI passthrough audio unit"};
        }

        impl_->sample_rate = static_cast<int>(target_format.mSampleRate);
        PY_LOG_INFO(TAG, "Passthrough opened (HDMI): codec_id=%d, %d Hz", codec_id, impl_->sample_rate);
        return Error::Ok();
    }

    impl_->passthrough_mode = false;
    return {ErrorCode::AudioOutputError, "Unsupported codec for passthrough"};
#endif
}

bool CAAudioOutput::is_passthrough() const {
    return impl_->passthrough_mode;
}

void CAAudioOutput::set_bitstream_pull_callback(BitstreamPullCallback cb) {
    std::lock_guard lock(impl_->callback_mutex);
    impl_->bitstream_pull_callback = std::move(cb);
}

// ---- Common methods ----

void CAAudioOutput::close() {
    stop();
    if (impl_->audio_unit) {
        AudioUnitUninitialize(impl_->audio_unit);
        AudioComponentInstanceDispose(impl_->audio_unit);
        impl_->audio_unit = nullptr;
    }

#if TARGET_OS_OSX
    // Restore original HDMI stream format if we changed it
    if (impl_->hdmi_stream != kAudioObjectUnknown) {
        AudioObjectPropertyAddress phys_addr = {
            kAudioStreamPropertyPhysicalFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioObjectSetPropertyData(impl_->hdmi_stream, &phys_addr, 0, nullptr,
            sizeof(impl_->hdmi_original_format), &impl_->hdmi_original_format);
        impl_->hdmi_stream = kAudioObjectUnknown;
        impl_->hdmi_device = kAudioObjectUnknown;
    }
#endif

    impl_->samples_played = 0;
    impl_->passthrough_mode = false;
}

void CAAudioOutput::reset_position() {
    impl_->samples_played = 0;
}

void CAAudioOutput::start() {
    if (impl_->audio_unit && !impl_->running) {
        OSStatus status = AudioOutputUnitStart(impl_->audio_unit);
        if (status == noErr) {
            impl_->running = true;
            PY_LOG_INFO(TAG, "Audio output started");
        }
    }
}

void CAAudioOutput::stop() {
    if (impl_->audio_unit && impl_->running) {
        AudioOutputUnitStop(impl_->audio_unit);
        impl_->running = false;
    }
}

void CAAudioOutput::set_pull_callback(PullCallback cb) {
    std::lock_guard lock(impl_->callback_mutex);
    impl_->pull_callback = std::move(cb);
}

void CAAudioOutput::set_pts_callback(PtsCallback cb) {
    std::lock_guard lock(impl_->callback_mutex);
    impl_->pts_callback = std::move(cb);
}

int CAAudioOutput::sample_rate() const { return impl_->sample_rate; }
int CAAudioOutput::channels() const { return impl_->channels; }

// ---- PCM render callback ----

OSStatus CAAudioOutput::Impl::renderCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData)
{
    auto* self = static_cast<Impl*>(inRefCon);

    float* buffer = static_cast<float*>(ioData->mBuffers[0].mData);
    int frames = static_cast<int>(inNumberFrames);
    int channels = self->channels;

    // Callbacks are set before start() and cleared after stop(),
    // so they are safe to read without locking on the real-time thread.
    int written = 0;
    if (self->pull_callback) {
        written = self->pull_callback(buffer, frames, channels);
    }

    // Silence any remaining frames
    if (written < frames) {
        memset(buffer + written * channels, 0,
               (frames - written) * channels * sizeof(float));
    }

    // Update samples played and report PTS
    self->samples_played += frames;
    if (self->pts_callback && self->sample_rate > 0) {
        int64_t pts_us = self->samples_played * 1000000LL / self->sample_rate;
        self->pts_callback(pts_us);
    }

    return noErr;
}

// ---- Passthrough render callback ----

OSStatus CAAudioOutput::Impl::passthroughRenderCallback(
    void* inRefCon,
    AudioUnitRenderActionFlags* ioActionFlags,
    const AudioTimeStamp* inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList* ioData)
{
    auto* self = static_cast<Impl*>(inRefCon);

    auto* buffer = static_cast<uint8_t*>(ioData->mBuffers[0].mData);
    int bytes = static_cast<int>(ioData->mBuffers[0].mDataByteSize);

    int written = 0;
    if (self->bitstream_pull_callback) {
        written = self->bitstream_pull_callback(buffer, bytes);
    }

    // Zero-fill any remainder
    if (written < bytes) {
        memset(buffer + written, 0, bytes - written);
    }

    // Update samples played for clock sync
    self->samples_played += inNumberFrames;
    if (self->pts_callback && self->sample_rate > 0) {
        int64_t pts_us = self->samples_played * 1000000LL / self->sample_rate;
        self->pts_callback(pts_us);
    }

    return noErr;
}

} // namespace py
