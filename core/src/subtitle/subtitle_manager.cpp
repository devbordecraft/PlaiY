#include "plaiy/subtitle_manager.h"
#include "plaiy/logger.h"
#include "srt_parser.h"
#include "ass_renderer.h"
#include "pgs_decoder.h"

#include <deque>
#include <mutex>

static constexpr const char* TAG = "SubtitleManager";

namespace py {

struct SubtitleManager::Impl {
    std::mutex mutex;

    SubtitleFormat active_format = SubtitleFormat::Unknown;

    std::unique_ptr<SrtParser> srt_parser;
    std::unique_ptr<AssRenderer> ass_renderer;
    std::unique_ptr<PgsDecoder> pgs_decoder;

    // Cached PGS frames (bitmap subs are decode-once, display for duration)
    std::deque<SubtitleFrame> pgs_frames;
    int video_width = 1920;
    int video_height = 1080;
    double ass_font_scale = 1.0;
};

SubtitleManager::SubtitleManager() : impl_(std::make_unique<Impl>()) {}
SubtitleManager::~SubtitleManager() = default;

Error SubtitleManager::load_external(const std::string& path) {
    // Detect format from extension (no lock needed)
    std::string ext;
    auto dot = path.rfind('.');
    if (dot != std::string::npos) {
        ext = path.substr(dot + 1);
        for (auto& c : ext) c = static_cast<char>(tolower(c));
    }

    // Parse/load outside the lock to avoid blocking rendering
    if (ext == "srt") {
        auto parser = std::make_unique<SrtParser>();
        if (!parser->parse_file(path)) {
            return {ErrorCode::SubtitleError, "Failed to parse SRT: " + path};
        }
        std::lock_guard lock(impl_->mutex);
        impl_->srt_parser = std::move(parser);
        impl_->active_format = SubtitleFormat::SRT;
    } else if (ext == "ass" || ext == "ssa") {
        int vw, vh;
        double font_scale;
        {
            std::lock_guard lock(impl_->mutex);
            vw = impl_->video_width;
            vh = impl_->video_height;
            font_scale = impl_->ass_font_scale;
        }
        auto renderer = std::make_unique<AssRenderer>();
        renderer->set_video_size(vw, vh);
        renderer->set_font_scale(font_scale);
        Error err = renderer->load_file(path);
        if (err) return err;
        std::lock_guard lock(impl_->mutex);
        impl_->ass_renderer = std::move(renderer);
        impl_->active_format = SubtitleFormat::ASS;
    } else {
        return {ErrorCode::UnsupportedFormat, "Unknown subtitle format: " + ext};
    }

    PY_LOG_INFO(TAG, "Loaded external subtitle: %s", path.c_str());
    return Error::Ok();
}

Error SubtitleManager::set_embedded_track(const TrackInfo& track) {
    std::lock_guard lock(impl_->mutex);

    impl_->active_format = track.subtitle_format;
    impl_->pgs_frames.clear();

    switch (track.subtitle_format) {
        case SubtitleFormat::SRT:
            impl_->srt_parser = std::make_unique<SrtParser>();
            break;

        case SubtitleFormat::ASS: {
            impl_->ass_renderer = std::make_unique<AssRenderer>();
            impl_->ass_renderer->set_video_size(impl_->video_width, impl_->video_height);
            impl_->ass_renderer->set_font_scale(impl_->ass_font_scale);
            if (!track.extradata.empty()) {
                Error err = impl_->ass_renderer->load_embedded(
                    track.extradata.data(), track.extradata.size());
                if (err) return err;
            }
            break;
        }

        case SubtitleFormat::PGS: {
            impl_->pgs_decoder = std::make_unique<PgsDecoder>();
            Error err = impl_->pgs_decoder->open();
            if (err) return err;
            break;
        }

        default:
            return {ErrorCode::UnsupportedFormat, "Unsupported subtitle format"};
    }

    return Error::Ok();
}

void SubtitleManager::feed_packet(const Packet& pkt) {
    std::lock_guard lock(impl_->mutex);

    switch (impl_->active_format) {
        case SubtitleFormat::SRT:
            // Embedded SRT: each packet is one subtitle event with PTS + duration
            if (pkt.data.empty()) break;
            if (impl_->srt_parser) {
                std::string text(reinterpret_cast<const char*>(pkt.data.data()), pkt.data.size());
                int64_t start_us = pkt.pts_us();
                int64_t duration_us = (pkt.duration / pkt.time_base_den) * 1000000LL * pkt.time_base_num
                                    + (pkt.duration % pkt.time_base_den) * 1000000LL * pkt.time_base_num / pkt.time_base_den;
                impl_->srt_parser->add_entry(start_us, start_us + duration_us, text);
            }
            break;

        case SubtitleFormat::ASS:
            if (impl_->ass_renderer) {
                impl_->ass_renderer->feed_packet(pkt);
            }
            break;

        case SubtitleFormat::PGS:
            if (impl_->pgs_decoder) {
                SubtitleFrame frame;
                bool has_output = false;
                impl_->pgs_decoder->decode(pkt, frame, has_output);
                if (has_output) {
                    impl_->pgs_frames.push_back(std::move(frame));
                    // Keep only recent frames (sliding window)
                    while (impl_->pgs_frames.size() > 32) {
                        impl_->pgs_frames.pop_front();
                    }
                }
            }
            break;

        default:
            break;
    }
}

SubtitleFrame SubtitleManager::get_frame_at(int64_t timestamp_us) {
    std::lock_guard lock(impl_->mutex);

    switch (impl_->active_format) {
        case SubtitleFormat::SRT:
            if (impl_->srt_parser) {
                return impl_->srt_parser->get_frame_at(timestamp_us);
            }
            break;

        case SubtitleFormat::ASS:
            if (impl_->ass_renderer) {
                return impl_->ass_renderer->render(timestamp_us);
            }
            break;

        case SubtitleFormat::PGS:
            // Find the active PGS frame
            for (auto it = impl_->pgs_frames.rbegin(); it != impl_->pgs_frames.rend(); ++it) {
                if (timestamp_us >= it->start_us && timestamp_us < it->end_us) {
                    return *it;
                }
            }
            break;

        default:
            break;
    }

    return {};
}

void SubtitleManager::set_ass_font_scale(double scale) {
    std::lock_guard lock(impl_->mutex);
    impl_->ass_font_scale = scale;
    if (impl_->ass_renderer) {
        impl_->ass_renderer->set_font_scale(scale);
    }
}

void SubtitleManager::set_video_size(int width, int height) {
    std::lock_guard lock(impl_->mutex);
    impl_->video_width = width;
    impl_->video_height = height;
    if (impl_->ass_renderer) {
        impl_->ass_renderer->set_video_size(width, height);
    }
}

void SubtitleManager::flush() {
    std::lock_guard lock(impl_->mutex);
    // Clear accumulated embedded SRT entries (they'll be re-fed from the new position)
    if (impl_->srt_parser) impl_->srt_parser->clear();
    // Do NOT flush ASS events: libass renders by timestamp, so existing events
    // remain valid and events spanning the seek point won't be lost.
    if (impl_->pgs_decoder) impl_->pgs_decoder->flush();
    impl_->pgs_frames.clear();
}

void SubtitleManager::close() {
    std::lock_guard lock(impl_->mutex);
    impl_->srt_parser.reset();
    impl_->ass_renderer.reset();
    impl_->pgs_decoder.reset();
    impl_->pgs_frames.clear();
    impl_->active_format = SubtitleFormat::Unknown;
}

} // namespace py
