add_executable(plaiy_tests
    test_error.cpp
    test_packet_pts.cpp
    test_spsc_ring_buffer.cpp
    test_clock.cpp
    test_packet_queue.cpp
    test_frame_queue.cpp
    test_srt_parser.cpp
    test_audio_passthrough.cpp
    test_playback_stats.cpp
    test_frame_presenter.cpp
    test_source_manager.cpp
    test_plex_media_source.cpp
    test_audio_filter_chain.cpp
    test_filesystem_error_handling.cpp
)

target_link_libraries(plaiy_tests PRIVATE
    plaiy_core
    Catch2::Catch2WithMain
)

# Tests need access to private headers (srt_parser.h, audio_passthrough.h, etc.)
# and FFmpeg headers for codec ID constants in audio_passthrough tests.
find_package(PkgConfig REQUIRED)
pkg_check_modules(AVCODEC REQUIRED IMPORTED_TARGET libavcodec)

target_include_directories(plaiy_tests PRIVATE
    ${CMAKE_SOURCE_DIR}/core/src
)

target_link_libraries(plaiy_tests PRIVATE PkgConfig::AVCODEC)

if(APPLE)
    target_link_libraries(plaiy_tests PRIVATE
        "-framework Foundation"
        "-framework NetFS"
    )
endif()

include(CTest)
include(Catch)
catch_discover_tests(plaiy_tests)
