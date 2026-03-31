#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "dv_video_output.h"
#include "plaiy/logger.h"

#include <mutex>
#include <condition_variable>

static constexpr const char* TAG = "DVVideoOutput";

namespace py {

struct DVVideoOutput::Impl {
    CMFormatDescriptionRef format_desc = nullptr;
    CMTimebaseRef timebase = nullptr;
    AVSampleBufferDisplayLayer* display_layer = nil;
    bool opened = false;
    std::atomic<int> packets_submitted{0};
    std::atomic<int64_t> last_pts_us{0};

    // Event-driven readiness signaling (replaces polling loop)
    std::mutex ready_mutex;
    std::condition_variable ready_cv;
    std::atomic<bool> ready_flag{false};
    dispatch_queue_t ready_queue = nullptr;
};

DVVideoOutput::DVVideoOutput() : impl_(std::make_unique<Impl>()) {}

DVVideoOutput::~DVVideoOutput() {
    close();
}

Error DVVideoOutput::open(const TrackInfo& track) {
    close();

    if (track.extradata.empty()) {
        return {ErrorCode::DecoderInitFailed, "DVVideoOutput: no extradata"};
    }

    PY_LOG_INFO(TAG, "Opening: %s %dx%d, DV profile %d.%d compat=%d",
                track.codec_name.c_str(), track.width, track.height,
                track.dv_profile, track.dv_level, track.dv_bl_signal_compatibility_id);

    const uint8_t* extra = track.extradata.data();
    size_t extra_size = track.extradata.size();

    // Determine codec type and atom names based on codec
    CMVideoCodecType dv_codec_type;
    CFStringRef config_atom_key;  // hvcC or av1C
    CFStringRef dovi_atom_key;    // dvcC or dvvC

    bool is_av1 = (track.codec_name.find("av1") != std::string::npos ||
                   track.codec_name.find("AV1") != std::string::npos);

    if (is_av1) {
        // Use Apple's standard AV1 codec type. DV processing is triggered
        // by the dvvC extension atom, not by a special codec FourCC.
        dv_codec_type = kCMVideoCodecType_AV1;
        config_atom_key = CFSTR("av1C");
        dovi_atom_key = CFSTR("dvvC");
        PY_LOG_DEBUG(TAG, "AV1 DV: using kCMVideoCodecType_AV1 + dvvC");
    } else {
        // HEVC DV: check if parameter sets are in the hvcC (sample description)
        // or in-band (in the compressed packets).
        //
        // The hvcC header is 23 bytes. Byte 22 is numOfArrays.
        // If numOfArrays == 0, the VPS/SPS/PPS are in-band.
        //   -> use 'dvhe' (like 'hev1': in-band parameter sets OK)
        // If numOfArrays > 0, parameter sets are in the hvcC.
        //   -> use 'dvh1' (like 'hvc1': parameter sets in sample description)
        bool params_in_band = (extra_size <= 23);
        if (!params_in_band && extra_size > 22) {
            params_in_band = (extra[22] == 0);  // numOfArrays == 0
        }

        dv_codec_type = params_in_band ? (CMVideoCodecType)'dvhe'
                                       : (CMVideoCodecType)'dvh1';
        config_atom_key = CFSTR("hvcC");
        dovi_atom_key = CFSTR("dvcC");
        PY_LOG_DEBUG(TAG, "HEVC DV: params_in_band=%d, codec='%s'",
                     params_in_band, params_in_band ? "dvhe" : "dvh1");
    }

    // Build SampleDescriptionExtensionAtoms with codec config + DOVI config

    CFDataRef codec_config = CFDataCreate(kCFAllocatorDefault, extra,
                                          static_cast<CFIndex>(extra_size));

    CFMutableDictionaryRef atoms = CFDictionaryCreateMutable(
        kCFAllocatorDefault, 2,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(atoms, config_atom_key, codec_config);
    CFRelease(codec_config);

    // Add DOVI configuration record
    if (!track.dv_config_raw.empty()) {
        CFDataRef dovi_data = CFDataCreate(kCFAllocatorDefault,
            track.dv_config_raw.data(),
            static_cast<CFIndex>(track.dv_config_raw.size()));
        CFDictionarySetValue(atoms, dovi_atom_key, dovi_data);
        CFRelease(dovi_data);
        PY_LOG_DEBUG(TAG, "DOVI config atom: %zu bytes", track.dv_config_raw.size());
    } else {
        PY_LOG_WARN(TAG, "No DOVI config data available");
    }

    // Build extensions dictionary with atoms only.
    // Don't add color space extensions — they break ASBDL for some profiles.
    // ASBDL detects HDR from the content and dvvC/dvcC atoms.
    const void* ext_keys[] = { CFSTR("SampleDescriptionExtensionAtoms") };
    const void* ext_values[] = { atoms };
    CFDictionaryRef ext_dict = CFDictionaryCreate(kCFAllocatorDefault,
        ext_keys, ext_values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, dv_codec_type,
        track.width, track.height,
        ext_dict, &impl_->format_desc);

    CFRelease(ext_dict);
    CFRelease(atoms);

    if (status != noErr || !impl_->format_desc) {
        PY_LOG_ERROR(TAG, "CMVideoFormatDescriptionCreate failed: %d", (int)status);
        return {ErrorCode::DecoderInitFailed,
                "DVVideoOutput: CMVideoFormatDescriptionCreate failed: "
                + std::to_string(status)};
    }

    // Create CMTimebase (clock source = host clock)
    CMClockRef host_clock = CMClockGetHostTimeClock();
    status = CMTimebaseCreateWithSourceClock(
        kCFAllocatorDefault, host_clock, &impl_->timebase);
    if (status != noErr) {
        CFRelease(impl_->format_desc);
        impl_->format_desc = nullptr;
        PY_LOG_ERROR(TAG, "CMTimebaseCreate failed: %d", (int)status);
        return {ErrorCode::DecoderInitFailed,
                "DVVideoOutput: CMTimebaseCreate failed: " + std::to_string(status)};
    }

    // Start paused
    CMTimebaseSetRate(impl_->timebase, 0.0);
    CMTimebaseSetTime(impl_->timebase, kCMTimeZero);

    impl_->opened = true;
    impl_->packets_submitted.store(0, std::memory_order_relaxed);
    impl_->last_pts_us.store(0, std::memory_order_relaxed);
    PY_LOG_INFO(TAG, "Opened DV output: %dx%d, profile %d",
                track.width, track.height, track.dv_profile);
    return Error::Ok();
}

void DVVideoOutput::set_display_layer(void* layer) {
    @autoreleasepool {
        impl_->display_layer = (__bridge AVSampleBufferDisplayLayer*)layer;
        if (impl_->display_layer && impl_->timebase) {
            impl_->display_layer.controlTimebase = impl_->timebase;

            // Set up event-driven readiness notification
            if (!impl_->ready_queue) {
                impl_->ready_queue = dispatch_queue_create(
                    "py.dv_video_output.ready", DISPATCH_QUEUE_SERIAL);
            }
            auto* impl = impl_.get();
            [impl_->display_layer.sampleBufferRenderer
                requestMediaDataWhenReadyOnQueue:impl_->ready_queue
                usingBlock:^{
                    impl->ready_flag.store(true, std::memory_order_release);
                    impl->ready_cv.notify_one();
                }];

            PY_LOG_INFO(TAG, "Display layer set, timebase attached");
        }
    }
}

Error DVVideoOutput::submit_packet(const Packet& pkt) {
    if (!impl_->opened || !impl_->display_layer || !impl_->format_desc) {
        return {ErrorCode::InvalidState, "DVVideoOutput not ready"};
    }

    @autoreleasepool {
        // Create CMBlockBuffer with a copy of the packet data
        CMBlockBufferRef block_buffer = nullptr;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(
            kCFAllocatorDefault,
            nullptr,
            pkt.data.size(),
            kCFAllocatorDefault,
            nullptr, 0,
            pkt.data.size(),
            kCMBlockBufferAssureMemoryNowFlag,
            &block_buffer);

        if (status != noErr || !block_buffer) {
            return {ErrorCode::DecoderError, "DVVideoOutput: block buffer creation failed"};
        }

        status = CMBlockBufferReplaceDataBytes(
            pkt.data.data(), block_buffer, 0, pkt.data.size());
        if (status != noErr) {
            CFRelease(block_buffer);
            return {ErrorCode::DecoderError, "DVVideoOutput: block buffer copy failed"};
        }

        // Timing in stream time_base units (same as VT decoder)
        CMSampleTimingInfo timing;
        timing.duration = CMTimeMake(pkt.duration, pkt.time_base_den);
        timing.presentationTimeStamp = CMTimeMake(pkt.pts, pkt.time_base_den);
        timing.decodeTimeStamp = CMTimeMake(pkt.dts, pkt.time_base_den);

        const size_t sample_size = pkt.data.size();
        CMSampleBufferRef sample_buffer = nullptr;
        status = CMSampleBufferCreateReady(
            kCFAllocatorDefault,
            block_buffer,
            impl_->format_desc,
            1, 1, &timing,
            1, &sample_size,
            &sample_buffer);

        CFRelease(block_buffer);

        if (status != noErr || !sample_buffer) {
            PY_LOG_ERROR(TAG, "CMSampleBufferCreateReady failed: %d (pkt#%d)",
                         (int)status,
                         impl_->packets_submitted.load(std::memory_order_relaxed));
            return {ErrorCode::DecoderError,
                    "DVVideoOutput: sample buffer creation failed: "
                    + std::to_string(status)};
        }

        [impl_->display_layer.sampleBufferRenderer enqueueSampleBuffer:sample_buffer];
        CFRelease(sample_buffer);
        impl_->packets_submitted.fetch_add(1, std::memory_order_relaxed);
        impl_->last_pts_us.store(pkt.pts_us(), std::memory_order_relaxed);

        // Check for ASBDL errors after enqueue
        AVQueuedSampleBufferRenderingStatus rendererStatus =
            impl_->display_layer.sampleBufferRenderer.status;
        if (rendererStatus == AVQueuedSampleBufferRenderingStatusFailed) {
            NSError* rendererError = impl_->display_layer.sampleBufferRenderer.error;
            NSString* errDesc = rendererError.localizedDescription
                ? rendererError.localizedDescription : @"unknown";
            PY_LOG_ERROR(TAG, "ASBDL rendering failed after pkt#%d: %s",
                         impl_->packets_submitted.load(std::memory_order_relaxed),
                         errDesc.UTF8String);
            return {ErrorCode::DecoderError, "ASBDL: " + std::string(errDesc.UTF8String)};
        }

        if (impl_->packets_submitted.load(std::memory_order_relaxed) == 1) {
            PY_LOG_DEBUG(TAG, "First packet enqueued, renderer status=%d",
                         (int)rendererStatus);
        }
    }

    return Error::Ok();
}

void DVVideoOutput::flush() {
    @autoreleasepool {
        if (impl_->display_layer) {
            [impl_->display_layer.sampleBufferRenderer flush];
            PY_LOG_DEBUG(TAG, "Flushed after %d packets",
                         impl_->packets_submitted.load(std::memory_order_relaxed));
            impl_->packets_submitted.store(0, std::memory_order_relaxed);
            impl_->last_pts_us.store(0, std::memory_order_relaxed);
        }
    }
}

void DVVideoOutput::set_rate(double rate) {
    if (impl_->timebase) {
        CMTimebaseSetRate(impl_->timebase, rate);
        PY_LOG_DEBUG(TAG, "set_rate(%.2f)", rate);
    }
}

void DVVideoOutput::set_time(int64_t pts_us) {
    if (impl_->timebase) {
        CMTime time = CMTimeMake(pts_us, 1000000);
        CMTimebaseSetTime(impl_->timebase, time);
        PY_LOG_DEBUG(TAG, "set_time(%.3f s)", (double)pts_us / 1e6);
    }
}

bool DVVideoOutput::wait_until_ready(const std::atomic<bool>& running) {
    if (is_ready()) return true;

    std::unique_lock<std::mutex> lock(impl_->ready_mutex);
    impl_->ready_cv.wait_for(lock, std::chrono::milliseconds(100), [&] {
        return impl_->ready_flag.load(std::memory_order_acquire) ||
               !running.load(std::memory_order_relaxed);
    });
    impl_->ready_flag.store(false, std::memory_order_relaxed);
    return is_ready() && running.load(std::memory_order_relaxed);
}

bool DVVideoOutput::is_ready() const {
    @autoreleasepool {
        if (!impl_->display_layer) return false;
        return impl_->display_layer.sampleBufferRenderer.isReadyForMoreMediaData;
    }
}

bool DVVideoOutput::has_display_layer() const {
    return impl_->display_layer != nil;
}

int DVVideoOutput::packets_submitted_count() const {
    return impl_->packets_submitted.load(std::memory_order_relaxed);
}

int64_t DVVideoOutput::last_pts_us() const {
    return impl_->last_pts_us.load(std::memory_order_relaxed);
}

void DVVideoOutput::close() {
    @autoreleasepool {
        if (impl_->opened) {
            PY_LOG_DEBUG(TAG, "Closing (total packets: %d)",
                         impl_->packets_submitted.load(std::memory_order_relaxed));
        }
        if (impl_->display_layer && impl_->ready_queue) {
            [impl_->display_layer.sampleBufferRenderer stopRequestingMediaData];
        }
        // Wake any thread blocked in wait_until_ready
        impl_->ready_flag.store(true, std::memory_order_release);
        impl_->ready_cv.notify_all();
        impl_->display_layer = nil;

        if (impl_->timebase) {
            CFRelease(impl_->timebase);
            impl_->timebase = nullptr;
        }
        if (impl_->format_desc) {
            CFRelease(impl_->format_desc);
            impl_->format_desc = nullptr;
        }
        impl_->opened = false;
    }
}

} // namespace py
