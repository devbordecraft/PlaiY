#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "vt_video_decoder.h"
#include "testplayer/logger.h"

#include <deque>
#include <mutex>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

static constexpr const char* TAG = "VTVideoDecoder";

namespace tp {

struct VTVideoDecoder::Impl {
    VTDecompressionSessionRef session = nullptr;
    CMFormatDescriptionRef format_desc = nullptr;
    TrackInfo track_info;

    std::mutex frame_mutex;
    std::deque<VideoFrame> decoded_frames;

    bool is_hevc = false;
    bool is_10bit = false;

    static void decompressionCallback(
        void* decompressionOutputRefCon,
        void* sourceFrameRefCon,
        OSStatus status,
        VTDecodeInfoFlags infoFlags,
        CVImageBufferRef imageBuffer,
        CMTime presentationTimeStamp,
        CMTime presentationDuration);
};

VTVideoDecoder::VTVideoDecoder() : impl_(std::make_unique<Impl>()) {}

VTVideoDecoder::~VTVideoDecoder() {
    close();
}

Error VTVideoDecoder::open(const TrackInfo& track) {
    close();
    impl_->track_info = track;

    auto codec_id = static_cast<AVCodecID>(track.codec_id);
    impl_->is_hevc = (codec_id == AV_CODEC_ID_HEVC);
    impl_->is_10bit = (track.pixel_format == PixelFormat::P010 ||
                       track.pixel_format == PixelFormat::YUV420P10);

    if (track.extradata.empty()) {
        return {ErrorCode::DecoderInitFailed, "No extradata for VideoToolbox"};
    }

    // Create format description from extradata
    OSStatus status;
    const uint8_t* extra = track.extradata.data();
    size_t extra_size = track.extradata.size();

    if (codec_id == AV_CODEC_ID_H264) {
        // Build format description from raw avcC extradata
        CFDataRef avcC = CFDataCreate(kCFAllocatorDefault, extra, extra_size);
        const void* atomKeys[] = { CFSTR("avcC") };
        const void* atomValues[] = { avcC };
        CFDictionaryRef atoms = CFDictionaryCreate(kCFAllocatorDefault,
            atomKeys, atomValues, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        const void* extKeys[] = { CFSTR("SampleDescriptionExtensionAtoms") };
        CFDictionaryRef extDict = CFDictionaryCreate(kCFAllocatorDefault,
            extKeys, (const void*[]){atoms}, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        status = CMVideoFormatDescriptionCreate(
            kCFAllocatorDefault,
            kCMVideoCodecType_H264,
            track.width, track.height,
            extDict,
            &impl_->format_desc);

        CFRelease(extDict);
        CFRelease(atoms);
        CFRelease(avcC);
    } else if (codec_id == AV_CODEC_ID_HEVC) {
        const void* extKeys[] = { CFSTR("SampleDescriptionExtensionAtoms") };
        CFDataRef hvcC = CFDataCreate(kCFAllocatorDefault, extra, extra_size);
        const void* atomKeys[] = { CFSTR("hvcC") };
        const void* atomValues[] = { hvcC };
        CFDictionaryRef atoms = CFDictionaryCreate(kCFAllocatorDefault,
            atomKeys, atomValues, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionaryRef extDict = CFDictionaryCreate(kCFAllocatorDefault,
            extKeys, (const void*[]){atoms}, 1,
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

        status = CMVideoFormatDescriptionCreate(
            kCFAllocatorDefault,
            kCMVideoCodecType_HEVC,
            track.width, track.height,
            extDict,
            &impl_->format_desc);

        CFRelease(extDict);
        CFRelease(atoms);
        CFRelease(hvcC);
    } else {
        return {ErrorCode::UnsupportedCodec, "VideoToolbox: unsupported codec"};
    }

    if (status != noErr || !impl_->format_desc) {
        return {ErrorCode::DecoderInitFailed, "Failed to create format description"};
    }

    // Output pixel format: 10-bit for HDR content, 8-bit otherwise
    OSType pixel_format = impl_->is_10bit
        ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;

    NSDictionary* destImageAttrs = @{
        (NSString*)kCVPixelBufferPixelFormatTypeKey: @(pixel_format),
        (NSString*)kCVPixelBufferWidthKey: @(track.width),
        (NSString*)kCVPixelBufferHeightKey: @(track.height),
        (NSString*)kCVPixelBufferIOSurfacePropertiesKey: @{},
        (NSString*)kCVPixelBufferMetalCompatibilityKey: @YES,
    };

    VTDecompressionOutputCallbackRecord callback;
    callback.decompressionOutputCallback = Impl::decompressionCallback;
    callback.decompressionOutputRefCon = impl_.get();

    // Decoder configuration
    NSDictionary* decoderConfig = @{
        (NSString*)kVTDecompressionPropertyKey_RealTime: @YES,
    };

    status = VTDecompressionSessionCreate(
        kCFAllocatorDefault,
        impl_->format_desc,
        (__bridge CFDictionaryRef)decoderConfig,
        (__bridge CFDictionaryRef)destImageAttrs,
        &callback,
        &impl_->session);

    if (status != noErr) {
        return {ErrorCode::DecoderInitFailed,
                "VTDecompressionSessionCreate failed: " + std::to_string(status)};
    }

    // Enable HDR metadata propagation for HEVC
    if (impl_->is_hevc) {
        VTSessionSetProperty(impl_->session,
            kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
            kCFBooleanTrue);
    }

    TP_LOG_INFO(TAG, "Opened VideoToolbox decoder: %s (%dx%d, %s)",
                track.codec_name.c_str(), track.width, track.height,
                impl_->is_10bit ? "10-bit" : "8-bit");

    return Error::Ok();
}

void VTVideoDecoder::close() {
    if (impl_->session) {
        VTDecompressionSessionInvalidate(impl_->session);
        CFRelease(impl_->session);
        impl_->session = nullptr;
    }
    if (impl_->format_desc) {
        CFRelease(impl_->format_desc);
        impl_->format_desc = nullptr;
    }
    std::lock_guard lock(impl_->frame_mutex);
    impl_->decoded_frames.clear();
}

void VTVideoDecoder::flush() {
    if (impl_->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
    }
    std::lock_guard lock(impl_->frame_mutex);
    impl_->decoded_frames.clear();
}

Error VTVideoDecoder::send_packet(const Packet& pkt) {
    if (!impl_->session) return {ErrorCode::InvalidState, "VT session not initialized"};

    if (pkt.is_flush) {
        VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
        return Error::Ok();
    }

    // Create CMBlockBuffer from packet data
    CMBlockBufferRef block_buffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        const_cast<uint8_t*>(pkt.data.data()),
        pkt.data.size(),
        kCFAllocatorNull, // no dealloc (data owned by Packet)
        nullptr, 0,
        pkt.data.size(),
        0,
        &block_buffer);

    if (status != noErr || !block_buffer) {
        return {ErrorCode::DecoderError, "Failed to create block buffer"};
    }

    // Create CMSampleBuffer
    CMSampleBufferRef sample_buffer = nullptr;
    const size_t sample_size = pkt.data.size();
    CMSampleTimingInfo timing;
    timing.duration = CMTimeMake(pkt.duration, pkt.time_base_den);
    timing.presentationTimeStamp = CMTimeMake(pkt.pts, pkt.time_base_den);
    timing.decodeTimeStamp = CMTimeMake(pkt.dts, pkt.time_base_den);

    status = CMSampleBufferCreateReady(
        kCFAllocatorDefault,
        block_buffer,
        impl_->format_desc,
        1, 1, &timing,
        1, &sample_size,
        &sample_buffer);

    CFRelease(block_buffer);

    if (status != noErr || !sample_buffer) {
        return {ErrorCode::DecoderError, "Failed to create sample buffer"};
    }

    // Decode
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags info_flags = 0;

    // Pack PTS info for the callback
    int64_t* pts_data = new int64_t[3];
    pts_data[0] = pkt.pts;
    pts_data[1] = pkt.time_base_num;
    pts_data[2] = pkt.time_base_den;

    status = VTDecompressionSessionDecodeFrame(
        impl_->session,
        sample_buffer,
        flags,
        pts_data,  // sourceFrameRefCon
        &info_flags);

    CFRelease(sample_buffer);

    if (status != noErr) {
        delete[] pts_data;
        return {ErrorCode::DecoderError,
                "VTDecompressionSessionDecodeFrame failed: " + std::to_string(status)};
    }

    return Error::Ok();
}

Error VTVideoDecoder::receive_frame(VideoFrame& out) {
    // Wait for async decode to produce a frame
    if (impl_->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
    }

    std::lock_guard lock(impl_->frame_mutex);
    if (impl_->decoded_frames.empty()) {
        return {ErrorCode::OutputNotReady};
    }

    out = std::move(impl_->decoded_frames.front());
    impl_->decoded_frames.pop_front();
    return Error::Ok();
}

void VTVideoDecoder::Impl::decompressionCallback(
    void* decompressionOutputRefCon,
    void* sourceFrameRefCon,
    OSStatus status,
    VTDecodeInfoFlags infoFlags,
    CVImageBufferRef imageBuffer,
    CMTime presentationTimeStamp,
    CMTime presentationDuration)
{
    auto* self = static_cast<Impl*>(decompressionOutputRefCon);
    int64_t* pts_data = static_cast<int64_t*>(sourceFrameRefCon);

    if (status != noErr || !imageBuffer) {
        TP_LOG_WARN(TAG, "VT decode callback error: %d", (int)status);
        delete[] pts_data;
        return;
    }

    VideoFrame frame;
    frame.width = static_cast<int>(CVPixelBufferGetWidth(imageBuffer));
    frame.height = static_cast<int>(CVPixelBufferGetHeight(imageBuffer));
    frame.hardware_frame = true;

    // Calculate PTS in microseconds
    if (pts_data) {
        int64_t pts = pts_data[0];
        int64_t tb_num = pts_data[1];
        int64_t tb_den = pts_data[2];
        if (tb_den > 0) {
            frame.pts_us = pts * 1000000LL * tb_num / tb_den;
        }
        delete[] pts_data;
    }

    if (CMTIME_IS_VALID(presentationDuration)) {
        frame.duration_us = static_cast<int64_t>(CMTimeGetSeconds(presentationDuration) * 1e6);
    }

    // Determine pixel format
    OSType pix_fmt = CVPixelBufferGetPixelFormatType(imageBuffer);
    if (pix_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
        pix_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange) {
        frame.pixel_format = PixelFormat::P010;
    } else {
        frame.pixel_format = PixelFormat::NV12;
    }

    // Retain the CVPixelBuffer
    CVPixelBufferRetain(imageBuffer);
    frame.native_buffer = imageBuffer;
    frame.owns_native_buffer = true;

    // Copy HDR metadata from track
    frame.hdr_metadata = self->track_info.hdr_metadata;
    frame.color_space = self->track_info.color_space;
    frame.color_primaries = self->track_info.color_primaries;
    frame.color_trc = self->track_info.color_trc;

    std::lock_guard lock(self->frame_mutex);
    self->decoded_frames.push_back(std::move(frame));
}

} // namespace tp
