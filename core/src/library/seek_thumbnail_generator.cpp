#include "seek_thumbnail_generator.h"
#include "demuxer/ff_demuxer.h"
#include "ffmpeg_video_opener.h"
#include "plaiy/logger.h"
#include "video/video_decoder_factory.h"

#ifdef __APPLE__
#include "seek_thumbnail_renderer.h"
#endif

extern "C" {
#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
}

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <sys/stat.h>
#include <vector>

static constexpr const char* TAG = "SeekThumb";
static constexpr int THUMB_MAX_WIDTH = 320;
static constexpr int THUMB_MAX_HEIGHT = 180;

namespace py {

namespace {

struct ThumbnailDimensions {
    int src_w = 0;
    int src_h = 0;
    int dst_w = 0;
    int dst_h = 0;
};

ThumbnailDimensions calculate_thumbnail_dimensions(int src_w, int src_h) {
    ThumbnailDimensions dims;
    dims.src_w = src_w;
    dims.src_h = src_h;
    if (src_w <= 0 || src_h <= 0) {
        return dims;
    }

    double scale = std::min(static_cast<double>(THUMB_MAX_WIDTH) / static_cast<double>(src_w),
                            static_cast<double>(THUMB_MAX_HEIGHT) / static_cast<double>(src_h));
    if (scale > 1.0) scale = 1.0;

    dims.dst_w = static_cast<int>(src_w * scale) & ~1;
    dims.dst_h = static_cast<int>(src_h * scale) & ~1;
    if (dims.dst_w < 2) dims.dst_w = 2;
    if (dims.dst_h < 2) dims.dst_h = 2;
    return dims;
}

std::string thumbnail_path_for_index(const std::string& cache_dir, int index) {
    char filename[64];
    snprintf(filename, sizeof(filename), "thumb_%04d.jpg", index);
    return cache_dir + "/" + filename;
}

AVCodecContext* create_jpeg_encoder(int width, int height) {
    const AVCodec* mjpeg = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
    if (!mjpeg) return nullptr;

    AVCodecContext* enc = avcodec_alloc_context3(mjpeg);
    if (!enc) return nullptr;

    enc->pix_fmt = AV_PIX_FMT_YUVJ420P;
    enc->width = width;
    enc->height = height;
    enc->time_base = {1, 1};
    enc->qmin = 2;
    enc->qmax = 8;

    if (avcodec_open2(enc, mjpeg, nullptr) < 0) {
        avcodec_free_context(&enc);
        return nullptr;
    }

    return enc;
}

bool write_encoded_jpeg(AVCodecContext* enc, AVFrame* frame, const std::string& path) {
    if (!enc || !frame) return false;

    int ret = avcodec_send_frame(enc, frame);
    if (ret < 0) return false;

    AVPacket* enc_pkt = av_packet_alloc();
    if (!enc_pkt) return false;

    bool wrote = false;
    ret = avcodec_receive_packet(enc, enc_pkt);
    if (ret == 0) {
        FILE* f = fopen(path.c_str(), "wb");
        if (f) {
            fwrite(enc_pkt->data, 1, static_cast<size_t>(enc_pkt->size), f);
            fclose(f);
            wrote = true;
        }
    }

    av_packet_free(&enc_pkt);
    return wrote;
}

} // namespace

SeekThumbnailGenerator::SeekThumbnailGenerator() = default;

SeekThumbnailGenerator::~SeekThumbnailGenerator() {
    cancel();
}

SeekThumbnailGenerator::ThumbnailMode SeekThumbnailGenerator::select_mode(const TrackInfo& track) {
#ifdef __APPLE__
    if (track.type == MediaType::Video &&
        track.hdr_metadata.type == HDRType::DolbyVision &&
        track.dv_profile == 5) {
        return ThumbnailMode::CustomMetalP5;
    }
#else
    (void)track;
#endif
    return ThumbnailMode::LegacySwscale;
}

void SeekThumbnailGenerator::start(const std::string& video_path,
                                   const std::string& cache_dir,
                                   int interval_seconds,
                                   const TrackInfo* video_track) {
    cancel(); // stop any previous generation

    cancel_flag_.store(false);
    progress_.store(0);
    generated_count_.store(0);
    total_count_.store(0);
    interval_seconds_ = interval_seconds;
    cache_dir_ = cache_dir;
    mode_ = video_track ? select_mode(*video_track) : ThumbnailMode::LegacySwscale;
    {
        std::lock_guard<std::mutex> lock(data_mutex_);
        last_index_ = -1;
        decoded_lru_.clear();
        decoded_cache_.clear();
    }

    // Create cache directory
    std::error_code ec;
    std::filesystem::create_directories(cache_dir, ec);
    if (ec) {
        PY_LOG_WARN(TAG, "Failed to create thumbnail cache dir %s: %s",
                    cache_dir.c_str(), ec.message().c_str());
        return;
    }

    if (mode_ == ThumbnailMode::CustomMetalP5) {
        PY_LOG_INFO(TAG, "DV Profile 5: seek thumbnails will use the custom Metal render pipeline");
    }

    worker_ = std::thread(&SeekThumbnailGenerator::generate_loop, this,
                          video_path, cache_dir, interval_seconds);
}

void SeekThumbnailGenerator::cancel() {
    cancel_flag_.store(true);
    if (worker_.joinable()) {
        worker_.join();
    }
}

bool SeekThumbnailGenerator::try_get_cached_thumbnail(int index,
                                                      const uint8_t** out_data,
                                                      int* out_width,
                                                      int* out_height) {
    auto it = decoded_cache_.find(index);
    if (it == decoded_cache_.end()) return false;

    decoded_lru_.erase(it->second.lru_it);
    decoded_lru_.push_front(index);
    it->second.lru_it = decoded_lru_.begin();
    last_index_ = index;

    *out_data = it->second.thumbnail.bgra.data();
    *out_width = it->second.thumbnail.width;
    *out_height = it->second.thumbnail.height;
    return true;
}

void SeekThumbnailGenerator::store_decoded_thumbnail(int index, DecodedThumbnail thumbnail) {
    auto existing = decoded_cache_.find(index);
    if (existing != decoded_cache_.end()) {
        decoded_lru_.erase(existing->second.lru_it);
        decoded_cache_.erase(existing);
    }

    decoded_lru_.push_front(index);
    decoded_cache_.emplace(index, DecodedThumbnailEntry{
        .thumbnail = std::move(thumbnail),
        .lru_it = decoded_lru_.begin(),
    });

    while (decoded_cache_.size() > DECODED_CACHE_CAPACITY) {
        int evict_index = decoded_lru_.back();
        decoded_lru_.pop_back();
        decoded_cache_.erase(evict_index);
    }
    last_index_ = index;
}

bool SeekThumbnailGenerator::get_thumbnail(int64_t timestamp_us, int64_t duration_us,
                                           const uint8_t** out_data,
                                           int* out_width, int* out_height) {
    if (generated_count_.load() == 0 || interval_seconds_ <= 0 || duration_us <= 0)
        return false;

    int index = static_cast<int>((timestamp_us / 1000000) / interval_seconds_);
    int max_index = generated_count_.load() - 1;
    if (index > max_index) index = max_index;
    if (index < 0) index = 0;

    {
        std::lock_guard<std::mutex> lock(data_mutex_);
        if (try_get_cached_thumbnail(index, out_data, out_width, out_height)) {
            return true;
        }
    }

    const std::string path = thumbnail_path_for_index(cache_dir_, index);

    // Read JPEG file
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    std::vector<uint8_t> jpeg_data(static_cast<size_t>(size));
    fread(jpeg_data.data(), 1, static_cast<size_t>(size), f);
    fclose(f);

    // Decode JPEG to BGRA using FFmpeg
    const AVCodec* mjpeg_dec = avcodec_find_decoder(AV_CODEC_ID_MJPEG);
    if (!mjpeg_dec) return false;

    AVCodecContext* dec = avcodec_alloc_context3(mjpeg_dec);
    if (!dec) return false;

    if (avcodec_open2(dec, mjpeg_dec, nullptr) < 0) {
        avcodec_free_context(&dec);
        return false;
    }

    AVPacket* pkt = av_packet_alloc();
    if (!pkt) {
        avcodec_free_context(&dec);
        return false;
    }
    pkt->data = jpeg_data.data();
    pkt->size = static_cast<int>(jpeg_data.size());

    int ret = avcodec_send_packet(dec, pkt);
    av_packet_free(&pkt);
    if (ret < 0) {
        avcodec_free_context(&dec);
        return false;
    }

    AVFrame* frame = av_frame_alloc();
    if (!frame) {
        avcodec_free_context(&dec);
        return false;
    }
    ret = avcodec_receive_frame(dec, frame);
    if (ret < 0) {
        av_frame_free(&frame);
        avcodec_free_context(&dec);
        return false;
    }

    int w = frame->width;
    int h = frame->height;

    SwsContext* sws = sws_getContext(
        w, h, static_cast<AVPixelFormat>(frame->format),
        w, h, AV_PIX_FMT_BGRA,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);

    if (!sws) {
        av_frame_free(&frame);
        avcodec_free_context(&dec);
        return false;
    }

    int bgra_stride = w * 4;
    std::vector<uint8_t> bgra(static_cast<size_t>(bgra_stride) * static_cast<size_t>(h));
    uint8_t* dst_data[1] = { bgra.data() };
    int dst_linesize[1] = { bgra_stride };

    sws_scale(sws, frame->data, frame->linesize, 0, h, dst_data, dst_linesize);
    sws_freeContext(sws);
    av_frame_free(&frame);
    avcodec_free_context(&dec);

    {
        std::lock_guard<std::mutex> lock(data_mutex_);
        store_decoded_thumbnail(index, DecodedThumbnail{
            .width = w,
            .height = h,
            .bgra = std::move(bgra),
        });
        auto it = decoded_cache_.find(index);
        if (it == decoded_cache_.end()) return false;

        *out_data = it->second.thumbnail.bgra.data();
        *out_width = it->second.thumbnail.width;
        *out_height = it->second.thumbnail.height;
    }
    return true;
}

void SeekThumbnailGenerator::generate_loop(std::string video_path,
                                           std::string cache_dir,
                                           int interval_seconds) {
    bool used_custom_path = false;
    if (mode_ == ThumbnailMode::CustomMetalP5) {
        used_custom_path = generate_custom_p5_thumbnails(video_path, cache_dir, interval_seconds);
        if (!used_custom_path && !cancel_flag_.load()) {
            PY_LOG_WARN(TAG, "DV Profile 5 custom thumbnail renderer unavailable, falling back to legacy path");
        }
    }

    if (!used_custom_path && !cancel_flag_.load()) {
        generate_legacy_thumbnails(video_path, cache_dir, interval_seconds);
    }

    if (!cancel_flag_.load()) {
        progress_.store(100);
        PY_LOG_INFO(TAG, "finished: %d thumbnails generated", generated_count_.load());
    }
}

bool SeekThumbnailGenerator::generate_legacy_thumbnails(const std::string& video_path,
                                                        const std::string& cache_dir,
                                                        int interval_seconds) {
    FFmpegVideoOpener opener;
    if (!opener.open(video_path)) {
        return false;
    }

    AVFormatContext* fmt = opener.fmt;
    AVCodecContext* dec = opener.dec;
    int video_idx = opener.stream_index;
    if (!fmt || !dec || video_idx < 0 || video_idx >= static_cast<int>(fmt->nb_streams)) {
        return false;
    }

    AVCodecParameters* par = fmt->streams[video_idx]->codecpar;
    ThumbnailDimensions dims = calculate_thumbnail_dimensions(par->width, par->height);
    if (dims.dst_w <= 0 || dims.dst_h <= 0) {
        return false;
    }

    SwsContext* sws = sws_getContext(
        dims.src_w, dims.src_h, static_cast<AVPixelFormat>(par->format),
        dims.dst_w, dims.dst_h, AV_PIX_FMT_YUVJ420P,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
    AVCodecContext* enc = create_jpeg_encoder(dims.dst_w, dims.dst_h);

    if (!sws || !enc) {
        PY_LOG_ERROR(TAG, "failed to init legacy thumbnail scaler or encoder");
        if (sws) sws_freeContext(sws);
        if (enc) avcodec_free_context(&enc);
        return false;
    }

    int64_t duration_sec = (fmt->duration > 0) ? (fmt->duration / AV_TIME_BASE) : 0;
    int total = (duration_sec > 0) ? static_cast<int>(duration_sec / interval_seconds) + 1 : 0;
    if (total <= 0) {
        sws_freeContext(sws);
        avcodec_free_context(&enc);
        return false;
    }

    total_count_.store(total);
    PY_LOG_INFO(TAG, "generating %d legacy thumbnails (%dx%d) at %ds intervals for %s",
                total, dims.dst_w, dims.dst_h, interval_seconds, video_path.c_str());

    AVFrame* frame = av_frame_alloc();
    AVFrame* scaled = av_frame_alloc();
    AVPacket* pkt = av_packet_alloc();
    if (!frame || !scaled || !pkt) {
        av_frame_free(&frame);
        av_frame_free(&scaled);
        av_packet_free(&pkt);
        sws_freeContext(sws);
        avcodec_free_context(&enc);
        return false;
    }

    scaled->format = AV_PIX_FMT_YUVJ420P;
    scaled->width = dims.dst_w;
    scaled->height = dims.dst_h;
    av_frame_get_buffer(scaled, 0);

    for (int i = 0; i < total && !cancel_flag_.load(); i++) {
        int64_t target_ts = static_cast<int64_t>(i) * interval_seconds * AV_TIME_BASE;
        av_seek_frame(fmt, -1, target_ts, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(dec);

        bool got_frame = false;
        int attempts = 0;
        while (!got_frame && attempts < 60 && !cancel_flag_.load()) {
            int ret = av_read_frame(fmt, pkt);
            if (ret < 0) break;

            if (pkt->stream_index != video_idx) {
                av_packet_unref(pkt);
                attempts++;
                continue;
            }

            ret = avcodec_send_packet(dec, pkt);
            av_packet_unref(pkt);
            if (ret < 0) {
                attempts++;
                continue;
            }

            ret = avcodec_receive_frame(dec, frame);
            if (ret == 0) {
                got_frame = true;
            }
            attempts++;
        }

        if (!got_frame) continue;

        av_frame_make_writable(scaled);
        sws_scale(sws, frame->data, frame->linesize, 0, frame->height,
                  scaled->data, scaled->linesize);

        write_encoded_jpeg(enc, scaled, thumbnail_path_for_index(cache_dir, i));

        generated_count_.store(i + 1);
        progress_.store(static_cast<int>(100.0 * static_cast<double>(i + 1) / static_cast<double>(total)));
    }

    av_frame_free(&frame);
    av_frame_free(&scaled);
    av_packet_free(&pkt);
    sws_freeContext(sws);
    avcodec_free_context(&enc);
    return true;
}

bool SeekThumbnailGenerator::generate_custom_p5_thumbnails(const std::string& video_path,
                                                           const std::string& cache_dir,
                                                           int interval_seconds) {
#ifndef __APPLE__
    (void)video_path;
    (void)cache_dir;
    (void)interval_seconds;
    return false;
#else
    FFDemuxer demuxer;
    Error demux_err = demuxer.open(video_path);
    if (demux_err) {
        PY_LOG_WARN(TAG, "DV Profile 5 thumbnail demuxer open failed: %s", demux_err.message.c_str());
        return false;
    }

    const MediaInfo& info = demuxer.media_info();
    if (info.best_video_index < 0 ||
        info.best_video_index >= static_cast<int>(info.tracks.size())) {
        return false;
    }

    const TrackInfo& track = info.tracks[static_cast<size_t>(info.best_video_index)];
    ThumbnailDimensions dims = calculate_thumbnail_dimensions(track.width, track.height);
    if (dims.dst_w <= 0 || dims.dst_h <= 0) {
        return false;
    }

    auto decoder = VideoDecoderFactory::create(track, HWDecodePreference::ForceSoftware);
    if (!decoder) {
        PY_LOG_WARN(TAG, "DV Profile 5 thumbnail decoder unavailable");
        return false;
    }

    SeekThumbnailRenderer renderer;
    if (!renderer.is_available()) {
        return false;
    }

    SwsContext* bgra_to_jpeg = sws_getContext(
        dims.dst_w, dims.dst_h, AV_PIX_FMT_BGRA,
        dims.dst_w, dims.dst_h, AV_PIX_FMT_YUVJ420P,
        SWS_BILINEAR, nullptr, nullptr, nullptr);
    AVCodecContext* enc = create_jpeg_encoder(dims.dst_w, dims.dst_h);
    AVFrame* yuv = av_frame_alloc();
    if (!bgra_to_jpeg || !enc || !yuv) {
        if (bgra_to_jpeg) sws_freeContext(bgra_to_jpeg);
        if (enc) avcodec_free_context(&enc);
        av_frame_free(&yuv);
        return false;
    }

    yuv->format = AV_PIX_FMT_YUVJ420P;
    yuv->width = dims.dst_w;
    yuv->height = dims.dst_h;
    if (av_frame_get_buffer(yuv, 0) < 0) {
        sws_freeContext(bgra_to_jpeg);
        avcodec_free_context(&enc);
        av_frame_free(&yuv);
        return false;
    }

    int total = (info.duration_us > 0)
        ? static_cast<int>((info.duration_us / 1000000) / interval_seconds) + 1
        : 0;
    if (total <= 0) {
        sws_freeContext(bgra_to_jpeg);
        avcodec_free_context(&enc);
        av_frame_free(&yuv);
        return false;
    }

    total_count_.store(total);
    PY_LOG_INFO(TAG, "generating %d DV Profile 5 thumbnails via custom Metal renderer (%dx%d) at %ds intervals for %s",
                total, dims.dst_w, dims.dst_h, interval_seconds, video_path.c_str());

    for (int i = 0; i < total && !cancel_flag_.load(); i++) {
        const int64_t target_us = static_cast<int64_t>(i) * interval_seconds * 1000000LL;
        Error seek_err = demuxer.seek(target_us);
        if (seek_err) continue;

        decoder->flush();

        bool got_frame = false;
        int attempts = 0;
        std::vector<uint8_t> bgra;

        while (!got_frame && attempts < 120 && !cancel_flag_.load()) {
            Packet pkt;
            Error read_err = demuxer.read_packet(pkt);
            if (read_err.code == ErrorCode::EndOfFile) break;
            if (read_err) {
                attempts++;
                continue;
            }

            if (pkt.stream_index != track.stream_index) {
                attempts++;
                continue;
            }

            Error send_err = decoder->send_packet(pkt);
            if (send_err && send_err.code != ErrorCode::NeedMoreInput) {
                attempts++;
                continue;
            }

            for (;;) {
                VideoFrame frame;
                Error recv_err = decoder->receive_frame(frame);
                if (recv_err.code == ErrorCode::OutputNotReady) break;
                if (recv_err) break;

                Error render_err = renderer.render_frame(frame, dims.dst_w, dims.dst_h, bgra);
                if (!render_err) {
                    got_frame = true;
                } else {
                    PY_LOG_WARN(TAG, "DV Profile 5 thumbnail render failed at %lldus: %s",
                                static_cast<long long>(target_us), render_err.message.c_str());
                }
                break;
            }

            attempts++;
        }

        if (!got_frame || bgra.empty()) continue;

        av_frame_make_writable(yuv);
        uint8_t* src_data[1] = { bgra.data() };
        int src_linesize[1] = { dims.dst_w * 4 };
        sws_scale(bgra_to_jpeg, src_data, src_linesize, 0, dims.dst_h,
                  yuv->data, yuv->linesize);

        write_encoded_jpeg(enc, yuv, thumbnail_path_for_index(cache_dir, i));

        generated_count_.store(i + 1);
        progress_.store(static_cast<int>(100.0 * static_cast<double>(i + 1) / static_cast<double>(total)));
    }

    sws_freeContext(bgra_to_jpeg);
    avcodec_free_context(&enc);
    av_frame_free(&yuv);
    return true;
#endif
}

} // namespace py
