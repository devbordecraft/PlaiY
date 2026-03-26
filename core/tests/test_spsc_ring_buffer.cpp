#include <catch2/catch_test_macros.hpp>
#include "plaiy/spsc_ring_buffer.h"
#include <thread>
#include <vector>
#include <numeric>

using py::SPSCRingBuffer;

TEST_CASE("SPSCRingBuffer resize and capacity") {
    SPSCRingBuffer<float> ring;
    ring.resize(1024);
    REQUIRE(ring.capacity() == 1024);
    REQUIRE(ring.available_read() == 0);
    REQUIRE(ring.available_write() == 1024);
}

TEST_CASE("SPSCRingBuffer write then read") {
    SPSCRingBuffer<int> ring;
    ring.resize(16);

    int data[] = {1, 2, 3, 4, 5};
    size_t written = ring.write(data, 5);
    REQUIRE(written == 5);
    REQUIRE(ring.available_read() == 5);
    REQUIRE(ring.available_write() == 11);

    int out[5] = {};
    size_t read = ring.read(out, 5);
    REQUIRE(read == 5);
    REQUIRE(out[0] == 1);
    REQUIRE(out[4] == 5);
    REQUIRE(ring.available_read() == 0);
}

TEST_CASE("SPSCRingBuffer partial write at capacity") {
    SPSCRingBuffer<int> ring;
    ring.resize(4);

    int data[] = {10, 20, 30, 40, 50, 60};
    size_t written = ring.write(data, 6);
    REQUIRE(written == 4); // capped at capacity
    REQUIRE(ring.available_write() == 0);
}

TEST_CASE("SPSCRingBuffer partial read when not enough data") {
    SPSCRingBuffer<int> ring;
    ring.resize(16);

    int data[] = {1, 2, 3};
    ring.write(data, 3);

    int out[10] = {};
    size_t read = ring.read(out, 10);
    REQUIRE(read == 3);
}

TEST_CASE("SPSCRingBuffer wrap-around") {
    SPSCRingBuffer<int> ring;
    ring.resize(8);

    // Fill 6 items, read 6, then write 6 more (wraps around)
    std::vector<int> first(6);
    std::iota(first.begin(), first.end(), 1);
    ring.write(first.data(), 6);

    std::vector<int> trash(6);
    ring.read(trash.data(), 6);
    REQUIRE(ring.available_read() == 0);

    // Now write indices start at 6, wrapping around the 8-element buffer
    std::vector<int> second = {10, 20, 30, 40, 50, 60};
    size_t written = ring.write(second.data(), 6);
    REQUIRE(written == 6);

    std::vector<int> out(6);
    size_t readn = ring.read(out.data(), 6);
    REQUIRE(readn == 6);
    REQUIRE(out[0] == 10);
    REQUIRE(out[5] == 60);
}

TEST_CASE("SPSCRingBuffer reset") {
    SPSCRingBuffer<int> ring;
    ring.resize(16);

    int data[] = {1, 2, 3};
    ring.write(data, 3);
    REQUIRE(ring.available_read() == 3);

    ring.reset();
    REQUIRE(ring.available_read() == 0);
    REQUIRE(ring.available_write() == 16);
}

TEST_CASE("SPSCRingBuffer release") {
    SPSCRingBuffer<int> ring;
    ring.resize(16);
    ring.release();
    REQUIRE(ring.capacity() == 0);
    REQUIRE(ring.available_read() == 0);
}

TEST_CASE("SPSCRingBuffer concurrent producer-consumer") {
    SPSCRingBuffer<int> ring;
    ring.resize(256);

    constexpr int total = 100'000;
    std::vector<int> received;
    received.reserve(total);

    std::thread producer([&] {
        for (int i = 0; i < total; ) {
            size_t written = ring.write(&i, 1);
            if (written == 1) ++i;
        }
    });

    std::thread consumer([&] {
        int count = 0;
        while (count < total) {
            int val;
            if (ring.read(&val, 1) == 1) {
                received.push_back(val);
                ++count;
            }
        }
    });

    producer.join();
    consumer.join();

    REQUIRE(received.size() == total);
    // Verify ordering
    for (int i = 0; i < total; ++i) {
        REQUIRE(received[static_cast<size_t>(i)] == i);
    }
}
