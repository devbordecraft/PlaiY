# CLAUDE.md - PlaiY

## Project overview

PlaiY is a high-quality video player with a C++ core library and SwiftUI frontend. The core handles demuxing, decoding, audio output, subtitles, and A-V sync. The SwiftUI layer handles UI and Metal rendering. Communication between the two happens through a pure C bridge API (`plaiy_c.h`).

Current platform: macOS 14+. Future: tvOS, Linux, Windows.

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
    +-- CoreAudio AUHAL (audio output on Apple)
    +-- libass (ASS/SSA subtitle rendering)
    +-- Metal shaders (YUV->RGB, HDR tone mapping)
```

## Directory structure

```
plaiy/
  CMakeLists.txt              # Root CMake project
  core/
    CMakeLists.txt             # Core library build
    include/plaiy/        # Public C++ headers (interfaces, types)
    include/plaiy_c.h     # Pure C bridge API (the Swift<->C++ contract)
    src/                       # Implementation
      player_engine.cpp        # Central orchestrator (threading, state machine)
      demuxer/                 # FFmpeg demuxer (libavformat)
      video/                   # Video decoders (FFmpeg SW + VT factory)
      audio/                   # Audio decoder + resampler (libavcodec + libswresample)
      subtitle/                # SRT parser, ASS renderer (libass), PGS decoder
      sync/                    # Clock, PacketQueue, FrameQueue
      library/                 # Media library scanner + metadata reader
      bridge/                  # C bridge implementation
    platform/apple/            # Apple-specific: VideoToolbox, CoreAudio, Metal shaders
  app/
    project.yml                # XcodeGen spec (generates .xcodeproj)
    BridgingHeader.h           # Imports plaiy_c.h into Swift
    Shared/                    # SwiftUI code (shared macOS/tvOS)
      PlayerBridge.swift       # Swift wrapper around C API
      Metal/                   # MetalViewCoordinator (display link + rendering)
      Views/                   # SwiftUI views
    macOS/                     # macOS-specific (Info.plist)
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

### Build C++ core

```bash
cmake -B build/apple-debug -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build/apple-debug
```

### Build + run the app

```bash
./scripts/run.sh
```

### Build Xcode project only

```bash
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

## Key interfaces

- **`plaiy_c.h`** - The sole contract between Swift and C++. All cross-language calls go through here. Changes here require updating both `plaiy_c.cpp` and `PlayerBridge.swift`.
- **`player_engine.h`** - The C++ orchestrator. Owns demuxer, decoders, audio, subtitles, queues, and threads.
- **`video_decoder.h`** - `IVideoDecoder` interface. `VideoDecoderFactory` picks VT or FFmpeg.
- **`audio_engine.h`** - `IAudioOutput` interface. `CAAudioOutput` implements it on Apple.
- **`demuxer.h`** - `IDemuxer` interface. `FFDemuxer` is the only implementation.

## Threading model (during playback)

1. **Demux thread** - reads packets, routes to video/audio/subtitle queues
2. **Video decode thread** - packets -> VideoFrame (CVPixelBufferRef via VT)
3. **Audio decode thread** - packets -> PCM float32 -> ring buffer
4. **Render thread** (MTKView display link) - pulls VideoFrame, presents via Metal
5. **CoreAudio real-time thread** (OS-managed) - pulls from ring buffer

## HDR pipeline

Metal shaders in `core/platform/apple/metal_shaders.metal` handle:
- BT.709 and BT.2020 YCbCr-to-RGB conversion
- PQ EOTF (HDR10) and HLG OOTF
- EDR scaling based on display headroom

`CAMetalLayer` is configured with `rgba16Float` + `wantsExtendedDynamicRangeContent`.

## Dependencies

| Library | Version | Source | Purpose |
|---|---|---|---|
| FFmpeg | 8.x | Homebrew | Demux, decode, resample |
| libass | 0.17.x | Homebrew | ASS/SSA subtitle rendering |
| nlohmann-json | 3.12.x | Homebrew | Library metadata JSON |
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
3. Add Swift wrapper in `app/Shared/PlayerBridge.swift`

### Adding a new SwiftUI view
1. Create in `app/Shared/Views/`
2. Run `cd app && xcodegen generate` to update the Xcode project

### Adding a new Apple platform source (.mm)
1. Create in `core/platform/apple/`
2. Add to the `if(APPLE)` block in `core/CMakeLists.txt`
3. Add ARC flag in `set_source_files_properties` if using Objective-C

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

## Phase 1 status (current)

Working: local file playback, VideoToolbox HW decode, FFmpeg SW fallback, Metal rendering with HDR10 EDR, CoreAudio output, SRT/ASS/PGS subtitles, media library scanner, play/pause/seek controls.

## Planned features (not yet implemented)

- Audio bitstream passthrough (Dolby Atmos, TrueHD, DTS:X)
- Spatial audio rendering
- HDR10+ dynamic metadata
- Dolby Vision profile-specific tone mapping
- tvOS target
- Linux/Windows targets
- Network sources (SMB/NFS, HTTP streaming)
- TMDb/OMDb metadata enrichment
- Chapter navigation
- Variable speed playback
