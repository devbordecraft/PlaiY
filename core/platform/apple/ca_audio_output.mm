#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/CoreAudio.h>

#include "ca_audio_output.h"
#include "testplayer/logger.h"

#include <mutex>

static constexpr const char* TAG = "CAAudioOutput";

namespace tp {

struct CAAudioOutput::Impl {
    AudioComponentInstance audio_unit = nullptr;
    int sample_rate = 0;
    int channels = 0;
    bool running = false;

    std::mutex callback_mutex;
    IAudioOutput::PullCallback pull_callback;
    IAudioOutput::PtsCallback pts_callback;

    int64_t samples_played = 0;

    static OSStatus renderCallback(
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

Error CAAudioOutput::open(int sample_rate, int channels) {
    close();
    impl_->sample_rate = sample_rate;
    impl_->channels = channels;

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

    TP_LOG_INFO(TAG, "Audio output opened: %d Hz, %d channels", sample_rate, channels);
    return Error::Ok();
}

void CAAudioOutput::close() {
    stop();
    if (impl_->audio_unit) {
        AudioUnitUninitialize(impl_->audio_unit);
        AudioComponentInstanceDispose(impl_->audio_unit);
        impl_->audio_unit = nullptr;
    }
    impl_->samples_played = 0;
}

void CAAudioOutput::start() {
    if (impl_->audio_unit && !impl_->running) {
        OSStatus status = AudioOutputUnitStart(impl_->audio_unit);
        if (status == noErr) {
            impl_->running = true;
            TP_LOG_INFO(TAG, "Audio output started");
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

    int written = 0;
    {
        std::lock_guard lock(self->callback_mutex);
        if (self->pull_callback) {
            written = self->pull_callback(buffer, frames, channels);
        }
    }

    // Silence any remaining frames
    if (written < frames) {
        memset(buffer + written * channels, 0,
               (frames - written) * channels * sizeof(float));
    }

    // Update samples played and report PTS
    self->samples_played += frames;
    {
        std::lock_guard lock(self->callback_mutex);
        if (self->pts_callback && self->sample_rate > 0) {
            int64_t pts_us = self->samples_played * 1000000LL / self->sample_rate;
            self->pts_callback(pts_us);
        }
    }

    return noErr;
}

} // namespace tp
