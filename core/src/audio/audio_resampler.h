#pragma once

#include "plaiy/error.h"
#include <cstdint>
#include <vector>

struct SwrContext;
struct AVFrame;
struct AVCodecContext;

namespace py {

class AudioResampler {
public:
    AudioResampler();
    ~AudioResampler();

    // Configure resampler to convert from the codec's output format
    // to interleaved float32 at the given output sample rate and channels.
    Error open(AVCodecContext* codec_ctx, int out_sample_rate, int out_channels);
    void close();

    // Convert an AVFrame to interleaved float32.
    // Returns the output samples in the provided vector.
    Error convert(AVFrame* frame, std::vector<float>& out_samples, int& out_num_samples);

private:
    SwrContext* swr_ctx_ = nullptr;
    int out_sample_rate_ = 0;
    int out_channels_ = 0;
};

} // namespace py
