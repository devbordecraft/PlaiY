#include "ass_renderer.h"
#include "plaiy/logger.h"

#include <ass/ass.h>

static constexpr const char* TAG = "AssRenderer";

namespace py {

AssRenderer::AssRenderer() = default;

AssRenderer::~AssRenderer() {
    close();
}

Error AssRenderer::init() {
    library_ = ass_library_init();
    if (!library_) {
        return {ErrorCode::SubtitleError, "Failed to init libass"};
    }

    renderer_ = ass_renderer_init(library_);
    if (!renderer_) {
        close();
        return {ErrorCode::SubtitleError, "Failed to init ASS renderer"};
    }

    ass_set_frame_size(renderer_, video_width_, video_height_);
    ass_set_font_scale(renderer_, font_scale_);

    // Use system fonts
#ifdef __APPLE__
    ass_set_fonts(renderer_, nullptr, "sans-serif", ASS_FONTPROVIDER_CORETEXT, nullptr, 1);
#else
    ass_set_fonts(renderer_, nullptr, "sans-serif", ASS_FONTPROVIDER_FONTCONFIG, nullptr, 1);
#endif

    return Error::Ok();
}

Error AssRenderer::load_file(const std::string& path) {
    if (!library_) {
        Error err = init();
        if (err) return err;
    }

    if (track_) {
        ass_free_track(track_);
        track_ = nullptr;
    }

    track_ = ass_read_file(library_, path.c_str(), nullptr);
    if (!track_) {
        return {ErrorCode::SubtitleError, "Failed to load ASS file: " + path};
    }

    PY_LOG_INFO(TAG, "Loaded ASS file: %s (%d events)", path.c_str(), track_->n_events);
    return Error::Ok();
}

Error AssRenderer::load_embedded(const uint8_t* header, size_t header_size) {
    if (!library_) {
        Error err = init();
        if (err) return err;
    }

    if (track_) {
        ass_free_track(track_);
        track_ = nullptr;
    }

    track_ = ass_new_track(library_);
    if (!track_) {
        return {ErrorCode::SubtitleError, "Failed to create ASS track"};
    }

    ass_process_codec_private(track_, const_cast<char*>(reinterpret_cast<const char*>(header)),
                               static_cast<int>(header_size));

    PY_LOG_INFO(TAG, "Loaded embedded ASS track");
    return Error::Ok();
}

void AssRenderer::feed_packet(const Packet& pkt) {
    if (!track_) return;

    // ASS embedded packets: the data is a dialogue line
    // PTS and duration are in the packet
    int64_t start_ms = pkt.pts_us() / 1000;
    int64_t duration_ms = pkt.duration * 1000LL * pkt.time_base_num / pkt.time_base_den / 1000;

    ass_process_chunk(track_,
                      const_cast<char*>(reinterpret_cast<const char*>(pkt.data.data())),
                      static_cast<int>(pkt.data.size()),
                      static_cast<long long>(start_ms),
                      static_cast<long long>(duration_ms));
}

SubtitleFrame AssRenderer::render(int64_t timestamp_us) {
    SubtitleFrame frame;
    if (!renderer_ || !track_) return frame;

    int changed = 0;
    ASS_Image* img = ass_render_frame(renderer_, track_,
                                       static_cast<long long>(timestamp_us / 1000),
                                       &changed);

    // Return cached frame when libass reports no change
    if (changed == 0 && cache_valid_) {
        cached_frame_.start_us = timestamp_us;
        return cached_frame_;
    }

    if (!img) {
        cache_valid_ = false;
        return frame;
    }

    frame.start_us = timestamp_us;
    frame.is_text = false;

    // Convert ASS_Image linked list to bitmap regions
    while (img) {
        if (img->w > 0 && img->h > 0) {
            SubtitleFrame::BitmapRegion region;
            region.width = img->w;
            region.height = img->h;
            region.x = img->dst_x;
            region.y = img->dst_y;

            // Convert ASS bitmap (alpha map + color) to RGBA
            int pixel_count = img->w * img->h;
            region.rgba_data.resize(pixel_count * 4);
            uint8_t r = (img->color >> 24) & 0xFF;
            uint8_t g = (img->color >> 16) & 0xFF;
            uint8_t b = (img->color >> 8) & 0xFF;
            uint8_t a_base = 255 - (img->color & 0xFF);

            for (int y = 0; y < img->h; y++) {
                const uint8_t* src_row = img->bitmap + y * img->stride;
                uint8_t* dst_row = region.rgba_data.data() + y * img->w * 4;
                for (int x = 0; x < img->w; x++) {
                    uint8_t final_a = static_cast<uint8_t>(
                        (static_cast<int>(src_row[x]) * a_base) / 255);
                    dst_row[0] = r;
                    dst_row[1] = g;
                    dst_row[2] = b;
                    dst_row[3] = final_a;
                    dst_row += 4;
                }
            }

            frame.regions.push_back(std::move(region));
        }
        img = img->next;
    }

    cached_frame_ = frame;
    cache_valid_ = true;
    return frame;
}

void AssRenderer::set_font_scale(double scale) {
    font_scale_ = scale;
    if (renderer_) {
        ass_set_font_scale(renderer_, scale);
    }
}

void AssRenderer::set_video_size(int width, int height) {
    video_width_ = width;
    video_height_ = height;
    if (renderer_) {
        ass_set_frame_size(renderer_, width, height);
    }
}

void AssRenderer::flush() {
    cache_valid_ = false;
    if (track_) {
        ass_flush_events(track_);
    }
}

void AssRenderer::close() {
    if (track_) {
        ass_free_track(track_);
        track_ = nullptr;
    }
    if (renderer_) {
        ass_renderer_done(renderer_);
        renderer_ = nullptr;
    }
    if (library_) {
        ass_library_done(library_);
        library_ = nullptr;
    }
}

} // namespace py
