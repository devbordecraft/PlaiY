import QuartzCore

struct HDRUniformBuilder {

    /// Populate VideoUniforms from frame metadata.
    static func buildVideoUniforms(
        framePtr: UnsafeMutableRawPointer,
        edrHeadroom: Float
    ) -> VideoUniforms {
        var uniforms = VideoUniforms()
        let colorTrc = PlayerBridge.frameColorTrc(framePtr)
        var colorMatrix = PlayerBridge.frameColorSpace(framePtr) // AVCOL_SPC_* (YCbCr matrix)
        let colorRange = PlayerBridge.frameColorRange(framePtr)
        let hdrType = PlayerBridge.frameHDRType(framePtr) // 0=SDR,1=HDR10,2=HDR10+,3=HLG,4=DV

        // DV content: the SPS/VUI often signals color info as "unspecified".
        // Force correct color space based on HDR type.
        if hdrType == 4 { // Dolby Vision
            // If color matrix is unspecified, the base layer is IPTPQc2 (Profile 5).
            if colorMatrix == 0 || colorMatrix == 2 {
                uniforms.colorSpace = 3  // ICtCp / IPTPQc2
                uniforms.transferFunc = 3 // PQ + ICtCp (shader checks this directly)
            } else {
                uniforms.colorSpace = 1  // BT.2020
                uniforms.transferFunc = 1 // PQ
            }

            // Populate DV color matrices from RPU metadata
            if PlayerBridge.frameHasDoviColor(framePtr) {
                uniforms.doviPresent = 1
                struct LogOnce { nonisolated(unsafe) static var done = false }
                if !LogOnce.done {
                    LogOnce.done = true
                    PYLog.info("DV RPU active: doviPresent=1, using per-frame RPU matrices", tag: "HDR")
                }
                if let ycc = PlayerBridge.frameDoviYccToRgb(framePtr) {
                    withUnsafeMutablePointer(to: &uniforms.doviYccToRgb) { ptr in
                        ptr.withMemoryRebound(to: Float.self, capacity: 9) { fp in
                            for i in 0..<9 { fp[i] = ycc.matrix[i] }
                        }
                    }
                    withUnsafeMutablePointer(to: &uniforms.doviYccOffset) { ptr in
                        ptr.withMemoryRebound(to: Float.self, capacity: 3) { fp in
                            for i in 0..<3 { fp[i] = ycc.offset[i] }
                        }
                    }
                }
                if let lms = PlayerBridge.frameDoviRgbToLms(framePtr) {
                    withUnsafeMutablePointer(to: &uniforms.doviRgbToLms) { ptr in
                        ptr.withMemoryRebound(to: Float.self, capacity: 9) { fp in
                            for i in 0..<9 { fp[i] = lms[i] }
                        }
                    }
                }
                if let inv = PlayerBridge.frameDoviLmsToRgb(framePtr) {
                    withUnsafeMutablePointer(to: &uniforms.doviLmsToRgb) { ptr in
                        ptr.withMemoryRebound(to: Float.self, capacity: 9) { fp in
                            for i in 0..<9 { fp[i] = inv[i] }
                        }
                    }
                }

                // L1 per-scene brightness
                if let l1 = PlayerBridge.frameDoviL1(framePtr) {
                    uniforms.doviHasL1 = 1
                    uniforms.doviL1MinPQ = Float(l1.minPQ) / 4095.0
                    uniforms.doviL1MaxPQ = Float(l1.maxPQ) / 4095.0
                    uniforms.doviL1AvgPQ = Float(l1.avgPQ) / 4095.0
                }

                // L2 display trim
                if let l2 = PlayerBridge.frameDoviL2(framePtr) {
                    uniforms.doviHasL2 = 1
                    uniforms.doviL2Slope = Float(l2.slope) / 2048.0
                    uniforms.doviL2Offset = Float(l2.offset) / 2048.0
                    uniforms.doviL2Power = Float(l2.power) / 2048.0
                    uniforms.doviL2ChromaWeight = Float(l2.chromaWeight) / 4095.0
                    uniforms.doviL2SatGain = Float(l2.saturationGain) / 2048.0
                }

                // Reshaping flag
                if PlayerBridge.frameDoviHasReshaping(framePtr) {
                    uniforms.doviHasReshaping = 1
                }
            } else {
                struct FallbackLog { nonisolated(unsafe) static var done = false }
                if !FallbackLog.done {
                    FallbackLog.done = true
                    PYLog.warning("DV Profile 5: no RPU matrices available, using hardcoded fallback", tag: "HDR")
                }
            }
        } else {
            // Transfer function: AVCOL_TRC_SMPTE2084 = 16 (PQ), AVCOL_TRC_ARIB_STD_B67 = 18 (HLG)
            if colorTrc == 16 {
                uniforms.transferFunc = 1 // PQ
            } else if colorTrc == 18 {
                uniforms.transferFunc = 2 // HLG
            }

            // YCbCr color matrix selection (AVCOL_SPC_*)
            if colorMatrix == 9 || colorMatrix == 10 {
                uniforms.colorSpace = 1  // BT.2020
            } else if colorMatrix == 5 || colorMatrix == 6 {
                uniforms.colorSpace = 2  // BT.601
            }
        }

        // AVCOL_RANGE_JPEG = 2 -> full range
        uniforms.colorRange = (colorRange == 2) ? 1 : 0

        // Use HDR metadata from the frame instead of hardcoded defaults
        let maxLum = PlayerBridge.frameMaxLuminance(framePtr) // in 0.0001 cd/m2 units
        let maxCLL = PlayerBridge.frameMaxCLL(framePtr)
        if maxLum > 0 {
            uniforms.maxLuminance = Float(maxLum) / 10000.0 // convert to cd/m2
        }
        if maxCLL > 0 {
            uniforms.maxLuminance = max(uniforms.maxLuminance, Float(maxCLL))
        }

        // Mastering display minimum luminance (for tone mapping black point)
        let minLum = PlayerBridge.frameMinLuminance(framePtr)
        if minLum > 0 {
            uniforms.minLuminance = Float(minLum) / 10000.0 // convert from 0.0001 cd/m2
        }

        // L6 RPU-level MaxCLL/MaxFALL override (more accurate than stream-level SEI)
        if let l6 = PlayerBridge.frameDoviL6(framePtr) {
            if l6.maxCLL > 0 {
                uniforms.maxLuminance = max(uniforms.maxLuminance, Float(l6.maxCLL))
            }
            if l6.maxFALL > 0 {
                uniforms.maxFALL = max(uniforms.maxFALL, Float(l6.maxFALL))
            }
            if l6.minLum > 0 {
                uniforms.minLuminance = Float(l6.minLum) / 10000.0
            }
        }

        uniforms.edrHeadroom = max(edrHeadroom, 1.0)

        // MaxFALL for scene-adaptive static HDR10
        let maxFALL = PlayerBridge.frameMaxFALL(framePtr)
        if maxFALL > 0 {
            uniforms.maxFALL = Float(maxFALL)
        }

        // Chroma subsampling format (0=420, 1=422, 2=444)
        uniforms.chromaFormat = PlayerBridge.frameChromaFormat(framePtr)

        // Populate HDR10+ per-frame dynamic metadata
        if PlayerBridge.frameHasHDR10Plus(framePtr) {
            uniforms.hdr10plusPresent = 1
            uniforms.kneePointX = PlayerBridge.frameHDR10PlusKneeX(framePtr)
            uniforms.kneePointY = PlayerBridge.frameHDR10PlusKneeY(framePtr)
            uniforms.targetMaxLuminance = PlayerBridge.frameHDR10PlusTargetMaxLum(framePtr)

            let anchors = PlayerBridge.frameHDR10PlusAnchors(framePtr)
            uniforms.numBezierAnchors = Int32(anchors.count)
            withUnsafeMutablePointer(to: &uniforms.bezierAnchors) { ptr in
                ptr.withMemoryRebound(to: Float.self, capacity: 15) { floatPtr in
                    for i in 0..<min(anchors.count, 15) {
                        floatPtr[i] = anchors[i]
                    }
                }
            }

            // Per-frame max scene content light (R,G,B)
            uniforms.maxscl = PlayerBridge.frameHDR10PlusMaxSCL(framePtr)
        }

        return uniforms
    }

    /// Returns the DV reshaping LUT data (3072 floats: 3 components x 1024 entries)
    /// if reshaping is active for this frame, nil otherwise.
    static func buildDoviReshapeLUT(framePtr: UnsafeMutableRawPointer) -> [Float]? {
        guard PlayerBridge.frameDoviHasReshaping(framePtr) else { return nil }
        var lut = [Float](repeating: 0, count: 3072)
        for c: Int32 in 0..<3 {
            guard let componentLUT = PlayerBridge.frameDoviReshapeLUT(framePtr, component: c) else {
                return nil
            }
            let offset = Int(c) * 1024
            for i in 0..<1024 {
                lut[offset + i] = componentLUT[i]
            }
        }
        return lut
    }

    /// Determine the CAEDRMetadata for a given transfer function and luminance.
    /// Returns nil for SDR content.
    static func edrMetadata(
        transferFunc: Int32,
        maxLuminance: Float,
        sdrWhite: Float
    ) -> CAEDRMetadata? {
        if transferFunc == 1 || transferFunc == 3 {
            // PQ (HDR10/HDR10+/DV Profile 5 IPTPQc2)
            let maxNits = maxLuminance > 0 ? maxLuminance : 1000.0
            return CAEDRMetadata.hdr10(
                minLuminance: 0.0001,
                maxLuminance: maxNits,
                opticalOutputScale: sdrWhite)
        } else if transferFunc == 2 {
            // HLG
            return CAEDRMetadata.hlg
        }
        return nil
    }
}
