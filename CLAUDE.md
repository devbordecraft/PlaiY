# CLAUDE.md - PlaiY

## Project overview

PlaiY is a high-quality video player with a C++ core library and SwiftUI frontend. The core handles demuxing, decoding, audio output, subtitles, and A-V sync. The SwiftUI layer handles UI and Metal rendering. Communication between the two happens through a pure C bridge API (`plaiy_c.h`).

Current platforms: macOS 26+, iOS 26+, tvOS 26+. Future: Linux, Windows.

## Architecture

```
SwiftUI App (app/)
    |
    | calls C functions via bridging header
    v
Pure C Bridge (core/include/plaiy_c.h)
    |
    | wraps C++ objects
    v
C++ Core Library (core/)
    |
    +-- FFmpeg (demux, SW decode, audio decode, resampling)
    +-- VideoToolbox (HW video decode on Apple)
    +-- CoreAudio AUHAL (stereo/passthrough audio output on Apple)
    +-- AVAudioEngine (spatial audio with HRTF on Apple)
    +-- Audio bitstream passthrough (Dolby Atmos, TrueHD, DTS-HD MA, DTS:X)
    +-- Audio filter chain (EQ, compressor, dialogue boost, tempo)
    +-- libass (ASS/SSA subtitle rendering)
    +-- Metal shaders (YUV->RGB, HDR tone mapping, color filters, crop/zoom)
    +-- Source plugins (local filesystem, SMB via NetFS)
```

## Directory structure

```
plaiy/
  Makefile                     # Build everything, run the app (make run)
  CMakeLists.txt              # Root CMake project
  .github/workflows/test.yml  # CI (C++ + Swift tests)
  core/
    CMakeLists.txt             # Core library build
    include/plaiy/            # Public C++ headers (interfaces, types)
    include/plaiy_c.h         # Pure C bridge API (the Swift<->C++ contract)
    src/                       # Implementation
      player_engine.cpp        # Central orchestrator (threading, state machine, thread loops)
      playback_stats.h/cpp     # Stats gathering (extracted from PlayerEngine)
      frame_presenter.h/cpp    # A-V sync frame acquisition (extracted from PlayerEngine)
      audio_pipeline.h/cpp     # Audio output lifecycle, passthrough ring buffer, callbacks
      demuxer/                 # FFmpeg demuxer (libavformat)
      video/                   # Video decoders (FFmpeg SW + VT factory)
        deinterlace_filter.h/cpp  # CPU deinterlace (yadif/bwdif)
      audio/                   # Audio decoder, resampler, filters, passthrough
        audio_filter.h           # IAudioFilter interface
        audio_filter_chain.h/cpp # Two-stage filter pipeline
        equalizer_filter.h/cpp   # 10-band parametric EQ
        compressor_filter.h/cpp  # Dynamic range compressor
        dialogue_boost_filter.h/cpp # Center channel enhancement
        audio_tempo_filter.h/cpp # Variable speed (0.25x-4x)
      subtitle/                # SRT parser, ASS renderer (libass), PGS decoder
      sync/                    # Clock, PacketQueue, FrameQueue
      sources/                 # Media source implementations
        source_manager.cpp
        local_media_source.h/cpp
      library/                 # Media library scanner, metadata reader, seek thumbnails
      bridge/                  # C bridge implementation
    tests/                     # C++ unit tests (Catch2)
    platform/apple/            # VideoToolbox, CoreAudio, AVAudioEngine, Metal
      smb_media_source.h/mm      # SMB via Apple NetFS
  app/
    project.yml                # XcodeGen spec (generates .xcodeproj)
    BridgingHeader.h           # Imports plaiy_c.h into Swift
    Shared/                    # SwiftUI code (shared across platforms)
      PlayerBridge.swift       # Swift wrapper around C API
      AppSettings.swift        # Global settings with @AppStorage persistence
      VideoDisplaySettings.swift  # Aspect ratio, crop, zoom, pan models
      BlackBarDetector.swift   # Auto-crop via luma analysis of CVPixelBuffer
      ResumeStore.swift        # Per-file playback position persistence
      NowPlayingManager.swift  # MPRemoteCommandCenter / media key integration
      SourceManagerBridge.swift # Swift wrapper for source manager C API
      SourceConfig.swift       # Source configuration model (Codable)
      SourcesViewModel.swift   # Sources UI state
      KeychainHelper.swift     # Credential storage
      PlatformTypes.swift      # Cross-platform type aliases (NSImage/UIImage)
      Metal/                   # Metal rendering pipeline
        MetalViewCoordinator.swift  # Display link, frame acquisition, render encoding
        HDRUniformBuilder.swift     # HDR metadata -> shader uniforms
        ColorFilterUniformBuilder.swift # Brightness/contrast/saturation/sharpness uniforms
      Views/                   # SwiftUI views
    PlaiYTests/                # Swift unit tests (XCTest)
    macOS/                     # macOS-specific (Info.plist)
    iOS/                       # iOS-specific
    tvOS/                      # tvOS-specific
  scripts/
    run.sh                     # Build everything + launch
    build_core.sh              # Build C++ core only
    build_deps.sh              # Install deps via vcpkg (alternative to Homebrew)
```

## Build commands

### Prerequisites

```bash
brew install cmake ffmpeg libass nlohmann-json xcodegen
```

### Build + run the app (recommended)

```bash
make run
```

### Other make targets

```bash
make          # Build everything (core + app)
make core     # Build C++ core only
make xcodegen # Regenerate Xcode project only
make app      # Build core + xcodegen + Xcode build
make clean    # Clean all build artifacts

# Tests
make test       # Run all tests (C++ + Swift)
make test-cpp   # C++ tests only (Catch2)
make test-swift # Swift tests only (XCTest)

# Cross-platform
make core-ios      # Build C++ core for iOS device
make core-ios-sim  # Build C++ core for iOS simulator
make app-ios       # Build iOS app
make core-tvos     # Build C++ core for tvOS
make app-tvos      # Build tvOS app
make deps-ios      # Install iOS dependencies via vcpkg
make deps-tvos     # Install tvOS dependencies via vcpkg
```

### Manual build (alternative to make)

```bash
# C++ core
cmake -B build/apple-debug -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build/apple-debug

# Xcode project
cd app
xcodegen generate
xcodebuild -project PlaiY.xcodeproj -scheme PlaiY -configuration Debug build
```

### Launch without rebuilding

```bash
open ~/Library/Developer/Xcode/DerivedData/PlaiY-*/Build/Products/Debug/PlaiY.app
```

## Build order matters

Always build the C++ core **before** the Xcode project. The Xcode project links against `libplaiy_core.a` from `build/apple-debug/core/`.

## Coding conventions and patterns

### C++

- **Naming**: `snake_case` for functions and variables, `PascalCase` for classes, enums, and structs
- **Member variables**: trailing underscore (`codec_ctx_`, `mount_path_`, `enabled_`)
- **Namespace**: all core code in `namespace py {}`
- **Header guards**: `#pragma once` (no `#ifndef` guards)
- **Smart pointers**: `std::unique_ptr<Impl>` for Pimpl pattern, `std::shared_ptr<uint8_t[]>` for shared buffers
- **Error handling**: no exceptions anywhere in the codebase. Use `Error` struct with `ErrorCode` enum. Check with `if (err)` or `err.ok()`. Return `Error::Ok()` on success
- **Move semantics**: `VideoFrame` has a deleted copy constructor -- always `std::move`. Same for `Packet`
- **Logging**: define `static constexpr const char* TAG = "ModuleName";` then use `PY_LOG_DEBUG(TAG, "msg: %d", val)`
- **Forward declarations**: use in headers for FFmpeg types (`struct AVFrame;`, `struct AVCodecContext;`)
- **Interface pattern**: pure virtual classes prefixed with `I` (`IVideoDecoder`, `IDemuxer`, `IAudioOutput`, `IMediaSource`, `IAudioFilter`). Implementations chosen by factory functions

### C bridge (`plaiy_c.h`)

- **Function prefix**: `py_` for functions, `PY_` for enums and constants
- **Opaque handles**: `PYPlayer*`, `PYLibrary*`, `PYSourceManager*` -- always paired `create`/`destroy`
- **Callbacks**: function pointer + `void* userdata` (never `std::function` across the bridge)
- **String ownership**: returned `const char*` is owned by the engine, valid until next call to the same function or `destroy`. Copy immediately on the Swift side via `String(cString:)`
- **Null safety**: every bridge function checks for null handle before dereferencing
- **Enum mapping**: C enums (`PYError`, `PYPlaybackState`) mirror C++ enums with explicit integer values
- **Adding a bridge function**: declare in `plaiy_c.h`, implement in `bridge/plaiy_c.cpp`, wrap in `PlayerBridge.swift`

### Swift

- **Bridge protocol**: `PlayerBridgeProtocol` abstracts the C bridge for testability. `PlayerViewModel` depends on the protocol, not the concrete `PlayerBridge` class
- **Hot-path wrappers**: `@inline(always)` on simple getter/setter pass-throughs in `PlayerBridge.swift`
- **Two-tier state model**: `PlaybackTransport` for high-frequency state (position, subtitle, stats) that must NOT be `@Published`. `PlayerViewModel` for infrequent UI state (track lists, media title) that IS `@Published`
- **Settings**: `@AppStorage` in `AppSettings.swift` for UserDefaults persistence
- **C callback bridging**: `Unmanaged<AnyObject>` with manual retain/release for `void* userdata`
- **Concurrency**: Swift 6.3 strict concurrency. `@MainActor` on ViewModels. `@unchecked Sendable` on bridge wrappers. `nonisolated(unsafe)` for properties read from the Metal render thread
- **Cross-platform types**: `PlatformTypes.swift` provides aliases (`PlatformImage = NSImage` on macOS, `UIImage` on iOS)

### Anti-patterns to avoid

- **No C++ exceptions** -- entire codebase is exception-free
- **No blocking on CoreAudio real-time thread** -- no malloc, no mutex, no I/O in audio pull callbacks. Use the lock-free SPSC ring buffer
- **No copying `VideoFrame`** -- deleted copy constructor; use `std::move`
- **No assuming C bridge strings persist** -- copy immediately in Swift via `String(cString:)`
- **No mixing microseconds with stream `time_base` units** -- use `Packet::pts_us()` for conversion at the boundary
- **No `@Published` for high-frequency state** -- causes SwiftUI view rebuilds at display refresh rate
- **No `.mm` files without ARC** -- add `-fobjc-arc` flag in `set_source_files_properties` in CMakeLists.txt

## Key interfaces

- **`plaiy_c.h`** - The sole contract between Swift and C++. All cross-language calls go through here. Changes here require updating both `plaiy_c.cpp` and `PlayerBridge.swift`.
- **`player_engine.h`** - The C++ orchestrator. Owns demuxer, decoders, audio, subtitles, queues, and threads. Delegates to `AudioPipeline`, `FramePresenter`, and `gather_playback_stats()`.
- **`audio_pipeline.h`** - Audio output lifecycle: setup, restart, teardown, passthrough ring buffer, real-time PCM/bitstream pull callbacks. Internal helper (not part of public API).
- **`frame_presenter.h`** - A-V sync frame acquisition: peek/pop from frame queue, skip late frames, first-frame gate, clock unfreeze. Internal helper.
- **`playback_stats.h`** - `StatsContext` struct + `gather_playback_stats()` free function. Pure read-only stats gathering. Internal helper.
- **`video_decoder.h`** - `IVideoDecoder` interface. `VideoDecoderFactory` picks VT or FFmpeg.
- **`audio_engine.h`** - `IAudioOutput` interface. `CAAudioOutput` (stereo/passthrough) and `SpatialAudioOutput` (HRTF) implement it on Apple.
- **`demuxer.h`** - `IDemuxer` interface. `FFDemuxer` is the only implementation.
- **`audio_passthrough.h`** - Codec eligibility checks, bitrate limits, HDMI vs SPDIF routing for bitstream passthrough.
- **`audio_filter.h`** - `IAudioFilter` interface for audio processing plugins. Two stages: PreResample (AVFrame) and PostResample (float32).
- **`audio_filter_chain.h`** - `AudioFilterChain` orchestrates the two-stage filter pipeline. Lookup by name, enable/disable per filter.
- **`audio_tempo_filter.h`** - FFmpeg `atempo` filter wrapper for variable speed playback (0.25x-4x). PreResample stage.
- **`media_source.h`** - `IMediaSource` interface for browsable media sources: connect, disconnect, list_directory, playable_path.
- **`source_manager.h`** - `SourceManager` registry/factory for media sources. JSON serialization for config persistence (passwords excluded).
- **`spatial_audio_output.h`** - AVAudioEngine-based spatial audio with HRTF and head tracking (AirPods).

## Plugin/filter architecture

### Audio filter chain

Two-stage pipeline defined in `core/src/audio/audio_filter_chain.h`:

1. **PreResample** -- operates on `AVFrame*` before the resampler (e.g., tempo filter)
2. **PostResample** -- operates on float32 interleaved samples after resampling (e.g., EQ, compressor)

Filters implement `IAudioFilter` (`core/src/audio/audio_filter.h`). Each filter has atomic `enabled_` and can be hot-configured during playback via `std::atomic<float>` parameters. Changed parameters trigger FFmpeg filter graph rebuild on next `process()` call.

| Filter | Stage | File | FFmpeg filter |
|---|---|---|---|
| `AudioTempoFilter` | PreResample | `audio_tempo_filter.h` | `atempo` |
| `EqualizerFilter` | PostResample | `equalizer_filter.h` | `superequalizer` (10-band) |
| `CompressorFilter` | PostResample | `compressor_filter.h` | `acompressor` |
| `DialogueBoostFilter` | PostResample | `dialogue_boost_filter.h` | `stereotools` + `pan` |

### Video filters

- **GPU filters**: brightness, contrast, saturation, sharpness via Metal shader uniforms (`ColorFilterUniforms`). Set through C bridge (`py_player_set_brightness()` etc.), built in `ColorFilterUniformBuilder.swift`, applied in `metal_shaders.metal`.
- **CPU filters**: `DeinterlaceFilter` (`core/src/video/deinterlace_filter.h`) uses FFmpeg yadif/bwdif. Operates in video decode thread on SW-decoded frames only.

### Adding a new audio filter

1. Create `core/src/audio/my_filter.h/cpp` implementing `IAudioFilter`
2. Choose stage: `PreResample` (AVFrame) or `PostResample` (float32 in-place)
3. Register in `AudioFilterChain` construction (in `audio_pipeline.cpp`)
4. Add bridge functions in `plaiy_c.h` / `plaiy_c.cpp` (pattern: `py_player_set_X_enabled`, `py_player_is_X_enabled`, `py_player_set_X_param`)
5. Add Swift wrappers in `PlayerBridge.swift`
6. Add to `core/CMakeLists.txt` `CORE_SOURCES`

## Network source system

Modular source plugin architecture for browsable media sources.

- **`IMediaSource`** (`core/include/plaiy/media_source.h`): abstract interface with `connect()`, `disconnect()`, `list_directory()`, `playable_path()`
- **`SourceManager`** (`core/include/plaiy/source_manager.h`): registry/factory. `add_source()` creates the right implementation via `create_source()` factory based on `MediaSourceType` enum. Supports JSON serialization (passwords excluded -- stored in Keychain on Swift side via `KeychainHelper.swift`)
- **`LocalMediaSource`** (`core/src/sources/local_media_source.h`): filesystem browsing
- **`SMBMediaSource`** (`core/platform/apple/smb_media_source.mm`): mounts SMB shares as local paths via Apple NetFS API. Downstream code works with mounted paths unchanged

### Adding a new media source protocol

1. Add enum case to `MediaSourceType` in `media_source.h`
2. Create implementation of `IMediaSource` (platform-specific goes in `core/platform/`)
3. Add factory case in `SourceManager::create_source()`
4. Add bridge functions in `plaiy_c.h` / `plaiy_c.cpp`
5. Update `SourceConfig.swift` type enum
6. Add to `core/CMakeLists.txt`

## Threading model (during playback)

1. **Demux thread** - reads packets, routes to video/audio/subtitle queues
2. **Video decode thread** - packets -> VideoFrame (CVPixelBufferRef via VT)
3. **Audio decode thread** - packets -> filter chain (PreResample) -> resampler -> filter chain (PostResample) -> ring buffer
4. **Render thread** (MTKView display link) - pulls VideoFrame, presents via Metal
5. **CoreAudio real-time thread** (OS-managed) - pulls from ring buffer (stereo/passthrough mode)
6. **AVAudioEngine render thread** (OS-managed) - pulls from ring buffer, applies HRTF (spatial mode)

**Threading rules**:
- Audio filter parameters use `std::atomic<float>` for lock-free hot-swap from any thread
- SPSC ring buffer uses `std::atomic` with acquire/release ordering -- no locks on the RT thread
- `SourceManager` is NOT thread-safe -- all CRUD must happen on the UI thread
- Frame queue uses `std::mutex` + condition variables (blocking OK for decode threads)

## HDR pipeline

Metal shaders in `core/platform/apple/metal_shaders.metal` handle YUV-to-RGB conversion, HDR tone mapping (HDR10 static via BT.2390 EETF, HDR10+ dynamic via ST 2094-40 bezier curves, HLG EOTF, Dolby Vision Profile 8 reshaping with L1/L2 trim), and EDR output mapping. HDR metadata flows: FFmpeg -> `VideoFrame` -> C bridge -> `HDRUniformBuilder.swift` -> shader uniforms. `CAMetalLayer` uses `rgba16Float` + `wantsExtendedDynamicRangeContent`.

## Audio output modes

Three modes selected by `PlayerEngine` based on content and settings: **PCM stereo** (`CAAudioOutput` via AUHAL), **spatial HRTF** (`SpatialAudioOutput` via AVAudioEngine with AirPods head tracking), and **bitstream passthrough** (AC3/E-AC3/DTS/DTS-HD MA/TrueHD direct to AVR/soundbar; TrueHD requires MAT framing via `MATFramer`; high-bitrate formats require HDMI, AC3/DTS can use SPDIF).

## Dependencies

| Library | Version | Source | Purpose |
|---|---|---|---|
| FFmpeg | 8.x | Homebrew | Demux, decode, resample, audio/video filters |
| libass | 0.17.x | Homebrew | ASS/SSA subtitle rendering |
| nlohmann-json | 3.12.x | Homebrew | Library metadata / source config JSON |
| CMake | 3.25+ | Homebrew | C++ build system |
| XcodeGen | 2.38+ | Homebrew | Generates .xcodeproj |

## Common tasks

### Adding a new C++ source file
1. Create the file in the appropriate `core/src/` subdirectory
2. Add it to `CORE_SOURCES` in `core/CMakeLists.txt`
3. Rebuild the core

### Adding a new C bridge function
1. Declare in `core/include/plaiy_c.h`
2. Implement in `core/src/bridge/plaiy_c.cpp`
3. Add Swift wrapper in `app/Shared/PlayerBridge.swift` (and in `PlayerBridgeProtocol` if needed for testing)

### Adding a new SwiftUI view
1. Create in `app/Shared/Views/`
2. Run `cd app && xcodegen generate` to update the Xcode project

### Adding a new Apple platform source (.mm)
1. Create in `core/platform/apple/`
2. Add to the `if(APPLE)` block in `core/CMakeLists.txt`
3. Add ARC flag in `set_source_files_properties` if using Objective-C

## Testing

### C++ tests (Catch2)

146 test cases across 12 files in `core/tests/`, built as `plaiy_tests` via CMake + Catch2.

```bash
make test-cpp
# or manually:
cmake --build build/apple-debug && cd build/apple-debug && ctest --output-on-failure
```

| Test file | Coverage |
|---|---|
| `test_error.cpp` | Error enum and struct |
| `test_packet_pts.cpp` | Packet PTS to microseconds conversion |
| `test_spsc_ring_buffer.cpp` | Lock-free SPSC ring buffer (resize, wrap, concurrent) |
| `test_clock.cpp` | Clock pause/resume/seek/rate/concurrent |
| `test_packet_queue.cpp` | PacketQueue sizing, timeout, abort, concurrent |
| `test_frame_queue.cpp` | FrameQueue blocking push/pop, peek, flush |
| `test_srt_parser.cpp` | SRT subtitle parsing and lookup |
| `test_audio_passthrough.cpp` | Passthrough codec support, byte rates, HDMI requirements |
| `test_playback_stats.cpp` | Stats gathering with mocked context |
| `test_frame_presenter.cpp` | A-V sync (empty queue, tolerance, skip late, first-frame gate) |
| `test_audio_filter_chain.cpp` | IAudioFilter interface, enable/disable, stage classification, hot reconfiguration |
| `test_source_manager.cpp` | SourceManager lifecycle, JSON roundtrip, factory, LocalMediaSource |

### Swift tests (XCTest)

102 test methods across 7 files in `app/PlaiYTests/`, run via Xcode or:

```bash
make test-swift
```

| Test file | Coverage |
|---|---|
| `PlayerViewModelTests.swift` | Play/pause, seek, track selection, speed (mock bridge) |
| `TrackInfoTests.swift` | Track metadata parsing |
| `VideoDisplaySettingsTests.swift` | Aspect ratio, crop, zoom, pan calculations |
| `LibraryItemTests.swift` | Media library item model |
| `TimeFormattingTests.swift` | Time display formatting |
| `ResumeStoreTests.swift` | Resume position persistence |
| `SourceConfigTests.swift` | Source config persistence, JSON roundtrip, KeychainHelper |

### Adding a new C++ test
1. Create `core/tests/test_<name>.cpp` with `#include <catch2/catch_test_macros.hpp>`
2. Add the file to `add_executable(plaiy_tests ...)` in `core/tests/CMakeLists.txt`
3. Internal headers (from `core/src/`) are accessible -- the test target has `core/src` in its include path

### Adding a new Swift test
1. Create in `app/PlaiYTests/`
2. Use `MockPlayerBridge` (conforms to `PlayerBridgeProtocol`) for testing player interactions
3. Run `cd app && xcodegen generate` to include the new file

## CI/CD

GitHub Actions workflow in `.github/workflows/test.yml`:
- **Triggers**: push to `master`, all pull requests
- **`cpp-tests` job**: installs deps via Homebrew, cmake configure + build, `ctest`
- **`swift-tests` job**: installs deps, `make core`, `make xcodegen`, `xcodebuild test`
- **Runner**: `macos-15`

## Logging

The codebase has a unified logging system that spans both the C++ core and the Swift UI layer. In debug builds, all log levels (including Debug) are active. In release builds, debug logs are compiled out of C++ entirely and suppressed in Swift.

### C++ (core)

The logger lives in `core/include/plaiy/logger.h` (singleton) with implementation in `core/src/util/logger.cpp`.

Use the macros with a module tag:

```cpp
static constexpr const char* TAG = "MyModule";

PY_LOG_DEBUG(TAG, "detailed info: %d", value);  // Compiled out in release (NDEBUG)
PY_LOG_INFO(TAG, "opened file: %s", path);
PY_LOG_WARN(TAG, "fallback: %s", reason);
PY_LOG_ERROR(TAG, "failed: %s", err.message.c_str());
```

Default output goes to stderr with timestamps: `HH:MM:SS.mmm [L/TAG] message`

The log level defaults to `Debug` in debug builds and `Info` in release builds. A custom callback can be set via `Logger::set_callback()` to redirect output (the Swift layer uses this to route to `os_log`).

### Swift (app)

`PYLog` in `app/Shared/PYLog.swift` provides Swift-side logging and wires the C++ core logs into Apple's unified logging (`os.Logger`).

```swift
PYLog.debug("detailed info", tag: "MyView")    // Only in DEBUG builds
PYLog.info("loaded items", tag: "Library")
PYLog.warning("missing data", tag: "Library")
PYLog.error("decode failed: \(error)", tag: "Metal")
```

`PYLog.setup()` is called at app launch (`PlaiYApp.init`). It sets the C++ log level and installs a callback that forwards all core logs to `os_log`, viewable in Console.app under subsystem `com.plaiy.app`.

### C bridge

`plaiy_c.h` exposes `py_log_set_level()`, `py_log_get_level()`, and `py_log_set_callback()` for configuring logging from the Swift side without touching C++ directly.

## Current status

Working: local file playback, VideoToolbox HW decode, FFmpeg SW fallback, Metal rendering with HDR10/HDR10+/HLG/Dolby Vision EDR tone mapping, CoreAudio output, SRT/ASS/PGS subtitles, media library scanner, play/pause/seek controls, seek preview thumbnails, keyboard shortcuts and media keys, variable speed playback (0.25x-4x), volume control with persistence, resume playback with dialog, global settings with persistence, audio bitstream passthrough (AC3, E-AC3/Atmos, DTS/DTS-HD MA/DTS:X, TrueHD), spatial audio rendering (AVAudioEngine HRTF + head tracking), aspect ratio override (auto/fill/stretch/16:9/4:3/21:9/2.35:1), auto-crop black bar detection, zoom and pan controls, audio EQ (10-band), audio compressor, dialogue boost, deinterlacing (yadif/bwdif), video color adjustments (brightness/contrast/saturation/sharpness), SMB network source browsing, iOS/tvOS cross-platform builds.

## Planned features (not yet implemented)

- Chapter navigation
- NFS and HTTP streaming sources
- Plex media server integration
- Playlist / play queue
- Subtitle timing adjustment
- TMDb/OMDb metadata enrichment
- Picture-in-Picture
- Frame capture / screenshot
- Linux/Windows targets
- Watch history and smart resume (CloudKit sync)
- Drag and drop / file association
