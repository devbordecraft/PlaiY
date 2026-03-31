if(CMAKE_CROSSCOMPILING)
    # Cross-compilation (iOS/tvOS): use find_library with CMAKE_PREFIX_PATH
    find_library(AVFORMAT_LIB avformat REQUIRED)
    find_library(AVCODEC_LIB avcodec REQUIRED)
    find_library(AVUTIL_LIB avutil REQUIRED)
    find_library(SWRESAMPLE_LIB swresample REQUIRED)
    find_library(SWSCALE_LIB swscale REQUIRED)
    find_library(AVFILTER_LIB avfilter REQUIRED)
    find_library(LIBASS_LIB ass REQUIRED)
    find_path(FFMPEG_INCLUDE_DIR libavformat/avformat.h REQUIRED)
    find_path(LIBASS_INCLUDE_DIR ass/ass.h REQUIRED)
    find_package(nlohmann_json CONFIG REQUIRED)
else()
    find_package(PkgConfig REQUIRED)
    find_package(FFmpeg COMPONENTS avformat avcodec avutil swresample swscale avfilter QUIET)

    if(NOT FFmpeg_FOUND)
        pkg_check_modules(AVFORMAT REQUIRED IMPORTED_TARGET libavformat)
        pkg_check_modules(AVCODEC REQUIRED IMPORTED_TARGET libavcodec)
        pkg_check_modules(AVUTIL REQUIRED IMPORTED_TARGET libavutil)
        pkg_check_modules(SWRESAMPLE REQUIRED IMPORTED_TARGET libswresample)
        pkg_check_modules(SWSCALE REQUIRED IMPORTED_TARGET libswscale)
        pkg_check_modules(AVFILTER REQUIRED IMPORTED_TARGET libavfilter)
    endif()

    pkg_check_modules(LIBASS REQUIRED IMPORTED_TARGET libass)

    find_package(nlohmann_json CONFIG REQUIRED)
endif()

# Platform-agnostic sources
set(CORE_SOURCES
    src/types.cpp
    src/player_engine.cpp
    src/playback_stats.cpp
    src/frame_presenter.cpp
    src/audio_pipeline.cpp
    src/demuxer/ff_demuxer.cpp
    src/video/video_decoder_factory.cpp
    src/video/ff_video_decoder.cpp
    src/video/deinterlace_filter.cpp
    src/audio/audio_decoder.cpp
    src/audio/audio_resampler.cpp
    src/audio/audio_filter_chain.cpp
    src/audio/audio_tempo_filter.cpp
    src/audio/equalizer_filter.cpp
    src/audio/compressor_filter.cpp
    src/audio/dialogue_boost_filter.cpp
    src/audio/audio_passthrough.cpp
    src/audio/mat_framer.cpp
    src/subtitle/subtitle_manager.cpp
    src/subtitle/srt_parser.cpp
    src/subtitle/ass_renderer.cpp
    src/subtitle/pgs_decoder.cpp
    src/sync/clock.cpp
    src/sync/packet_queue.cpp
    src/sync/frame_queue.cpp
    src/library/media_library.cpp
    src/library/metadata_reader.cpp
    src/library/ffmpeg_video_opener.cpp
    src/library/seek_thumbnail_generator.cpp
    src/sources/source_manager.cpp
    src/sources/local_media_source.cpp
    src/sources/plex_media_source.cpp
    src/util/logger.cpp
    src/bridge/plaiy_c.cpp
)

# Apple platform sources
if(APPLE)
    list(APPEND CORE_SOURCES
        platform/apple/vt_video_decoder.mm
        platform/apple/ca_audio_output.mm
        platform/apple/spatial_audio_output.mm
        platform/apple/spatial_audio_detector.mm
        platform/apple/ns_http_client.mm
        platform/apple/dv_video_output.mm
    )
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        list(APPEND CORE_SOURCES platform/apple/smb_media_source.mm)
    endif()
endif()

add_library(plaiy_core STATIC ${CORE_SOURCES})

target_compile_options(plaiy_core PRIVATE -Wall -Wextra -Wpedantic -Wshadow -Wconversion)

target_precompile_headers(plaiy_core PRIVATE
    "$<$<COMPILE_LANGUAGE:CXX>:cstdint>"
    "$<$<COMPILE_LANGUAGE:CXX>:cstdarg>"
    "$<$<COMPILE_LANGUAGE:CXX>:string>"
    "$<$<COMPILE_LANGUAGE:CXX>:vector>"
    "$<$<COMPILE_LANGUAGE:CXX>:memory>"
    "$<$<COMPILE_LANGUAGE:CXX>:atomic>"
    "$<$<COMPILE_LANGUAGE:CXX>:mutex>"
    "$<$<COMPILE_LANGUAGE:CXX>:thread>"
    "$<$<COMPILE_LANGUAGE:CXX>:chrono>"
    "$<$<COMPILE_LANGUAGE:CXX>:functional>"
)

target_include_directories(plaiy_core
    PUBLIC include
    PRIVATE src
)

if(APPLE)
    target_include_directories(plaiy_core PRIVATE platform/apple)
endif()

if(CMAKE_CROSSCOMPILING)
    target_include_directories(plaiy_core PRIVATE
        ${FFMPEG_INCLUDE_DIR}
        ${LIBASS_INCLUDE_DIR}
    )
    target_link_libraries(plaiy_core PRIVATE
        ${AVFORMAT_LIB} ${AVCODEC_LIB} ${AVUTIL_LIB}
        ${SWRESAMPLE_LIB} ${SWSCALE_LIB} ${AVFILTER_LIB}
        ${LIBASS_LIB}
    )
elseif(FFmpeg_FOUND)
    target_link_libraries(plaiy_core PRIVATE
        FFmpeg::avformat FFmpeg::avcodec FFmpeg::avutil
        FFmpeg::swresample FFmpeg::swscale FFmpeg::avfilter
    )
else()
    target_link_libraries(plaiy_core PRIVATE
        PkgConfig::AVFORMAT PkgConfig::AVCODEC PkgConfig::AVUTIL
        PkgConfig::SWRESAMPLE PkgConfig::SWSCALE PkgConfig::AVFILTER
    )
endif()

if(NOT CMAKE_CROSSCOMPILING)
    target_link_libraries(plaiy_core PRIVATE PkgConfig::LIBASS)
endif()

target_link_libraries(plaiy_core PRIVATE
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
        "-framework Accelerate"
        "-framework Metal"
        "-framework QuartzCore"
        "-framework IOSurface"
        "-framework AVFoundation"
        "-framework CoreMotion"
    )
    set_source_files_properties(
        platform/apple/vt_video_decoder.mm
        platform/apple/ca_audio_output.mm
        platform/apple/spatial_audio_output.mm
        platform/apple/spatial_audio_detector.mm
        platform/apple/ns_http_client.mm
        platform/apple/dv_video_output.mm
        PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
    )
    if(NOT CMAKE_SYSTEM_NAME STREQUAL "tvOS")
        target_link_libraries(plaiy_core PRIVATE "-framework NetFS")
        set_source_files_properties(
            platform/apple/smb_media_source.mm
            PROPERTIES COMPILE_OPTIONS "-fobjc-arc"
        )
    endif()
endif()

install(TARGETS plaiy_core ARCHIVE DESTINATION lib)
install(DIRECTORY include/ DESTINATION include)
