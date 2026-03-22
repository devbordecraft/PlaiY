#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <string>

namespace py {

class IDemuxer {
public:
    virtual ~IDemuxer() = default;

    virtual Error open(const std::string& path) = 0;
    virtual void close() = 0;

    virtual const MediaInfo& media_info() const = 0;

    // Read the next packet. Returns EndOfFile when done.
    virtual Error read_packet(Packet& out) = 0;

    // Seek to timestamp in microseconds.
    virtual Error seek(int64_t timestamp_us) = 0;
};

} // namespace py
