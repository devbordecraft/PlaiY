#import <AVFoundation/AVFoundation.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreAudio/CoreAudio.h>
#import <AudioToolbox/AudioToolbox.h>

#include "spatial_audio_output.h"
#include "plaiy/logger.h"

#include <atomic>
#include <cmath>
#include <vector>

static constexpr const char* TAG = "SpatialAudio";

namespace py {

// Maximum render block size for pre-allocated buffers.
static constexpr int kMaxFramesPerBlock = 4096;

// Build an AudioChannelLayout for standard surround configurations.
static AudioChannelLayoutTag channel_layout_tag_for(int channels) {
    switch (channels) {
        case 1: return kAudioChannelLayoutTag_Mono;
        case 2: return kAudioChannelLayoutTag_Stereo;
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1;
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1;
        default: return kAudioChannelLayoutTag_DiscreteInOrder | static_cast<UInt32>(channels);
    }
}

struct SpatialAudioOutput::Impl {
    AVAudioEngine *engine = nil;
    AVAudioSourceNode *sourceNode = nil;

    CMHeadphoneMotionManager *motionManager = nil;
    NSOperationQueue *motionQueue = nil;
    id configChangeObserver = nil;

    int sample_rate_ = 0;
    int channels_ = 0;
    bool running = false;

    std::atomic<bool> muted{false};
    std::atomic<float> volume{1.0f};
    std::atomic<int64_t> samples_played{0};
    std::atomic<bool> head_tracking_enabled{false};

    PullCallback pull_callback;
    PtsCallback pts_callback;
    DeviceChangeCallback device_change_callback;

    // Pre-allocated interleaved scratch buffer (no allocation on real-time thread).
    float *interleavedBuf = nullptr;

    void allocate_buffers() {
        interleavedBuf = new float[kMaxFramesPerBlock * channels_];
    }

    void free_buffers() {
        delete[] interleavedBuf;
        interleavedBuf = nullptr;
    }

    void start_head_tracking() {
        if (!head_tracking_enabled.load()) return;
        if (![CMHeadphoneMotionManager class]) {
            PY_LOG_INFO(TAG, "CMHeadphoneMotionManager not available");
            return;
        }
        if (!motionManager) {
            motionManager = [[CMHeadphoneMotionManager alloc] init];
        }
        if (!motionManager.isDeviceMotionAvailable) {
            PY_LOG_INFO(TAG, "Head tracking not available (no supported headphones)");
            return;
        }
        if (motionManager.isDeviceMotionActive) return;

        motionQueue = [[NSOperationQueue alloc] init];
        motionQueue.maxConcurrentOperationCount = 1;

        // Head tracking updates the AVAudioEngine's output spatial properties.
        // On macOS 14+, the system applies head tracking automatically for
        // AirPods Pro/Max. This CMHeadphoneMotionManager gives us awareness
        // of when head tracking is active, even if the system handles it.
        [motionManager startDeviceMotionUpdatesToQueue:motionQueue
            withHandler:^(CMDeviceMotion * _Nullable motion, NSError * _Nullable) {
                (void)motion; // System handles rendering; we just track availability
            }];

        PY_LOG_INFO(TAG, "Head tracking started");
    }

    void stop_head_tracking() {
        if (motionManager && motionManager.isDeviceMotionActive) {
            [motionManager stopDeviceMotionUpdates];
            PY_LOG_INFO(TAG, "Head tracking stopped");
        }
        motionQueue = nil;
    }
};

SpatialAudioOutput::SpatialAudioOutput() : impl_(std::make_unique<Impl>()) {}

SpatialAudioOutput::~SpatialAudioOutput() {
    close();
}

Error SpatialAudioOutput::open(int sample_rate, int channels) {
    close();

    impl_->sample_rate_ = sample_rate;
    impl_->channels_ = channels;
    impl_->samples_played.store(0);

    impl_->allocate_buffers();

    // Create AVAudioEngine
    impl_->engine = [[AVAudioEngine alloc] init];

    // Build a multichannel AVAudioFormat with the correct channel layout.
    // This tells macOS the speaker arrangement so it can apply HRTF rendering
    // for spatial-audio-capable headphones (AirPods Pro/Max).
    AudioChannelLayoutTag layoutTag = channel_layout_tag_for(channels);
    AVAudioChannelLayout *layout = [[AVAudioChannelLayout alloc]
        initWithLayoutTag:layoutTag];
    AVAudioFormat *multiChFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:sample_rate
                 interleaved:NO
               channelLayout:layout];

    if (!multiChFormat) {
        PY_LOG_ERROR(TAG, "Failed to create %d-channel audio format", channels);
        impl_->engine = nil;
        impl_->free_buffers();
        return {ErrorCode::AudioOutputError, "Failed to create multichannel audio format"};
    }

    // Single source node — one render block, no synchronization needed.
    Impl *pImpl = impl_.get();
    impl_->sourceNode = [[AVAudioSourceNode alloc]
        initWithFormat:multiChFormat
           renderBlock:^OSStatus(BOOL * _Nonnull isSilence,
                                 const AudioTimeStamp * _Nonnull,
                                 AVAudioFrameCount frameCount,
                                 AudioBufferList * _Nonnull outputData)
    {
        int frames = static_cast<int>(std::min(frameCount,
                                               (AVAudioFrameCount)kMaxFramesPerBlock));
        int numCh = pImpl->channels_;

        // Pull interleaved multichannel PCM from the ring buffer.
        int pulled = 0;
        if (pImpl->pull_callback) {
            pulled = pImpl->pull_callback(pImpl->interleavedBuf, frames, numCh);
        }

        // Deinterleave into AVAudioEngine's non-interleaved output buffers.
        // outputData has one buffer per channel (non-interleaved format).
        for (int ch = 0; ch < numCh && ch < (int)outputData->mNumberBuffers; ch++) {
            float *dst = (float *)outputData->mBuffers[ch].mData;
            // Copy this channel from interleaved source
            for (int f = 0; f < pulled; f++) {
                dst[f] = pImpl->interleavedBuf[f * numCh + ch];
            }
            // Zero-fill remainder on underrun
            for (int f = pulled; f < frames; f++) {
                dst[f] = 0.0f;
            }

            // Apply volume
            float vol = pImpl->volume.load(std::memory_order_relaxed);
            if (vol < 0.999f) {
                for (int f = 0; f < frames; f++) {
                    dst[f] *= vol;
                }
            }
        }

        // Apply mute
        if (pImpl->muted.load(std::memory_order_relaxed)) {
            for (int ch = 0; ch < (int)outputData->mNumberBuffers; ch++) {
                memset(outputData->mBuffers[ch].mData, 0,
                       static_cast<size_t>(frames) * sizeof(float));
            }
            *isSilence = YES;
        }

        // Update PTS tracking
        pImpl->samples_played.fetch_add(pulled, std::memory_order_relaxed);

        return noErr;
    }];

    [impl_->engine attachNode:impl_->sourceNode];

    // Connect source → mainMixerNode with the multichannel format.
    // macOS automatically applies HRTF spatial rendering for AirPods Pro/Max
    // when it sees multichannel content with a proper channel layout.
    [impl_->engine connect:impl_->sourceNode
                        to:impl_->engine.mainMixerNode
                    format:multiChFormat];

    [impl_->engine prepare];

    PY_LOG_INFO(TAG, "Spatial audio opened: %d Hz, %d ch (layout tag 0x%x)",
                sample_rate, channels, (unsigned)layoutTag);
    return {};
}

void SpatialAudioOutput::close() {
    stop();

    if (impl_->configChangeObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:impl_->configChangeObserver];
        impl_->configChangeObserver = nil;
    }

    if (impl_->engine) {
        if (impl_->sourceNode) {
            [impl_->engine detachNode:impl_->sourceNode];
            impl_->sourceNode = nil;
        }
        impl_->engine = nil;
    }

    impl_->free_buffers();
    impl_->running = false;
}

void SpatialAudioOutput::start() {
    if (!impl_->engine || impl_->running) return;

    NSError *error = nil;
    if (![impl_->engine startAndReturnError:&error]) {
        PY_LOG_ERROR(TAG, "Failed to start AVAudioEngine: %s",
                     error.localizedDescription.UTF8String);
        return;
    }
    impl_->running = true;

    // Register for engine configuration change (device disconnect, etc.)
    Impl *pImpl = impl_.get();
    impl_->configChangeObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:impl_->engine
                     queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification * _Nonnull) {
            PY_LOG_WARN(TAG, "AVAudioEngine configuration changed (device change)");
            if (pImpl->device_change_callback) {
                pImpl->device_change_callback();
            }
        }];

    impl_->start_head_tracking();

    PY_LOG_INFO(TAG, "Spatial audio started");
}

void SpatialAudioOutput::stop() {
    impl_->stop_head_tracking();

    if (impl_->engine && impl_->running) {
        [impl_->engine stop];
        impl_->running = false;
        PY_LOG_INFO(TAG, "Spatial audio stopped");
    }
}

void SpatialAudioOutput::reset_position() {
    impl_->samples_played.store(0);
}

void SpatialAudioOutput::set_pull_callback(PullCallback cb) {
    impl_->pull_callback = std::move(cb);
}

void SpatialAudioOutput::set_pts_callback(PtsCallback cb) {
    impl_->pts_callback = std::move(cb);
}

int SpatialAudioOutput::sample_rate() const {
    return impl_->sample_rate_;
}

int SpatialAudioOutput::channels() const {
    return impl_->channels_;
}

int SpatialAudioOutput::max_device_channels() const {
    // Return 8 so the player engine doesn't downmix before feeding us.
    // We output multichannel to AVAudioEngine; macOS handles HRTF rendering.
    return 8;
}

void SpatialAudioOutput::set_muted(bool muted) {
    impl_->muted.store(muted);
}

bool SpatialAudioOutput::is_muted() const {
    return impl_->muted.load();
}

void SpatialAudioOutput::set_volume(float v) {
    impl_->volume.store(v);
}

float SpatialAudioOutput::volume() const {
    return impl_->volume.load();
}

void SpatialAudioOutput::set_device_change_callback(DeviceChangeCallback cb) {
    impl_->device_change_callback = std::move(cb);
}

void SpatialAudioOutput::set_head_tracking_enabled(bool enabled) {
    bool was = impl_->head_tracking_enabled.exchange(enabled);
    if (enabled && !was && impl_->running) {
        impl_->start_head_tracking();
    } else if (!enabled && was) {
        impl_->stop_head_tracking();
    }
}

bool SpatialAudioOutput::is_head_tracking_enabled() const {
    return impl_->head_tracking_enabled.load();
}

bool SpatialAudioOutput::is_spatial() const {
    return true;
}

} // namespace py
