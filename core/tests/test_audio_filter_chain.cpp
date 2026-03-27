#include <catch2/catch_test_macros.hpp>
#include <catch2/catch_approx.hpp>
#include "audio/audio_filter.h"
#include "audio/audio_filter_chain.h"

using namespace py;

// A trivial post-resample filter that multiplies all samples by a gain factor.
class GainFilter : public IAudioFilter {
public:
    explicit GainFilter(float gain) : gain_(gain) {}

    const char* name() const override { return "gain"; }
    AudioFilterStage stage() const override { return AudioFilterStage::PostResample; }

    Error open_float(int /*sample_rate*/, int /*channels*/) override {
        return Error::Ok();
    }

    void process(float* data, int num_samples, int channels) override {
        int total = num_samples * channels;
        for (int i = 0; i < total; i++) {
            data[i] *= gain_;
        }
    }

    void close() override {}

    void set_gain(float g) { gain_ = g; }
    float gain() const { return gain_; }

private:
    float gain_ = 1.0f;
};

// A second filter for testing chain ordering.
class OffsetFilter : public IAudioFilter {
public:
    explicit OffsetFilter(float offset) : offset_(offset) {}

    const char* name() const override { return "offset"; }
    AudioFilterStage stage() const override { return AudioFilterStage::PostResample; }

    Error open_float(int /*sample_rate*/, int /*channels*/) override {
        return Error::Ok();
    }

    void process(float* data, int num_samples, int channels) override {
        int total = num_samples * channels;
        for (int i = 0; i < total; i++) {
            data[i] += offset_;
        }
    }

    void close() override {}

private:
    float offset_ = 0.0f;
};

TEST_CASE("AudioFilterChain: find returns registered filters", "[audio_filter_chain]") {
    AudioFilterChain chain;
    chain.add(std::make_unique<GainFilter>(2.0f));
    chain.add(std::make_unique<OffsetFilter>(0.5f));

    auto* gain = chain.find("gain");
    auto* offset = chain.find("offset");
    auto* missing = chain.find("nonexistent");

    REQUIRE(gain != nullptr);
    REQUIRE(offset != nullptr);
    REQUIRE(missing == nullptr);

    REQUIRE(std::string(gain->name()) == "gain");
    REQUIRE(std::string(offset->name()) == "offset");
}

TEST_CASE("AudioFilterChain: enable/disable filters", "[audio_filter_chain]") {
    GainFilter filter(2.0f);

    REQUIRE_FALSE(filter.enabled());

    filter.set_enabled(true);
    REQUIRE(filter.enabled());

    filter.set_enabled(false);
    REQUIRE_FALSE(filter.enabled());
}

TEST_CASE("AudioFilterChain: stage classification", "[audio_filter_chain]") {
    GainFilter gain(1.0f);
    REQUIRE(gain.stage() == AudioFilterStage::PostResample);
}

TEST_CASE("GainFilter: in-place processing", "[audio_filter_chain]") {
    GainFilter filter(2.0f);
    filter.set_enabled(true);

    float data[] = {0.5f, -0.25f, 1.0f, 0.0f};
    filter.process(data, 2, 2); // 2 samples, 2 channels

    REQUIRE(data[0] == Catch::Approx(1.0f));
    REQUIRE(data[1] == Catch::Approx(-0.5f));
    REQUIRE(data[2] == Catch::Approx(2.0f));
    REQUIRE(data[3] == Catch::Approx(0.0f));
}

TEST_CASE("GainFilter: unity gain is identity", "[audio_filter_chain]") {
    GainFilter filter(1.0f);
    filter.set_enabled(true);

    float data[] = {0.3f, -0.7f, 0.0f, 1.0f};
    float expected[] = {0.3f, -0.7f, 0.0f, 1.0f};
    filter.process(data, 2, 2);

    for (int i = 0; i < 4; i++) {
        REQUIRE(data[i] == Catch::Approx(expected[i]));
    }
}

TEST_CASE("GainFilter: hot reconfiguration", "[audio_filter_chain]") {
    GainFilter filter(2.0f);
    filter.set_enabled(true);

    float data1[] = {1.0f};
    filter.process(data1, 1, 1);
    REQUIRE(data1[0] == Catch::Approx(2.0f));

    // Change gain mid-stream
    filter.set_gain(0.5f);
    float data2[] = {1.0f};
    filter.process(data2, 1, 1);
    REQUIRE(data2[0] == Catch::Approx(0.5f));
}
