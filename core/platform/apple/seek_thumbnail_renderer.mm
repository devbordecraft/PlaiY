#include "seek_thumbnail_renderer.h"
#include "plaiy/logger.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>
#import <simd/simd.h>

static constexpr const char* TAG = "ThumbRender";

namespace py {

namespace {

struct VideoUniforms {
    int32_t colorSpace = 0;
    int32_t transferFunc = 0;
    int32_t colorRange = 0;
    float edrHeadroom = 1.0f;
    float maxLuminance = 100.0f;
    float sdrWhite = 203.0f;

    int32_t hdr10plusPresent = 0;
    float kneePointX = 0.0f;
    float kneePointY = 0.0f;
    int32_t numBezierAnchors = 0;
    float bezierAnchors[15] = {};
    float targetMaxLuminance = 0.0f;

    float maxscl[3] = {};
    float maxFALL = 0.0f;

    int32_t chromaFormat = 0;

    int32_t doviPresent = 0;
    float doviYccToRgb[9] = {};
    float doviYccOffset[3] = {};
    float doviRgbToLms[9] = {};
    float doviLmsToRgb[9] = {};

    int32_t doviHasL1 = 0;
    float doviL1MinPQ = 0.0f;
    float doviL1MaxPQ = 1.0f;
    float doviL1AvgPQ = 0.0f;

    int32_t doviHasL2 = 0;
    float doviL2Slope = 1.0f;
    float doviL2Offset = 1.0f;
    float doviL2Power = 1.0f;
    float doviL2ChromaWeight = 0.0f;
    float doviL2SatGain = 1.0f;

    int32_t doviHasReshaping = 0;
    int32_t bitDepth = 8;
    float minLuminance = 0.0f;
};

struct CropUniforms {
    simd_float2 texOrigin = simd_make_float2(0.0f, 0.0f);
    simd_float2 texScale = simd_make_float2(1.0f, 1.0f);
};

struct ColorFilterUniforms {
    float brightness = 0.0f;
    float contrast = 1.0f;
    float saturation = 1.0f;
    float sharpness = 0.0f;
    float debandEnabled = 0.0f;
    float lanczosUpscaling = 0.0f;
    uint32_t frameCounter = 0;
};

static_assert(sizeof(CropUniforms) == sizeof(float) * 4, "CropUniforms layout mismatch");
static_assert(sizeof(ColorFilterUniforms) == sizeof(float) * 6 + sizeof(uint32_t),
              "ColorFilterUniforms layout mismatch");

VideoUniforms build_video_uniforms(const VideoFrame& frame) {
    VideoUniforms uniforms;

    const int hdr_type = static_cast<int>(frame.hdr_metadata.type);
    const int color_trc = frame.color_trc;
    const int color_matrix = frame.color_space;
    const int color_range = frame.color_range;

    if (hdr_type == static_cast<int>(HDRType::DolbyVision)) {
        if (color_matrix == 0 || color_matrix == 2) {
            uniforms.colorSpace = 3;
            uniforms.transferFunc = 3;
        } else {
            uniforms.colorSpace = 1;
            uniforms.transferFunc = 1;
        }

        if (frame.dovi_color.present) {
            uniforms.doviPresent = 1;
            std::memcpy(uniforms.doviYccToRgb, frame.dovi_color.ycc_to_rgb_matrix,
                        sizeof(uniforms.doviYccToRgb));
            std::memcpy(uniforms.doviYccOffset, frame.dovi_color.ycc_to_rgb_offset,
                        sizeof(uniforms.doviYccOffset));
            std::memcpy(uniforms.doviRgbToLms, frame.dovi_color.rgb_to_lms_matrix,
                        sizeof(uniforms.doviRgbToLms));
            std::memcpy(uniforms.doviLmsToRgb, frame.dovi_color.lms_to_rgb_matrix,
                        sizeof(uniforms.doviLmsToRgb));

            if (frame.dovi_color.has_l1) {
                uniforms.doviHasL1 = 1;
                uniforms.doviL1MinPQ = static_cast<float>(frame.dovi_color.l1_min_pq) / 4095.0f;
                uniforms.doviL1MaxPQ = static_cast<float>(frame.dovi_color.l1_max_pq) / 4095.0f;
                uniforms.doviL1AvgPQ = static_cast<float>(frame.dovi_color.l1_avg_pq) / 4095.0f;
            }

            if (frame.dovi_color.has_l2) {
                uniforms.doviHasL2 = 1;
                uniforms.doviL2Slope = static_cast<float>(frame.dovi_color.l2_trim_slope) / 2048.0f;
                uniforms.doviL2Offset = static_cast<float>(frame.dovi_color.l2_trim_offset) / 2048.0f;
                uniforms.doviL2Power = static_cast<float>(frame.dovi_color.l2_trim_power) / 2048.0f;
                uniforms.doviL2ChromaWeight =
                    static_cast<float>(frame.dovi_color.l2_trim_chroma_weight) / 4095.0f;
                uniforms.doviL2SatGain =
                    static_cast<float>(frame.dovi_color.l2_trim_saturation_gain) / 2048.0f;
            }

            if (frame.dovi_color.has_reshaping) {
                uniforms.doviHasReshaping = 1;
            }
        }
    } else {
        if (color_trc == 16) {
            uniforms.transferFunc = 1;
        } else if (color_trc == 18) {
            uniforms.transferFunc = 2;
        }

        if (color_matrix == 9 || color_matrix == 10) {
            uniforms.colorSpace = 1;
        } else if (color_matrix == 5 || color_matrix == 6) {
            uniforms.colorSpace = 2;
        }
    }

    uniforms.colorRange = (color_range == 2) ? 1 : 0;

    if (frame.hdr_metadata.max_luminance > 0) {
        uniforms.maxLuminance = static_cast<float>(frame.hdr_metadata.max_luminance) / 10000.0f;
    }
    if (frame.hdr_metadata.max_content_light_level > 0) {
        uniforms.maxLuminance = std::max(uniforms.maxLuminance,
                                         static_cast<float>(frame.hdr_metadata.max_content_light_level));
    }
    if (frame.hdr_metadata.min_luminance > 0) {
        uniforms.minLuminance = static_cast<float>(frame.hdr_metadata.min_luminance) / 10000.0f;
    }
    if (frame.hdr_metadata.max_frame_average_light_level > 0) {
        uniforms.maxFALL = std::max(uniforms.maxFALL,
                                    static_cast<float>(frame.hdr_metadata.max_frame_average_light_level));
    }

    if (frame.dovi_color.has_l6) {
        if (frame.dovi_color.l6_max_cll > 0) {
            uniforms.maxLuminance = std::max(uniforms.maxLuminance,
                                             static_cast<float>(frame.dovi_color.l6_max_cll));
        }
        if (frame.dovi_color.l6_max_fall > 0) {
            uniforms.maxFALL = std::max(uniforms.maxFALL,
                                        static_cast<float>(frame.dovi_color.l6_max_fall));
        }
        if (frame.dovi_color.l6_min_luminance > 0) {
            uniforms.minLuminance =
                static_cast<float>(frame.dovi_color.l6_min_luminance) / 10000.0f;
        }
    }

    switch (frame.chroma_format) {
    case ChromaFormat::Chroma422:
        uniforms.chromaFormat = 1;
        break;
    case ChromaFormat::Chroma444:
        uniforms.chromaFormat = 2;
        break;
    case ChromaFormat::Chroma420:
    default:
        uniforms.chromaFormat = 0;
        break;
    }

    switch (frame.pixel_format) {
    case PixelFormat::P010:
    case PixelFormat::P210:
    case PixelFormat::YUV420P10:
    case PixelFormat::YUV422P10:
        uniforms.bitDepth = 10;
        break;
    default:
        uniforms.bitDepth = 8;
        break;
    }

    uniforms.edrHeadroom = 1.0f;
    return uniforms;
}

id<MTLTexture> create_blue_noise_texture(id<MTLDevice> device) {
    static constexpr int kSize = 64;
    MTLTextureDescriptor* desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                          width:kSize
                                                         height:kSize
                                                      mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> texture = [device newTextureWithDescriptor:desc];
    if (!texture) return nil;

    std::vector<uint8_t> values(static_cast<size_t>(kSize * kSize));
    const double g = 1.32471795724;
    const double a1 = 1.0 / g;
    const double a2 = 1.0 / (g * g);

    for (int i = 0; i < kSize * kSize; i++) {
        int x = static_cast<int>(std::fmod(static_cast<double>(i) * a1, 1.0) * kSize) % kSize;
        int y = static_cast<int>(std::fmod(static_cast<double>(i) * a2, 1.0) * kSize) % kSize;
        values[static_cast<size_t>(y * kSize + x)] =
            static_cast<uint8_t>(std::clamp(i * 256 / (kSize * kSize), 0, 255));
    }

    MTLRegion region = MTLRegionMake2D(0, 0, kSize, kSize);
    [texture replaceRegion:region mipmapLevel:0 withBytes:values.data() bytesPerRow:kSize];
    return texture;
}

id<MTLBuffer> create_reshape_buffer(id<MTLDevice> device, const VideoFrame& frame) {
    if (!frame.dovi_color.has_reshaping) return nil;

    std::vector<float> lut_data(3072);
    for (int component = 0; component < 3; component++) {
        const size_t offset = static_cast<size_t>(component * 1024);
        std::memcpy(lut_data.data() + offset, frame.dovi_color.reshape_lut[component],
                    sizeof(frame.dovi_color.reshape_lut[component]));
    }

    return [device newBufferWithBytes:lut_data.data()
                               length:static_cast<NSUInteger>(lut_data.size() * sizeof(float))
                              options:MTLResourceStorageModeShared];
}

std::string ns_error_string(NSError* error, const char* fallback) {
    if (!error || !error.localizedDescription) {
        return fallback ? fallback : "unknown error";
    }
    const char* str = error.localizedDescription.UTF8String;
    return str ? str : (fallback ? fallback : "unknown error");
}

} // namespace

struct SeekThumbnailRenderer::Impl {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> command_queue = nil;
    id<MTLRenderPipelineState> pipeline_state = nil;
    id<MTLTexture> output_texture = nil;
    id<MTLTexture> blue_noise_texture = nil;
    CVMetalTextureCacheRef texture_cache = nullptr;
    int output_width = 0;
    int output_height = 0;
    bool available = false;

    ~Impl() {
        if (texture_cache) {
            CFRelease(texture_cache);
            texture_cache = nullptr;
        }
    }

    Error ensure_output_texture(int width, int height) {
        if (output_texture && output_width == width && output_height == height) {
            return Error::Ok();
        }

        MTLTextureDescriptor* desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                              width:static_cast<NSUInteger>(width)
                                                             height:static_cast<NSUInteger>(height)
                                                          mipmapped:NO];
        desc.usage = MTLTextureUsageRenderTarget;
        desc.storageMode = MTLStorageModeShared;

        output_texture = [device newTextureWithDescriptor:desc];
        if (!output_texture) {
            return {ErrorCode::RendererError, "Failed to allocate offscreen thumbnail texture"};
        }

        output_width = width;
        output_height = height;
        return Error::Ok();
    }
};

SeekThumbnailRenderer::SeekThumbnailRenderer() : impl_(std::make_unique<Impl>()) {
    impl_->device = MTLCreateSystemDefaultDevice();
    if (!impl_->device) {
        PY_LOG_WARN(TAG, "Metal device unavailable for thumbnail rendering");
        return;
    }

    impl_->command_queue = [impl_->device newCommandQueue];
    if (!impl_->command_queue) {
        PY_LOG_WARN(TAG, "Metal command queue unavailable for thumbnail rendering");
        return;
    }

    if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, impl_->device, nullptr,
                                  &impl_->texture_cache) != kCVReturnSuccess ||
        !impl_->texture_cache) {
        PY_LOG_WARN(TAG, "CVMetalTextureCacheCreate failed for thumbnail renderer");
        return;
    }

    id<MTLLibrary> library = [impl_->device newDefaultLibrary];
    if (!library) {
        PY_LOG_WARN(TAG, "Failed to load default Metal library for thumbnail renderer");
        return;
    }

    id<MTLFunction> vertex_func = [library newFunctionWithName:@"vertexFullscreen"];
    id<MTLFunction> fragment_func = [library newFunctionWithName:@"fragmentBiplanar"];
    if (!vertex_func || !fragment_func) {
        PY_LOG_WARN(TAG, "Failed to load thumbnail Metal shader functions");
        return;
    }

    MTLRenderPipelineDescriptor* pipeline_desc = [[MTLRenderPipelineDescriptor alloc] init];
    pipeline_desc.vertexFunction = vertex_func;
    pipeline_desc.fragmentFunction = fragment_func;
    pipeline_desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;

    NSError* error = nil;
    impl_->pipeline_state = [impl_->device newRenderPipelineStateWithDescriptor:pipeline_desc
                                                                          error:&error];
    if (!impl_->pipeline_state) {
        PY_LOG_WARN(TAG, "Failed to create thumbnail render pipeline: %s",
                    ns_error_string(error, "pipeline init failed").c_str());
        return;
    }

    impl_->blue_noise_texture = create_blue_noise_texture(impl_->device);
    if (!impl_->blue_noise_texture) {
        PY_LOG_WARN(TAG, "Failed to create blue-noise texture for thumbnail renderer");
        return;
    }

    impl_->available = true;
}

SeekThumbnailRenderer::~SeekThumbnailRenderer() = default;

bool SeekThumbnailRenderer::is_available() const {
    return impl_ && impl_->available;
}

Error SeekThumbnailRenderer::render_frame(const VideoFrame& frame, int dst_width, int dst_height,
                                         std::vector<uint8_t>& out_bgra) {
    if (!is_available()) {
        return {ErrorCode::RendererError, "Thumbnail renderer unavailable"};
    }
    if (!frame.native_buffer) {
        return {ErrorCode::RendererError, "Video frame has no native pixel buffer"};
    }

    Error texture_err = impl_->ensure_output_texture(dst_width, dst_height);
    if (texture_err) return texture_err;

    CVPixelBufferRef pixel_buffer = static_cast<CVPixelBufferRef>(frame.native_buffer);
    const size_t width = CVPixelBufferGetWidth(pixel_buffer);
    const size_t height = CVPixelBufferGetHeight(pixel_buffer);
    const OSType pix_fmt = CVPixelBufferGetPixelFormatType(pixel_buffer);
    const bool is_10bit = (pix_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                           pix_fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                           pix_fmt == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange);
    const bool is_422 = (pix_fmt == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange ||
                         pix_fmt == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange);

    CVMetalTextureRef y_ref = nullptr;
    CVMetalTextureRef uv_ref = nullptr;
    CVReturn y_ret = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, impl_->texture_cache, pixel_buffer, nullptr,
        is_10bit ? MTLPixelFormatR16Unorm : MTLPixelFormatR8Unorm,
        width, height, 0, &y_ref);
    if (y_ret != kCVReturnSuccess || !y_ref) {
        return {ErrorCode::RendererError, "Failed to create Metal texture for Y plane"};
    }

    const size_t uv_height = is_422 ? height : height / 2;
    CVReturn uv_ret = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, impl_->texture_cache, pixel_buffer, nullptr,
        is_10bit ? MTLPixelFormatRG16Unorm : MTLPixelFormatRG8Unorm,
        width / 2, uv_height, 1, &uv_ref);
    if (uv_ret != kCVReturnSuccess || !uv_ref) {
        if (y_ref) CFRelease(y_ref);
        return {ErrorCode::RendererError, "Failed to create Metal texture for UV plane"};
    }

    id<MTLTexture> y_tex = CVMetalTextureGetTexture(y_ref);
    id<MTLTexture> uv_tex = CVMetalTextureGetTexture(uv_ref);
    if (!y_tex || !uv_tex) {
        CFRelease(y_ref);
        CFRelease(uv_ref);
        return {ErrorCode::RendererError, "Failed to access Metal textures for thumbnail render"};
    }

    VideoUniforms uniforms = build_video_uniforms(frame);
    CropUniforms crop_uniforms;
    ColorFilterUniforms color_filters;
    id<MTLBuffer> reshape_buffer = nil;
    if (uniforms.doviHasReshaping != 0) {
        reshape_buffer = create_reshape_buffer(impl_->device, frame);
        if (!reshape_buffer) {
            uniforms.doviHasReshaping = 0;
        }
    }

    MTLRenderPassDescriptor* pass_desc = [MTLRenderPassDescriptor renderPassDescriptor];
    pass_desc.colorAttachments[0].texture = impl_->output_texture;
    pass_desc.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass_desc.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass_desc.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

    id<MTLCommandBuffer> command_buffer = [impl_->command_queue commandBuffer];
    if (!command_buffer) {
        CFRelease(y_ref);
        CFRelease(uv_ref);
        return {ErrorCode::RendererError, "Failed to create thumbnail command buffer"};
    }

    id<MTLRenderCommandEncoder> encoder =
        [command_buffer renderCommandEncoderWithDescriptor:pass_desc];
    if (!encoder) {
        CFRelease(y_ref);
        CFRelease(uv_ref);
        return {ErrorCode::RendererError, "Failed to create thumbnail render encoder"};
    }

    MTLViewport viewport;
    viewport.originX = 0.0;
    viewport.originY = 0.0;
    viewport.width = static_cast<double>(dst_width);
    viewport.height = static_cast<double>(dst_height);
    viewport.znear = 0.0;
    viewport.zfar = 1.0;
    [encoder setViewport:viewport];
    [encoder setRenderPipelineState:impl_->pipeline_state];
    [encoder setFragmentTexture:y_tex atIndex:0];
    [encoder setFragmentTexture:uv_tex atIndex:1];
    [encoder setFragmentTexture:impl_->blue_noise_texture atIndex:2];
    [encoder setFragmentBytes:&uniforms length:sizeof(VideoUniforms) atIndex:0];
    [encoder setFragmentBytes:&crop_uniforms length:sizeof(CropUniforms) atIndex:1];
    [encoder setFragmentBytes:&color_filters length:sizeof(ColorFilterUniforms) atIndex:2];

    if (reshape_buffer) {
        [encoder setFragmentBuffer:reshape_buffer offset:0 atIndex:3];
    } else {
        float zero = 0.0f;
        [encoder setFragmentBytes:&zero length:sizeof(float) atIndex:3];
    }

    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];

    [command_buffer commit];
    [command_buffer waitUntilCompleted];

    if (command_buffer.status == MTLCommandBufferStatusError) {
        const std::string err = ns_error_string(command_buffer.error, "thumbnail render failed");
        CFRelease(y_ref);
        CFRelease(uv_ref);
        return {ErrorCode::RendererError, err};
    }

    out_bgra.resize(static_cast<size_t>(dst_width * dst_height * 4));
    MTLRegion region = MTLRegionMake2D(
        0, 0,
        static_cast<NSUInteger>(dst_width),
        static_cast<NSUInteger>(dst_height));
    [impl_->output_texture getBytes:out_bgra.data()
                        bytesPerRow:static_cast<NSUInteger>(dst_width * 4)
                         fromRegion:region
                        mipmapLevel:0];

    CFRelease(y_ref);
    CFRelease(uv_ref);
    return Error::Ok();
}

} // namespace py
