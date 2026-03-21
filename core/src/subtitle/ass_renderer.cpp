#include "ass_renderer.h"
#include "testplayer/logger.h"

#include <ass/ass.h>

static constexpr const char* TAG = "AssRenderer";

namespace tp {

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

    TP_LOG_INFO(TAG, "Loaded ASS file: %s (%d events)", path.c_str(), track_->n_events);
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

    TP_LOG_INFO(TAG, "Loaded embedded ASS track");
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

    if (!img) return frame;

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
            region.rgba_data.resize(img->w * img->h * 4);
            uint8_t r = (img->color >> 24) & 0xFF;
            uint8_t g = (img->color >> 16) & 0xFF;
            uint8_t b = (img->color >> 8) & 0xFF;
            uint8_t a_base = 255 - (img->color & 0xFF);

            for (int y = 0; y < img->h; y++) {
                for (int x = 0; x < img->w; x++) {
                    uint8_t alpha = img->bitmap[y * img->stride + x];
                    uint8_t final_a = static_cast<uint8_t>(
                        (static_cast<int>(alpha) * a_base) / 255);
                    int idx = (y * img->w + x) * 4;
                    region.rgba_data[idx + 0] = r;
                    region.rgba_data[idx + 1] = g;
                    region.rgba_data[idx + 2] = b;
                    region.rgba_data[idx + 3] = final_a;
                }
            }

            frame.regions.push_back(std::move(region));
        }
        img = img->next;
    }

    return frame;
}

void AssRenderer::set_video_size(int width, int height) {
    video_width_ = width;
    video_height_ = height;
    if (renderer_) {
        ass_set_frame_size(renderer_, width, height);
    }
}

void AssRenderer::flush() {
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

} // namespace tp
