import QuartzCore

struct HDRUniformBuilder {

    /// Populate VideoUniforms from frame metadata.
    static func buildVideoUniforms(
        framePtr: UnsafeMutableRawPointer,
        edrHeadroom: Float
    ) -> VideoUniforms {
        var uniforms = VideoUniforms()
        let colorTrc = PlayerBridge.frameColorTrc(framePtr)
        let colorPrimaries = PlayerBridge.frameColorPrimaries(framePtr)
        let colorRange = PlayerBridge.frameColorRange(framePtr)

        // Transfer function: AVCOL_TRC_SMPTE2084 = 16 (PQ), AVCOL_TRC_ARIB_STD_B67 = 18 (HLG)
        if colorTrc == 16 {
            uniforms.transferFunc = 1 // PQ
        } else if colorTrc == 18 {
            uniforms.transferFunc = 2 // HLG
        }

        // Color space matrix: AVCOL_PRI_BT2020 = 9
        if colorPrimaries == 9 {
            uniforms.colorSpace = 1  // BT.2020
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

        uniforms.edrHeadroom = max(edrHeadroom, 1.0)

        // MaxFALL for scene-adaptive static HDR10
        let maxFALL = PlayerBridge.frameMaxFALL(framePtr)
        if maxFALL > 0 {
            uniforms.maxFALL = Float(maxFALL)
        }

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

    /// Populate DoviUniforms from frame's DV RPU metadata.
    /// Returns default (present=0) if no DV metadata is available.
    static func buildDoviUniforms(framePtr: UnsafeMutableRawPointer) -> DoviUniforms {
        var doviUniforms = DoviUniforms()
        guard let dovi = PlayerBridge.frameGetDovi(framePtr) else {
            return doviUniforms
        }

        doviUniforms.present = 1
        doviUniforms.minPQ = dovi.min_pq
        doviUniforms.maxPQ = dovi.max_pq
        doviUniforms.avgPQ = dovi.avg_pq
        doviUniforms.sourceMaxPQ = dovi.source_max_pq
        doviUniforms.sourceMinPQ = dovi.source_min_pq
        doviUniforms.trimSlope = dovi.trim_slope
        doviUniforms.trimOffset = dovi.trim_offset
        doviUniforms.trimPower = dovi.trim_power
        doviUniforms.trimChromaWeight = dovi.trim_chroma_weight
        doviUniforms.trimSaturationGain = dovi.trim_saturation_gain

        // Copy reshaping curves from C struct tuples into DoviUniforms.
        // C arrays are imported as tuples in Swift; use withMemoryRebound
        // to bulk-copy the flat memory layout.
        withUnsafePointer(to: dovi.curves) { srcPtr in
            srcPtr.withMemoryRebound(to: PYDoviCurve.self, capacity: 3) { curves in
                for c in 0..<3 {
                    withUnsafeMutablePointer(to: &doviUniforms.numPivots) { p in
                        p.withMemoryRebound(to: Int32.self, capacity: 3) { dst in
                            dst[c] = curves[c].num_pivots
                        }
                    }
                    withUnsafePointer(to: curves[c].pivots) { src in
                        src.withMemoryRebound(to: Float.self, capacity: 9) { srcF in
                            withUnsafeMutablePointer(to: &doviUniforms.pivots) { dst in
                                dst.withMemoryRebound(to: Float.self, capacity: 27) { dstF in
                                    for i in 0..<9 { dstF[c * 9 + i] = srcF[i] }
                                }
                            }
                        }
                    }
                    withUnsafePointer(to: curves[c].poly_order) { src in
                        src.withMemoryRebound(to: Int32.self, capacity: 8) { srcI in
                            withUnsafeMutablePointer(to: &doviUniforms.polyOrder) { dst in
                                dst.withMemoryRebound(to: Int32.self, capacity: 24) { dstI in
                                    for i in 0..<8 { dstI[c * 8 + i] = srcI[i] }
                                }
                            }
                        }
                    }
                    withUnsafePointer(to: curves[c].poly_coef) { src in
                        src.withMemoryRebound(to: Float.self, capacity: 24) { srcF in
                            withUnsafeMutablePointer(to: &doviUniforms.polyCoef) { dst in
                                dst.withMemoryRebound(to: Float.self, capacity: 72) { dstF in
                                    for i in 0..<24 { dstF[c * 24 + i] = srcF[i] }
                                }
                            }
                        }
                    }
                }
            }
        }

        return doviUniforms
    }

    /// Determine the CAEDRMetadata for a given transfer function and luminance.
    /// Returns nil for SDR content.
    static func edrMetadata(
        transferFunc: Int32,
        maxLuminance: Float,
        sdrWhite: Float
    ) -> CAEDRMetadata? {
        if transferFunc == 1 {
            // PQ (HDR10/HDR10+/DV)
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
