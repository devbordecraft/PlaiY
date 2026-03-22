find_package(PkgConfig REQUIRED)
find_package(FFmpeg COMPONENTS avformat avcodec avutil swresample swscale QUIET)

if(NOT FFmpeg_FOUND)
    pkg_check_modules(AVFORMAT REQUIRED IMPORTED_TARGET libavformat)
    pkg_check_modules(AVCODEC REQUIRED IMPORTED_TARGET libavcodec)
    pkg_check_modules(AVUTIL REQUIRED IMPORTED_TARGET libavutil)
    pkg_check_modules(SWRESAMPLE REQUIRED IMPORTED_TARGET libswresample)
    pkg_check_modules(SWSCALE REQUIRED IMPORTED_TARGET libswscale)
endif()

pkg_check_modules(LIBASS REQUIRED IMPORTED_TARGET libass)

find_package(nlohmann_json CONFIG REQUIRED)

# Platform-agnostic sources
set(CORE_SOURCES
    src/types.cpp
    src/player_engine.cpp
    src/demuxer/ff_demuxer.cpp
    src/video/video_decoder_factory.cpp
    src/video/ff_video_decoder.cpp
    src/audio/audio_decoder.cpp
    src/audio/audio_resampler.cpp
    src/audio/audio_passthrough.cpp
    src/subtitle/subtitle_manager.cpp
    src/subtitle/srt_parser.cpp
    src/subtitle/ass_renderer.cpp
    src/subtitle/pgs_decoder.cpp
    src/sync/clock.cpp
    src/sync/packet_queue.cpp
    src/sync/frame_queue.cpp
    src/library/media_library.cpp
    src/library/metadata_reader.cpp
    src/library/thumbnail_generator.cpp
    src/library/seek_thumbnail_generator.cpp
    src/util/logger.cpp
    src/bridge/plaiy_c.cpp
)

# Apple platform sources
if(APPLE)
    list(APPEND CORE_SOURCES
        platform/apple/vt_video_decoder.mm
        platform/apple/ca_audio_output.mm
        platform/apple/metal_video_renderer.mm
    )
endif()

add_library(plaiy_core STATIC ${CORE_SOURCES})

target_include_directories(plaiy_core
    PUBLIC include
    PRIVATE src
)

if(FFmpeg_FOUND)
    target_link_libraries(plaiy_core PRIVATE
        FFmpeg::avformat FFmpeg::avcodec FFmpeg::avutil
        FFmpeg::swresample FFmpeg::swscale
    )
else()
    target_link_libraries(plaiy_core PRIVATE
        PkgConfig::AVFORMAT PkgConfig::AVCODEC PkgConfig::AVUTIL
        PkgConfig::SWRESAMPLE PkgConfig::SWSCALE
    )
endif()

target_link_libraries(plaiy_core PRIVATE
    PkgConfig::LIBASS
    nlohmann_json::nlohmann_json
)

if(APPLE)
    target_link_libraries(plaiy_core PRIVATE
        "-framework VideoToolbox"
        "-framework CoreMedia"
        "-framework CoreVideo"
        "-framework CoreFoundation"
        "-framework CoreAudio"
        "-framework AudioToolbox"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework IOSurface"
    )
    set_source_files_properties(
        platform/apple/vt_video_decoder.mm
        platform/apple/ca_audio_output.mm
        platform/apple/metal_video_renderer.mm
        PROPERTIES COMPILE_FLAGS "-fobjc-arc"
    )
endif()

install(TARGETS plaiy_core ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
