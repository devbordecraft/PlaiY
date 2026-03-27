#pragma once

// This header provides C++ constants and helpers for Metal rendering.
// The actual Metal rendering is driven from Swift (MetalViewCoordinator.swift).
// This file provides shared constants used by both the C++ core and Swift.

namespace py {

struct VideoRenderConstants {
    // Color space IDs matching VideoUniforms.colorSpace in metal_shaders.metal
    static constexpr int COLOR_SPACE_BT709 = 0;
    static constexpr int COLOR_SPACE_BT2020 = 1;
    static constexpr int COLOR_SPACE_BT601 = 2;

    // Transfer function IDs matching VideoUniforms.transferFunc
    static constexpr int TRANSFER_SDR = 0;
    static constexpr int TRANSFER_PQ = 1;   // HDR10
    static constexpr int TRANSFER_HLG = 2;  // HLG

    // Default SDR reference white in cd/m2
    static constexpr float SDR_WHITE_NITS = 203.0f;
};

} // namespace py
