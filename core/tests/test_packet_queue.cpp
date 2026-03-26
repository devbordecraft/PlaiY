#include <catch2/catch_test_macros.hpp>
#include "plaiy/packet_queue.h"
#include <thread>
#include <chrono>

using py::PacketQueue;
using py::Packet;
using namespace std::chrono_literals;

static Packet make_packet(int stream_index, int64_t pts, size_t data_size = 0) {
    Packet p;
    p.stream_index = stream_index;
    p.pts = pts;
    if (data_size > 0) {
        p.data.resize(data_size, 0);
    }
    return p;
}

TEST_CASE("PacketQueue starts empty") {
    PacketQueue q(16);
    REQUIRE(q.empty());
    REQUIRE(q.size() == 0);
    REQUIRE(q.total_bytes() == 0);
}

TEST_CASE("PacketQueue push and pop") {
    PacketQueue q(16);
    q.push(make_packet(0, 100));
    REQUIRE(q.size() == 1);
    REQUIRE_FALSE(q.empty());

    Packet out;
    REQUIRE(q.pop(out));
    REQUIRE(out.stream_index == 0);
    REQUIRE(out.pts == 100);
    REQUIRE(q.empty());
}

TEST_CASE("PacketQueue FIFO order") {
    PacketQueue q(16);
    q.push(make_packet(0, 1));
    q.push(make_packet(0, 2));
    q.push(make_packet(0, 3));

    Packet out;
    q.pop(out); REQUIRE(out.pts == 1);
    q.pop(out); REQUIRE(out.pts == 2);
    q.pop(out); REQUIRE(out.pts == 3);
}

TEST_CASE("PacketQueue total_bytes tracking") {
    PacketQueue q(16);
    q.push(make_packet(0, 1, 100));
    REQUIRE(q.total_bytes() == 100);

    q.push(make_packet(0, 2, 200));
    REQUIRE(q.total_bytes() == 300);

    Packet out;
    q.pop(out);
    REQUIRE(q.total_bytes() == 200);

    q.pop(out);
    REQUIRE(q.total_bytes() == 0);
}

TEST_CASE("PacketQueue try_pop_for on empty returns false") {
    PacketQueue q(16);
    Packet out;
    REQUIRE_FALSE(q.try_pop_for(out, 10ms));
}

TEST_CASE("PacketQueue try_pop_for succeeds when data available") {
    PacketQueue q(16);
    q.push(make_packet(0, 42));

    Packet out;
    REQUIRE(q.try_pop_for(out, 100ms));
    REQUIRE(out.pts == 42);
}

TEST_CASE("PacketQueue flush clears queue") {
    PacketQueue q(16);
    q.push(make_packet(0, 1));
    q.push(make_packet(0, 2));
    REQUIRE(q.size() == 2);

    q.flush();
    REQUIRE(q.empty());
    REQUIRE(q.total_bytes() == 0);
}

TEST_CASE("PacketQueue abort unblocks pop") {
    PacketQueue q(16);

    std::thread popper([&] {
        Packet out;
        // This should block until abort
        bool got = q.pop(out);
        REQUIRE_FALSE(got);
    });

    std::this_thread::sleep_for(10ms);
    q.abort();
    popper.join();
}

TEST_CASE("PacketQueue abort causes push to return false") {
    PacketQueue q(16);
    q.abort();
    REQUIRE_FALSE(q.push(make_packet(0, 1)));
}

TEST_CASE("PacketQueue reset after abort") {
    PacketQueue q(16);
    q.abort();
    REQUIRE_FALSE(q.push(make_packet(0, 1)));

    q.reset();
    REQUIRE(q.push(make_packet(0, 2)));
    REQUIRE(q.size() == 1);
}

TEST_CASE("PacketQueue max_size blocks push") {
    PacketQueue q(2); // max 2 packets

    q.push(make_packet(0, 1));
    q.push(make_packet(0, 2));
    REQUIRE(q.size() == 2);

    // Third push should block; use abort to unblock
    std::atomic<bool> push_started{false};
    std::thread pusher([&] {
        push_started.store(true);
        q.push(make_packet(0, 3));
    });

    // Wait for thread to start, then pop to unblock
    while (!push_started.load()) std::this_thread::yield();
    std::this_thread::sleep_for(10ms);

    Packet out;
    q.pop(out); // should unblock the pusher
    pusher.join();
    REQUIRE(q.size() == 2); // still 2: one popped, one pushed
}

TEST_CASE("PacketQueue max_bytes limits") {
    PacketQueue q(100, 500); // max 100 packets, 500 bytes

    q.push(make_packet(0, 1, 300));
    q.push(make_packet(0, 2, 200));
    REQUIRE(q.total_bytes() == 500);

    // Next push should block on bytes; use abort
    std::atomic<bool> started{false};
    std::thread pusher([&] {
        started.store(true);
        q.push(make_packet(0, 3, 100));
    });

    while (!started.load()) std::this_thread::yield();
    std::this_thread::sleep_for(10ms);

    Packet out;
    q.pop(out); // free 300 bytes
    pusher.join();
}

TEST_CASE("PacketQueue concurrent producer consumer") {
    PacketQueue q(32);
    constexpr int total = 1000;

    std::thread producer([&] {
        for (int i = 0; i < total; ++i) {
            q.push(make_packet(0, i));
        }
    });

    std::vector<int64_t> received;
    received.reserve(total);

    std::thread consumer([&] {
        for (int i = 0; i < total; ++i) {
            Packet out;
            q.pop(out);
            received.push_back(out.pts);
        }
    });

    producer.join();
    consumer.join();

    REQUIRE(received.size() == total);
    for (int i = 0; i < total; ++i) {
        REQUIRE(received[static_cast<size_t>(i)] == i);
    }
}
