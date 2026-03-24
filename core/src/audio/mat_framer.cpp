#include "mat_framer.h"
#include "plaiy/logger.h"

extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
}

static constexpr const char* TAG = "MATFramer";

namespace py {

struct MATFramer::Impl {
    AVFormatContext* fmt_ctx = nullptr;
    AVIOContext* avio_ctx = nullptr;
    AVStream* stream = nullptr;
    uint8_t* avio_buffer = nullptr;
    bool header_written = false;

    // Buffer to accumulate muxer output
    std::vector<uint8_t> output_buf;

    static int write_packet(void* opaque, const uint8_t* buf, int buf_size) {
        auto* self = static_cast<Impl*>(opaque);
        self->output_buf.insert(self->output_buf.end(), buf, buf + buf_size);
        return buf_size;
    }
};

MATFramer::MATFramer() : impl_(std::make_unique<Impl>()) {}

MATFramer::~MATFramer() {
    close();
}

Error MATFramer::open(int codec_id, int sample_rate, int channels) {
    close();

    // Allocate output format context for spdif muxer
    int ret = avformat_alloc_output_context2(&impl_->fmt_ctx, nullptr, "spdif", nullptr);
    if (ret < 0 || !impl_->fmt_ctx) {
        return {ErrorCode::AudioOutputError, "Failed to create spdif muxer context"};
    }

    // Create in-memory I/O context
    static constexpr int AVIO_BUF_SIZE = 65536;
    impl_->avio_buffer = static_cast<uint8_t*>(av_malloc(AVIO_BUF_SIZE));
    if (!impl_->avio_buffer) {
        close();
        return {ErrorCode::OutOfMemory, "Failed to allocate AVIO buffer"};
    }

    impl_->avio_ctx = avio_alloc_context(
        impl_->avio_buffer, AVIO_BUF_SIZE,
        1,  // write flag
        impl_.get(),
        nullptr,  // read_packet
        Impl::write_packet,
        nullptr   // seek
    );
    if (!impl_->avio_ctx) {
        // avio_buffer is freed by close() via fmt_ctx or manually
        close();
        return {ErrorCode::OutOfMemory, "Failed to allocate AVIO context"};
    }

    impl_->fmt_ctx->pb = impl_->avio_ctx;
    impl_->fmt_ctx->flags |= AVFMT_FLAG_CUSTOM_IO;

    // Add a stream matching the TrueHD codec
    impl_->stream = avformat_new_stream(impl_->fmt_ctx, nullptr);
    if (!impl_->stream) {
        close();
        return {ErrorCode::AudioOutputError, "Failed to create spdif stream"};
    }

    impl_->stream->codecpar->codec_type = AVMEDIA_TYPE_AUDIO;
    impl_->stream->codecpar->codec_id = static_cast<AVCodecID>(codec_id);
    impl_->stream->codecpar->sample_rate = sample_rate;
    impl_->stream->codecpar->ch_layout.nb_channels = channels;

    ret = avformat_write_header(impl_->fmt_ctx, nullptr);
    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        PY_LOG_ERROR(TAG, "Failed to write spdif header: %s", errbuf);
        close();
        return {ErrorCode::AudioOutputError, "Failed to write spdif header"};
    }

    impl_->header_written = true;
    impl_->output_buf.clear();  // Discard any header output

    PY_LOG_INFO(TAG, "MAT framer opened: codec_id=%d, %d Hz, %d ch",
                codec_id, sample_rate, channels);
    return Error::Ok();
}

void MATFramer::close() {
    if (impl_->fmt_ctx && impl_->header_written) {
        av_write_trailer(impl_->fmt_ctx);
        impl_->header_written = false;
    }
    if (impl_->fmt_ctx) {
        // Don't free avio_buffer separately — avio_context_free handles it
        if (impl_->avio_ctx) {
            // Prevent avformat_free_context from freeing our custom pb
            impl_->fmt_ctx->pb = nullptr;
        }
        avformat_free_context(impl_->fmt_ctx);
        impl_->fmt_ctx = nullptr;
        impl_->stream = nullptr;
    }
    if (impl_->avio_ctx) {
        av_freep(&impl_->avio_ctx->buffer);
        avio_context_free(&impl_->avio_ctx);
        impl_->avio_buffer = nullptr;
    }
    impl_->output_buf.clear();
}

Error MATFramer::frame_packet(const uint8_t* data, size_t size, int64_t pts,
                               std::vector<uint8_t>& out) {
    if (!impl_->fmt_ctx || !impl_->header_written) {
        return {ErrorCode::InvalidState, "MAT framer not open"};
    }

    out.clear();
    impl_->output_buf.clear();

    AVPacket* pkt = av_packet_alloc();
    if (!pkt) {
        return {ErrorCode::OutOfMemory, "Failed to allocate packet"};
    }

    pkt->data = const_cast<uint8_t*>(data);
    pkt->size = static_cast<int>(size);
    pkt->pts = pts;
    pkt->dts = pts;
    pkt->stream_index = 0;

    int ret = av_write_frame(impl_->fmt_ctx, pkt);
    av_packet_free(&pkt);

    if (ret < 0) {
        char errbuf[256];
        av_strerror(ret, errbuf, sizeof(errbuf));
        PY_LOG_WARN(TAG, "Failed to write frame to spdif muxer: %s", errbuf);
        return {ErrorCode::AudioOutputError, "MAT framing failed"};
    }

    // Swap output buffer to caller
    out.swap(impl_->output_buf);
    impl_->output_buf.clear();

    return Error::Ok();
}

} // namespace py
