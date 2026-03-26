#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include "vt_video_decoder.h"
#include "plaiy/logger.h"

#include <deque>
#include <mutex>

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
}

static constexpr const char* TAG = "VTVideoDecoder";

namespace py {

// Helper: build CMFormatDescription from codec extradata (shared by H264/HEVC/AV1/VP9)
static OSStatus create_vt_format_description(
    const uint8_t* extra, size_t extra_size, CFStringRef atom_key,
    CMVideoCodecType codec_type, int width, int height,
    CMFormatDescriptionRef* out_fmt)
{
    CFDataRef ext_data = CFDataCreate(kCFAllocatorDefault, extra, static_cast<CFIndex>(extra_size));
    const void* atom_keys[] = { atom_key };
    const void* atom_values[] = { ext_data };
    CFDictionaryRef atoms = CFDictionaryCreate(kCFAllocatorDefault,
        atom_keys, atom_values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void* ext_keys[] = { CFSTR("SampleDescriptionExtensionAtoms") };
    const void* ext_values[] = { atoms };
    CFDictionaryRef ext_dict = CFDictionaryCreate(kCFAllocatorDefault,
        ext_keys, ext_values, 1,
        &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);

    OSStatus status = CMVideoFormatDescriptionCreate(
        kCFAllocatorDefault, codec_type, width, height, ext_dict, out_fmt);

    CFRelease(ext_dict);
    CFRelease(atoms);
    CFRelease(ext_data);
    return status;
}

struct VTVideoDecoder::Impl {
    VTDecompressionSessionRef session = nullptr;
    CMFormatDescriptionRef format_desc = nullptr;
    TrackInfo track_info;

    std::mutex frame_mutex;
    std::deque<VideoFrame> decoded_frames;

    bool is_hevc = false;
    bool is_10bit = false;

    // Reorder buffer depth: H264/HEVC with B-frames deliver decoded frames
    // in decode order, not display order.  We accumulate this many extra
    // frames before emitting the lowest-PTS one, guaranteeing correct order.
    int reorder_depth = 0;

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

    // H264/HEVC use B-frames whose decode order differs from display order.
    // Buffer enough frames so the sorted callback insertion can place them
    // correctly before receive_frame emits them.  4 covers virtually all
    // real-world content (max_num_reorder_frames is typically 2-4).
    impl_->reorder_depth = (codec_id == AV_CODEC_ID_H264 ||
                            codec_id == AV_CODEC_ID_HEVC) ? 4 : 0;

    // Detect 10-bit: check pixel format, bit depth, and HDR indicators.
    // par->format is often AV_PIX_FMT_NONE for HEVC in containers,
    // so pixel_format alone is unreliable.
    impl_->is_10bit = (track.pixel_format == PixelFormat::P010 ||
                       track.pixel_format == PixelFormat::YUV420P10 ||
                       track.hdr_metadata.type != HDRType::SDR ||
                       track.color_trc == 16 /* SMPTE2084/PQ */ ||
                       track.color_trc == 18 /* ARIB_STD_B67/HLG */);

    if (track.extradata.empty()) {
        return {ErrorCode::DecoderInitFailed, "No extradata for VideoToolbox"};
    }

    // Create format description from extradata
    OSStatus status;
    const uint8_t* extra = track.extradata.data();
    size_t extra_size = track.extradata.size();

    if (codec_id == AV_CODEC_ID_H264) {
        status = create_vt_format_description(extra, extra_size, CFSTR("avcC"),
            kCMVideoCodecType_H264, track.width, track.height, &impl_->format_desc);
    } else if (codec_id == AV_CODEC_ID_HEVC) {
        status = create_vt_format_description(extra, extra_size, CFSTR("hvcC"),
            kCMVideoCodecType_HEVC, track.width, track.height, &impl_->format_desc);
    } else if (codec_id == AV_CODEC_ID_AV1) {
        status = create_vt_format_description(extra, extra_size, CFSTR("av1C"),
            kCMVideoCodecType_AV1, track.width, track.height, &impl_->format_desc);
    } else if (codec_id == AV_CODEC_ID_VP9) {
        status = create_vt_format_description(extra, extra_size, CFSTR("vpcC"),
            kCMVideoCodecType_VP9, track.width, track.height, &impl_->format_desc);
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

    // Enable HDR metadata propagation for HDR-capable codecs
    if (impl_->is_hevc || codec_id == AV_CODEC_ID_AV1) {
        VTSessionSetProperty(impl_->session,
            kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata,
            kCFBooleanTrue);
    }

    PY_LOG_INFO(TAG, "Opened VideoToolbox decoder: %s (%dx%d, %s)",
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

void VTVideoDecoder::set_reorder_depth(int depth) {
    std::lock_guard lock(impl_->frame_mutex);
    impl_->reorder_depth = depth;
}

void VTVideoDecoder::flush() {
    if (impl_->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
    }
    std::lock_guard lock(impl_->frame_mutex);
    impl_->decoded_frames.clear();

    // Restore reorder depth (drain() may have zeroed it for EOF draining)
    auto codec_id = static_cast<AVCodecID>(impl_->track_info.codec_id);
    impl_->reorder_depth = (codec_id == AV_CODEC_ID_H264 ||
                            codec_id == AV_CODEC_ID_HEVC) ? 4 : 0;
}

void VTVideoDecoder::clear_frames() {
    std::lock_guard lock(impl_->frame_mutex);
    impl_->decoded_frames.clear();
}

void VTVideoDecoder::drain() {
    // Wait for all in-flight async decodes to complete, then lower the
    // reorder depth so receive_frame emits every remaining buffered frame.
    // Called at end-of-stream (or seek-near-end) before the final drain.
    if (impl_->session) {
        VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
    }
    std::lock_guard lock(impl_->frame_mutex);
    impl_->reorder_depth = 0;
}

Error VTVideoDecoder::send_packet(const Packet& pkt) {
    if (!impl_->session) return {ErrorCode::InvalidState, "VT session not initialized"};

    if (pkt.is_flush) {
        VTDecompressionSessionWaitForAsynchronousFrames(impl_->session);
        return Error::Ok();
    }

    // Create CMBlockBuffer with its own copy of the data.
    // With async decode (kVTDecodeFrame_EnableAsynchronousDecompression),
    // VT may still be reading the data after send_packet returns.
    // The Packet can be freed on the next loop iteration, so VT must own the data.
    CMBlockBufferRef block_buffer = nullptr;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(
        kCFAllocatorDefault,
        nullptr,              // Let CoreMedia allocate
        pkt.data.size(),
        kCFAllocatorDefault,  // CoreMedia manages the allocation
        nullptr, 0,
        pkt.data.size(),
        kCMBlockBufferAssureMemoryNowFlag,
        &block_buffer);

    if (status != noErr || !block_buffer) {
        return {ErrorCode::DecoderError, "Failed to create block buffer"};
    }

    status = CMBlockBufferReplaceDataBytes(
        pkt.data.data(), block_buffer, 0, pkt.data.size());
    if (status != noErr) {
        CFRelease(block_buffer);
        return {ErrorCode::DecoderError, "Failed to copy data to block buffer"};
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

    // Async decode — reordering is handled by our own buffer (reorder_depth)
    // rather than kVTDecodeFrame_EnableTemporalProcessing, which adds an
    // uncontrolled delivery delay that drifts the audio clock ahead of video.
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    VTDecodeInfoFlags info_flags = 0;

    // Pre-compute PTS in microseconds to avoid heap allocation per frame
    int64_t pts_us = 0;
    if (pkt.pts >= 0 && pkt.time_base_den > 0) {
        pts_us = pkt.pts * 1000000LL * pkt.time_base_num / pkt.time_base_den;
    }
    // Pack into a pointer-sized integer (safe on 64-bit platforms)
    void* pts_refcon = reinterpret_cast<void*>(pts_us);

    status = VTDecompressionSessionDecodeFrame(
        impl_->session,
        sample_buffer,
        flags,
        pts_refcon,  // sourceFrameRefCon
        &info_flags);

    CFRelease(sample_buffer);

    if (status != noErr) {
        return {ErrorCode::DecoderError,
                "VTDecompressionSessionDecodeFrame failed: " + std::to_string(status)};
    }

    return Error::Ok();
}

Error VTVideoDecoder::receive_frame(VideoFrame& out) {
    std::lock_guard lock(impl_->frame_mutex);

    // Wait until the reorder buffer has enough frames to guarantee
    // the front (lowest PTS, via sorted insertion) is in the correct
    // display position.  Without this, B-frames that arrive after
    // their reference P-frame would be emitted out of order.
    if (impl_->decoded_frames.size() <= static_cast<size_t>(impl_->reorder_depth)) {
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
    VTDecodeInfoFlags /*infoFlags*/,
    CVImageBufferRef imageBuffer,
    CMTime /*presentationTimeStamp*/,
    CMTime presentationDuration)
{
    auto* self = static_cast<Impl*>(decompressionOutputRefCon);

    if (status != noErr || !imageBuffer) {
        PY_LOG_WARN(TAG, "VT decode callback error: %d", static_cast<int>(status));
        return;
    }

    VideoFrame frame;
    frame.width = static_cast<int>(CVPixelBufferGetWidth(imageBuffer));
    frame.height = static_cast<int>(CVPixelBufferGetHeight(imageBuffer));
    frame.hardware_frame = true;

    // PTS was pre-computed and packed into the pointer
    frame.pts_us = reinterpret_cast<int64_t>(sourceFrameRefCon);

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

    // Copy metadata from track
    frame.hdr_metadata = self->track_info.hdr_metadata;
    frame.color_space = self->track_info.color_space;
    frame.color_primaries = self->track_info.color_primaries;
    frame.color_trc = self->track_info.color_trc;
    frame.color_range = self->track_info.color_range;
    frame.sar_num = self->track_info.sar_num;
    frame.sar_den = self->track_info.sar_den;

    // Override with per-frame HDR metadata from CVPixelBuffer attachments
    CFDictionaryRef attachments = CVBufferCopyAttachments(imageBuffer, kCVAttachmentMode_ShouldPropagate);
    if (attachments) {
        auto read_u16_be = [](const uint8_t* p) -> uint16_t {
            return static_cast<uint16_t>((uint16_t(p[0]) << 8) | p[1]);
        };
        auto read_u32_be = [](const uint8_t* p) -> uint32_t {
            return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
                   (uint32_t(p[2]) << 8) | p[3];
        };

        // Mastering display color volume (MDCV) - raw HEVC SEI format
        CFDataRef mdcv = (CFDataRef)CFDictionaryGetValue(attachments,
            kCVImageBufferMasteringDisplayColorVolumeKey);
        if (mdcv && CFDataGetLength(mdcv) >= 24) {
            const uint8_t* bytes = CFDataGetBytePtr(mdcv);
            for (int j = 0; j < 3; j++) {
                frame.hdr_metadata.display_primaries_x[j] = read_u16_be(bytes + j * 4);
                frame.hdr_metadata.display_primaries_y[j] = read_u16_be(bytes + j * 4 + 2);
            }
            frame.hdr_metadata.white_point_x = read_u16_be(bytes + 12);
            frame.hdr_metadata.white_point_y = read_u16_be(bytes + 14);
            frame.hdr_metadata.max_luminance = read_u32_be(bytes + 16);
            frame.hdr_metadata.min_luminance = read_u32_be(bytes + 20);
        }

        // Content light level info (CLLI)
        CFDataRef clli = (CFDataRef)CFDictionaryGetValue(attachments,
            kCVImageBufferContentLightLevelInfoKey);
        if (clli && CFDataGetLength(clli) >= 4) {
            const uint8_t* bytes = CFDataGetBytePtr(clli);
            frame.hdr_metadata.max_content_light_level = read_u16_be(bytes);
            frame.hdr_metadata.max_frame_average_light_level = read_u16_be(bytes + 2);
        }

        CFRelease(attachments);
    }

    std::lock_guard lock(self->frame_mutex);
    // Insert sorted by PTS so frames are in display order even if VT
    // delivers them out of order (safety net for temporal processing).
    auto it = self->decoded_frames.end();
    while (it != self->decoded_frames.begin()) {
        auto prev = std::prev(it);
        if (prev->pts_us <= frame.pts_us) break;
        it = prev;
    }
    self->decoded_frames.insert(it, std::move(frame));
}

} // namespace py
