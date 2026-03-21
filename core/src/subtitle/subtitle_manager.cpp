#include "testplayer/subtitle_manager.h"
#include "testplayer/logger.h"
#include "srt_parser.h"
#include "ass_renderer.h"
#include "pgs_decoder.h"

#include <mutex>

static constexpr const char* TAG = "SubtitleManager";

namespace tp {

struct SubtitleManager::Impl {
    std::mutex mutex;

    SubtitleFormat active_format = SubtitleFormat::Unknown;

    std::unique_ptr<SrtParser> srt_parser;
    std::unique_ptr<AssRenderer> ass_renderer;
    std::unique_ptr<PgsDecoder> pgs_decoder;

    // Cached PGS frames (bitmap subs are decode-once, display for duration)
    std::vector<SubtitleFrame> pgs_frames;
    int video_width = 1920;
    int video_height = 1080;
};

SubtitleManager::SubtitleManager() : impl_(std::make_unique<Impl>()) {}
SubtitleManager::~SubtitleManager() = default;

Error SubtitleManager::load_external(const std::string& path) {
    std::lock_guard lock(impl_->mutex);

    // Detect format from extension
    std::string ext;
    auto dot = path.rfind('.');
    if (dot != std::string::npos) {
        ext = path.substr(dot + 1);
        for (auto& c : ext) c = static_cast<char>(tolower(c));
    }

    if (ext == "srt") {
        impl_->srt_parser = std::make_unique<SrtParser>();
        if (!impl_->srt_parser->parse_file(path)) {
            return {ErrorCode::SubtitleError, "Failed to parse SRT: " + path};
        }
        impl_->active_format = SubtitleFormat::SRT;
        TP_LOG_INFO(TAG, "Loaded external SRT: %s", path.c_str());
    } else if (ext == "ass" || ext == "ssa") {
        impl_->ass_renderer = std::make_unique<AssRenderer>();
        impl_->ass_renderer->set_video_size(impl_->video_width, impl_->video_height);
        Error err = impl_->ass_renderer->load_file(path);
        if (err) return err;
        impl_->active_format = SubtitleFormat::ASS;
        TP_LOG_INFO(TAG, "Loaded external ASS: %s", path.c_str());
    } else {
        return {ErrorCode::UnsupportedFormat, "Unknown subtitle format: " + ext};
    }

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
            // Embedded SRT: packet data is the text
            if (impl_->srt_parser) {
                std::string text(reinterpret_cast<const char*>(pkt.data.data()), pkt.data.size());
                // Build a mini SRT entry
                // For embedded SRT, each packet is one subtitle event
                impl_->srt_parser->parse_string(
                    "1\n00:00:00,000 --> 99:59:59,999\n" + text);
                // Actually, for embedded SRT we should accumulate entries properly
                // For now, just feed as-is
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
                        impl_->pgs_frames.erase(impl_->pgs_frames.begin());
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
    if (impl_->ass_renderer) impl_->ass_renderer->flush();
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

} // namespace tp
