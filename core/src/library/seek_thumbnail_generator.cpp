#include "seek_thumbnail_generator.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libswscale/swscale.h>
#include <libavutil/imgutils.h>
}

#include <cstdio>
#include <sys/stat.h>
#include <filesystem>

static constexpr const char* TAG = "SeekThumb";
static constexpr int THUMB_MAX_WIDTH = 320;
static constexpr int THUMB_MAX_HEIGHT = 180;

namespace py {

SeekThumbnailGenerator::SeekThumbnailGenerator() = default;

SeekThumbnailGenerator::~SeekThumbnailGenerator() {
    cancel();
}

void SeekThumbnailGenerator::start(const std::string& video_path,
                                    const std::string& cache_dir,
                                    int interval_seconds) {
    cancel(); // stop any previous generation

    cancel_flag_.store(false);
    progress_.store(0);
    generated_count_.store(0);
    total_count_.store(0);
    interval_seconds_ = interval_seconds;
    cache_dir_ = cache_dir;

    // Create cache directory
    std::filesystem::create_directories(cache_dir);

    worker_ = std::thread(&SeekThumbnailGenerator::generate_loop, this,
                           video_path, cache_dir, interval_seconds);
}

void SeekThumbnailGenerator::cancel() {
    cancel_flag_.store(true);
    if (worker_.joinable()) {
        worker_.join();
    }
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

    // Build path
    char filename[64];
    snprintf(filename, sizeof(filename), "thumb_%04d.jpg", index);
    std::string path = cache_dir_ + "/" + filename;

    // Read JPEG file
    FILE* f = fopen(path.c_str(), "rb");
    if (!f) return false;

    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);

    std::vector<uint8_t> jpeg_data(size);
    fread(jpeg_data.data(), 1, size, f);
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
    pkt->data = jpeg_data.data();
    pkt->size = static_cast<int>(jpeg_data.size());

    int ret = avcodec_send_packet(dec, pkt);
    av_packet_free(&pkt);
    if (ret < 0) {
        avcodec_free_context(&dec);
        return false;
    }

    AVFrame* frame = av_frame_alloc();
    ret = avcodec_receive_frame(dec, frame);
    if (ret < 0) {
        av_frame_free(&frame);
        avcodec_free_context(&dec);
        return false;
    }

    int w = frame->width;
    int h = frame->height;

    // Convert to BGRA
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
    std::vector<uint8_t> bgra(bgra_stride * h);
    uint8_t* dst_data[1] = { bgra.data() };
    int dst_linesize[1] = { bgra_stride };

    sws_scale(sws, frame->data, frame->linesize, 0, h, dst_data, dst_linesize);
    sws_freeContext(sws);
    av_frame_free(&frame);
    avcodec_free_context(&dec);

    std::lock_guard<std::mutex> lock(data_mutex_);
    last_bgra_data_ = std::move(bgra);
    thumb_width_ = w;
    thumb_height_ = h;

    *out_data = last_bgra_data_.data();
    *out_width = w;
    *out_height = h;
    return true;
}

void SeekThumbnailGenerator::generate_loop(std::string video_path,
                                            std::string cache_dir,
                                            int interval_seconds) {
    AVFormatContext* fmt = nullptr;
    int ret = avformat_open_input(&fmt, video_path.c_str(), nullptr, nullptr);
    if (ret < 0) {
        PY_LOG_ERROR(TAG, "failed to open: %s", video_path.c_str());
        return;
    }

    ret = avformat_find_stream_info(fmt, nullptr);
    if (ret < 0) {
        avformat_close_input(&fmt);
        return;
    }

    int video_idx = av_find_best_stream(fmt, AVMEDIA_TYPE_VIDEO, -1, -1, nullptr, 0);
    if (video_idx < 0) {
        avformat_close_input(&fmt);
        return;
    }

    AVStream* stream = fmt->streams[video_idx];
    AVCodecParameters* par = stream->codecpar;

    const AVCodec* codec = avcodec_find_decoder(par->codec_id);
    if (!codec) {
        avformat_close_input(&fmt);
        return;
    }

    AVCodecContext* dec = avcodec_alloc_context3(codec);
    if (!dec) {
        avformat_close_input(&fmt);
        return;
    }

    avcodec_parameters_to_context(dec, par);
    dec->thread_count = 2;

    ret = avcodec_open2(dec, codec, nullptr);
    if (ret < 0) {
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        return;
    }

    // Calculate thumbnail dimensions
    int src_w = par->width;
    int src_h = par->height;
    double scale = std::min(static_cast<double>(THUMB_MAX_WIDTH) / src_w,
                            static_cast<double>(THUMB_MAX_HEIGHT) / src_h);
    if (scale > 1.0) scale = 1.0;
    int dst_w = static_cast<int>(src_w * scale) & ~1;
    int dst_h = static_cast<int>(src_h * scale) & ~1;
    if (dst_w < 2) dst_w = 2;
    if (dst_h < 2) dst_h = 2;

    // Scaler for video frame -> JPEG-compatible YUV
    SwsContext* sws = sws_getContext(
        src_w, src_h, static_cast<AVPixelFormat>(par->format),
        dst_w, dst_h, AV_PIX_FMT_YUVJ420P,
        SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);

    // JPEG encoder
    const AVCodec* mjpeg = avcodec_find_encoder(AV_CODEC_ID_MJPEG);
    AVCodecContext* enc = nullptr;
    if (mjpeg) {
        enc = avcodec_alloc_context3(mjpeg);
        enc->pix_fmt = AV_PIX_FMT_YUVJ420P;
        enc->width = dst_w;
        enc->height = dst_h;
        enc->time_base = {1, 1};
        enc->qmin = 2;
        enc->qmax = 8;
        if (avcodec_open2(enc, mjpeg, nullptr) < 0) {
            avcodec_free_context(&enc);
            enc = nullptr;
        }
    }

    if (!sws || !enc) {
        PY_LOG_ERROR(TAG, "failed to init scaler or encoder");
        if (sws) sws_freeContext(sws);
        if (enc) avcodec_free_context(&enc);
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        return;
    }

    int64_t duration_sec = (fmt->duration > 0) ? (fmt->duration / AV_TIME_BASE) : 0;
    int total = (duration_sec > 0) ? static_cast<int>(duration_sec / interval_seconds) + 1 : 0;
    if (total <= 0) {
        sws_freeContext(sws);
        avcodec_free_context(&enc);
        avcodec_free_context(&dec);
        avformat_close_input(&fmt);
        return;
    }

    total_count_.store(total);
    PY_LOG_INFO(TAG, "generating %d thumbnails (%dx%d) at %ds intervals for %s",
                total, dst_w, dst_h, interval_seconds, video_path.c_str());

    AVFrame* frame = av_frame_alloc();
    AVFrame* scaled = av_frame_alloc();
    scaled->format = AV_PIX_FMT_YUVJ420P;
    scaled->width = dst_w;
    scaled->height = dst_h;
    av_frame_get_buffer(scaled, 0);

    AVPacket* pkt = av_packet_alloc();

    for (int i = 0; i < total && !cancel_flag_.load(); i++) {
        int64_t target_ts = static_cast<int64_t>(i) * interval_seconds * AV_TIME_BASE;
        av_seek_frame(fmt, -1, target_ts, AVSEEK_FLAG_BACKWARD);
        avcodec_flush_buffers(dec);

        // Decode one frame
        bool got_frame = false;
        int attempts = 0;
        while (!got_frame && attempts < 60 && !cancel_flag_.load()) {
            ret = av_read_frame(fmt, pkt);
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

        // Scale
        sws_scale(sws, frame->data, frame->linesize, 0, frame->height,
                  scaled->data, scaled->linesize);

        // Encode to JPEG
        ret = avcodec_send_frame(enc, scaled);
        if (ret < 0) continue;

        AVPacket* enc_pkt = av_packet_alloc();
        ret = avcodec_receive_packet(enc, enc_pkt);
        if (ret == 0) {
            char filename[64];
            snprintf(filename, sizeof(filename), "thumb_%04d.jpg", i);
            std::string path = cache_dir + "/" + filename;

            FILE* f = fopen(path.c_str(), "wb");
            if (f) {
                fwrite(enc_pkt->data, 1, enc_pkt->size, f);
                fclose(f);
            }
        }
        av_packet_free(&enc_pkt);

        generated_count_.store(i + 1);
        progress_.store(static_cast<int>(100.0 * (i + 1) / total));
    }

    av_frame_free(&frame);
    av_frame_free(&scaled);
    av_packet_free(&pkt);
    sws_freeContext(sws);
    avcodec_free_context(&enc);
    avcodec_free_context(&dec);
    avformat_close_input(&fmt);

    if (!cancel_flag_.load()) {
        progress_.store(100);
        PY_LOG_INFO(TAG, "finished: %d thumbnails generated", generated_count_.load());
    }
}

} // namespace py
