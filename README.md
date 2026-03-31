# PlaiY

A high-quality video player built with a C++20 core and SwiftUI frontend. Designed for cinephiles who care about accurate HDR rendering, lossless audio, and proper subtitle support.

## Features

- **Video decoding**: VideoToolbox hardware decode (H.264, H.265, VP9, AV1) with FFmpeg software fallback
- **HDR rendering**: Metal EDR pipeline with HDR10, HDR10+, HLG, and Dolby Vision tone mapping
- **Audio output modes**: PCM stereo, passthrough bitstream (AC3/E-AC3/DTS/DTS-HD MA/TrueHD), and spatial audio (HRTF + head tracking)
- **Audio processing**: 10-band EQ, compressor, dialogue boost, variable speed (0.25x to 4x)
- **Subtitle support**: SRT, ASS/SSA via libass, PGS bitmap subtitles
- **Video processing**: deinterlacing (yadif/bwdif), brightness/contrast/saturation/sharpness, auto-crop, zoom/pan, aspect ratio overrides
- **Sources**: local files, SMB browsing, Plex browsing/auth, direct-play HTTP URLs, plus media library scanning and seek thumbnails
- **Platforms**: macOS, iOS, tvOS targets (Apple platform toolchains)

## Screenshots

*Coming soon*

## Requirements

- macOS 26+ for app builds
- Xcode with macOS/iOS/tvOS 26 SDKs
- Homebrew

## Quick start

### 1. Install dependencies

```bash
brew install cmake ffmpeg libass nlohmann-json xcodegen

# Optional: NFS direct-play URLs require an FFmpeg build with libnfs support.
# Homebrew's `ffmpeg` formula does not currently advertise `nfs://` input support.
# Use an FFmpeg build with `libnfs` enabled if you need NFS playback.
```

### 2. Build and run

```bash
git clone <repo-url> plaiy
cd plaiy
make run
```

This builds the C++ core, regenerates the Xcode project, compiles the app, and launches it.

### 3. Use the app

- Click **Add Folder** to scan a directory for media files
- Click **Open File** to play a single file
- Click a media item in the library to start playback
- Tap the player to show/hide controls
- Use the seek bar, play/pause, and skip buttons

## Manual build

### Build the C++ core library

```bash
cmake -B build/apple-debug -DCMAKE_BUILD_TYPE=Debug -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build build/apple-debug
```

### Build the macOS app

```bash
cd app
xcodegen generate
xcodebuild -project PlaiY.xcodeproj -scheme PlaiY -configuration Debug build
```

### Launch the app

```bash
open ~/Library/Developer/Xcode/DerivedData/PlaiY-*/Build/Products/Debug/PlaiY.app
```

### Or open in Xcode

```bash
open app/PlaiY.xcodeproj
```

Then hit Cmd+R to build and run.

## Architecture

PlaiY is split into two layers:

### C++ core (`core/`)

A platform-agnostic static library (`libplaiy_core.a`) that handles all media processing:

- **Demuxer**: FFmpeg `libavformat` for universal container support
- **Video decoder**: VideoToolbox for hardware acceleration, FFmpeg for software fallback
- **Audio decoder**: FFmpeg `libavcodec` with `libswresample` for high-quality resampling
- **Subtitle engine**: Custom SRT parser, libass for ASS/SSA, FFmpeg for PGS
- **Player engine**: Multi-threaded orchestrator with audio-master A-V sync
- **Media library**: Folder scanner with FFmpeg-based metadata probing

### SwiftUI app (`app/`)

The macOS frontend that handles UI and rendering:

- **Metal renderer**: Zero-copy `CVPixelBuffer` to `MTLTexture` pipeline with HDR EDR support
- **Library view**: Grid display with resolution/HDR/codec badges
- **Player view**: Full-screen playback with overlay controls
- **Subtitle overlay**: Text rendering (SRT) and bitmap compositing (ASS/PGS)

The two layers communicate through a pure C API (`plaiy_c.h`), making the core reusable with any UI framework on any platform.

## Supported formats

### Containers
MKV, MP4, AVI, TS, M2TS, MOV, WebM, FLV, WMV, MPEG

### Video codecs
H.264 (AVC), H.265 (HEVC), VP9, AV1 — hardware accelerated via VideoToolbox where supported

### Audio codecs
AAC, AC3, E-AC3, DTS, DTS-HD, TrueHD, FLAC, Opus, Vorbis, MP3, PCM

### Subtitle formats
SRT, ASS/SSA (with full styling), PGS (Blu-ray bitmap)

### HDR formats
HDR10 (SMPTE ST 2084 PQ), HLG (ARIB STD-B67), Dolby Vision (detection)

## Roadmap

- [ ] Chapter navigation
- [ ] Remote HTTP/NFS browsing beyond direct-play URLs
- [ ] Playlist / play queue improvements
- [ ] Subtitle timing adjustment
- [ ] TMDb/OMDb poster art and metadata
- [ ] Picture-in-Picture
- [ ] Frame capture / screenshot
- [ ] Watch history and smart resume (CloudKit sync)
- [ ] Linux target (Vulkan + PulseAudio/PipeWire)
- [ ] Windows target (D3D12 + WASAPI)

## Project structure

```
plaiy/
  CMakeLists.txt                 # Root CMake
  core/
    CMakeLists.txt               # Core library build
    include/
      plaiy/                # Public C++ interfaces
      plaiy_c.h             # C bridge API
    src/
      player_engine.cpp          # Multi-threaded orchestrator
      demuxer/                   # FFmpeg demuxer
      video/                     # Video decoders + factory
      audio/                     # Audio decoder + resampler
      subtitle/                  # SRT, ASS, PGS subtitle engine
      sync/                      # Clock, packet/frame queues
      library/                   # Media scanner + metadata reader
      bridge/                    # C bridge implementation
    platform/apple/              # VideoToolbox, CoreAudio, Metal shaders
  app/
    project.yml                  # XcodeGen spec
    Shared/                      # SwiftUI views + Metal rendering
    macOS/                       # macOS-specific resources
  scripts/
    run.sh                       # Build everything + launch
    build_core.sh                # Build C++ core only
    build_deps.sh                # Install deps via vcpkg (alternative)
```

## License

TBD
