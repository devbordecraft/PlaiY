#pragma once
#include <string>

struct AVFormatContext;
struct AVCodecContext;

namespace py {

// RAII helper for opening a video file with FFmpeg (demux + decode setup).
// Used by ThumbnailGenerator and SeekThumbnailGenerator.
struct FFmpegVideoOpener {
    AVFormatContext* fmt = nullptr;
    AVCodecContext*  dec = nullptr;
    int stream_index = -1;

    // Opens video file, finds best video stream, opens decoder.
    bool open(const std::string& path, int thread_count = 2);
    void close();
    ~FFmpegVideoOpener() { close(); }

    // Non-copyable
    FFmpegVideoOpener() = default;
    FFmpegVideoOpener(const FFmpegVideoOpener&) = delete;
    FFmpegVideoOpener& operator=(const FFmpegVideoOpener&) = delete;
};

} // namespace py
