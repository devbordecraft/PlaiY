#pragma once

#include "plaiy/demuxer.h"
#include <atomic>

struct AVFormatContext;
struct AVPacket;

namespace py {

struct RemoteBufferConfig {
    RemoteSourceKind source_kind = RemoteSourceKind::None;
    RemoteBufferMode mode = RemoteBufferMode::Off;
    RemoteBufferProfile profile = RemoteBufferProfile::Balanced;
};

class FFDemuxer : public IDemuxer {
public:
    FFDemuxer();
    ~FFDemuxer() override;

    Error open(const std::string& path) override;
    void close() override;
    const MediaInfo& media_info() const override;
    Error read_packet(Packet& out) override;
    Error seek(int64_t timestamp_us) override;
    void set_remote_buffer_config(RemoteBufferConfig config);
    void request_abort();

private:
    void populate_media_info();
    static int interrupt_callback(void* opaque);
    std::string buffered_open_path_for(const std::string& path) const;
    static PixelFormat convert_pixel_format(int ff_format);
    static SubtitleFormat detect_subtitle_format(int codec_id);

    AVFormatContext* fmt_ctx_ = nullptr;
    AVPacket* reuse_pkt_ = nullptr;
    MediaInfo info_;
    RemoteBufferConfig remote_buffer_config_;
    std::atomic<bool> abort_requested_{false};
};

} // namespace py
