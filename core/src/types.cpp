#include "plaiy/types.h"

#ifdef __APPLE__
#include <CoreVideo/CoreVideo.h>
#endif

namespace py {

VideoFrame::~VideoFrame() {
    release();
}

VideoFrame::VideoFrame(VideoFrame&& other) noexcept {
    *this = std::move(other);
}

VideoFrame& VideoFrame::operator=(VideoFrame&& other) noexcept {
    if (this != &other) {
        release();

        width = other.width;
        height = other.height;
        pts_us = other.pts_us;
        duration_us = other.duration_us;
        pixel_format = other.pixel_format;
        hdr_metadata = other.hdr_metadata;
        color_space = other.color_space;
        color_primaries = other.color_primaries;
        color_trc = other.color_trc;
        color_range = other.color_range;
        sar_num = other.sar_num;
        sar_den = other.sar_den;
        hdr10plus = other.hdr10plus;
        dovi = other.dovi;
        hardware_frame = other.hardware_frame;
        plane_data = std::move(other.plane_data);

        for (int i = 0; i < 4; i++) {
            planes[i] = other.planes[i];
            strides[i] = other.strides[i];
            other.planes[i] = nullptr;
            other.strides[i] = 0;
        }

        native_buffer = other.native_buffer;
        owns_native_buffer = other.owns_native_buffer;
        other.native_buffer = nullptr;
        other.owns_native_buffer = false;
    }
    return *this;
}

void VideoFrame::release() {
#ifdef __APPLE__
    if (native_buffer && owns_native_buffer) {
        CVPixelBufferRelease(static_cast<CVPixelBufferRef>(native_buffer));
    }
#endif
    native_buffer = nullptr;
    owns_native_buffer = false;
    plane_data.reset();
    for (int i = 0; i < 4; i++) {
        planes[i] = nullptr;
        strides[i] = 0;
    }
}

} // namespace py
