#include "metal_video_renderer.h"
// This file is intentionally minimal.
// The Metal rendering pipeline is implemented in Swift (MetalViewCoordinator.swift)
// because the CAMetalLayer is owned by the SwiftUI view hierarchy.
//
// The C++ core provides:
// 1. Decoded VideoFrames with CVPixelBufferRef (via py_player_acquire_video_frame)
// 2. HDR metadata and color space info (via py_player_frame_get_*)
// 3. Metal shader source (metal_shaders.metal)
//
// The Swift side handles:
// - CAMetalLayer setup and configuration
// - CVDisplayLink / CADisplayLink integration
// - CVMetalTextureCache for zero-copy texture creation
// - Render pipeline setup and draw calls
// - EDR configuration (wantsExtendedDynamicRangeContent, CAEDRMetadata)
