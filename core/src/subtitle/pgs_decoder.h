#pragma once

#include "plaiy/error.h"
#include "plaiy/types.h"
#include <vector>

struct AVCodecContext;

namespace py {

class PgsDecoder {
public:
    PgsDecoder();
    ~PgsDecoder();

    Error open();
    void close();
    void flush();

    // Decode a PGS subtitle packet. May produce a bitmap frame.
    Error decode(const Packet& pkt, SubtitleFrame& out, bool& has_output);

private:
    AVCodecContext* codec_ctx_ = nullptr;
};

} // namespace py
