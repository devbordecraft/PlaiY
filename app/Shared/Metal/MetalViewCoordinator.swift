import Metal
import MetalKit
import CoreVideo
import QuartzCore

struct VideoUniforms {
    var colorSpace: Int32 = 0      // 0=BT.709, 1=BT.2020
    var transferFunc: Int32 = 0    // 0=SDR, 1=PQ, 2=HLG
    var colorRange: Int32 = 0      // 0=limited, 1=full
    var edrHeadroom: Float = 1.0
    var maxLuminance: Float = 100.0
    var sdrWhite: Float = 203.0

    // HDR10+ dynamic metadata
    var hdr10plusPresent: Int32 = 0
    var kneePointX: Float = 0.0
    var kneePointY: Float = 0.0
    var numBezierAnchors: Int32 = 0
    var bezierAnchors: (Float, Float, Float, Float, Float,
                        Float, Float, Float, Float, Float,
                        Float, Float, Float, Float, Float) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    var targetMaxLuminance: Float = 0.0

    // HDR10+ per-frame max scene content light (R,G,B) in cd/m2
    var maxscl: (Float, Float, Float) = (0, 0, 0)
}

struct DoviUniforms {
    var present: Int32 = 0

    // Per-component reshaping curves
    var numPivots: (Int32, Int32, Int32) = (0, 0, 0)
    var pivots: ((Float,Float,Float,Float,Float,Float,Float,Float,Float),
                 (Float,Float,Float,Float,Float,Float,Float,Float,Float),
                 (Float,Float,Float,Float,Float,Float,Float,Float,Float)) =
        ((0,0,0,0,0,0,0,0,0),(0,0,0,0,0,0,0,0,0),(0,0,0,0,0,0,0,0,0))
    var polyOrder: ((Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32),
                    (Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32),
                    (Int32,Int32,Int32,Int32,Int32,Int32,Int32,Int32)) =
        ((0,0,0,0,0,0,0,0),(0,0,0,0,0,0,0,0),(0,0,0,0,0,0,0,0))
    var polyCoef: (
        // component 0: 8 pieces x 3 coefficients
        ((Float,Float,Float),(Float,Float,Float),(Float,Float,Float),(Float,Float,Float),
         (Float,Float,Float),(Float,Float,Float),(Float,Float,Float),(Float,Float,Float)),
        // component 1
        ((Float,Float,Float),(Float,Float,Float),(Float,Float,Float),(Float,Float,Float),
         (Float,Float,Float),(Float,Float,Float),(Float,Float,Float),(Float,Float,Float)),
        // component 2
        ((Float,Float,Float),(Float,Float,Float),(Float,Float,Float),(Float,Float,Float),
         (Float,Float,Float),(Float,Float,Float),(Float,Float,Float),(Float,Float,Float))
    ) = (
        ((0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0)),
        ((0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0)),
        ((0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0),(0,0,0))
    )

    // Per-frame brightness
    var minPQ: Float = 0
    var maxPQ: Float = 0
    var avgPQ: Float = 0
    var sourceMaxPQ: Float = 0
    var sourceMinPQ: Float = 0

    // Trim
    var trimSlope: Float = 1.0
    var trimOffset: Float = 0.0
    var trimPower: Float = 1.0
    var trimChromaWeight: Float = 1.0
    var trimSaturationGain: Float = 1.0
}

struct CropUniforms {
    var texOrigin: SIMD2<Float> = SIMD2(0, 0)
    var texScale: SIMD2<Float> = SIMD2(1, 1)
}

class MetalViewCoordinator {
    private let playerBridge: PlayerBridge
    let transport: PlaybackTransport
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var drawableSize: CGSize = .zero

    // Keep CVMetalTextures alive across frames — releasing them invalidates
    // the MTLTexture even if the GPU is still reading from it.
    private var activeYTexture: CVMetalTexture?
    private var activeUVTexture: CVMetalTexture?

    // Track the last rendered frame's PTS to skip redundant renders.
    // At 120Hz ProMotion with 24fps content, 96 of 120 draws are wasteful.
    private var lastRenderedPts: Int64 = Int64.min

    // Track whether we've configured the layer for HDR/SDR to avoid
    // setting CAEDRMetadata on every frame.
    private var currentHDRMode: Int32 = -1 // -1 = unset, 0 = SDR, 1 = PQ, 2 = HLG

    init(playerBridge: PlayerBridge, transport: PlaybackTransport, mtkView: MTKView) {
        guard let device = mtkView.device,
              let commandQueue = device.makeCommandQueue() else {
            fatalError("Metal device or command queue unavailable")
        }
        self.playerBridge = playerBridge
        self.transport = transport
        self.device = device
        self.commandQueue = commandQueue

        // Create texture cache for zero-copy CVPixelBuffer -> MTLTexture
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache

        setupPipeline(mtkView: mtkView)
    }

    private func setupPipeline(mtkView: MTKView) {
        // Load shaders from the default library
        // The metal_shaders.metal file must be included in the Xcode project
        guard let library = device.makeDefaultLibrary() else {
            PYLog.error("Failed to load Metal shader library", tag: "Metal")
            return
        }

        let vertexFunc = library.makeFunction(name: "vertexFullscreen")
        let fragmentFunc = library.makeFunction(name: "fragmentBiplanar")

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunc
        descriptor.fragmentFunction = fragmentFunc
        descriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat

        // Enable alpha blending for subtitle compositing
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            PYLog.error("Failed to create render pipeline: \(error)", tag: "Metal")
        }
    }

    func drawableSizeWillChange(size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let pipelineState else { return }

        // Acquire a video frame from the player BEFORE requesting a drawable.
        // This avoids wasting drawables when we have no new content.
        // Note: targetPts is unused by the C++ implementation — it reads the
        // internal clock directly. Passing 0 avoids a redundant Clock mutex
        // acquisition on every display-link tick (120Hz).
        guard let framePtr = playerBridge.acquireVideoFrame(targetPts: 0) else {
            lastRenderedPts = Int64.min
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }
            drawBlack(descriptor: descriptor, drawable: drawable)
            return
        }

        defer { playerBridge.releaseVideoFrame(framePtr) }

        // Skip redundant renders: if this is the same frame we already rendered,
        // don't request a new drawable or submit GPU work. The display holds
        // the previous content. At 120Hz with 24fps content this skips ~96/120 draws.
        let currentPts = PlayerBridge.framePts(framePtr)
        if currentPts == lastRenderedPts {
            return
        }
        lastRenderedPts = currentPts

        // Get CVPixelBuffer from the frame
        guard let pixelBuffer = PlayerBridge.framePixelBuffer(framePtr) else {
            guard let drawable = view.currentDrawable,
                  let descriptor = view.currentRenderPassDescriptor else { return }
            drawBlack(descriptor: descriptor, drawable: drawable)
            return
        }

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else { return }

        // Create Metal textures from CVPixelBuffer (biplanar NV12/P010)
        guard let textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Detect 10-bit from the actual CVPixelBuffer format, not HDR type.
        // Content can be 10-bit without HDR metadata, or vice versa.
        let pixFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is10bit = (pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange)

        // Y plane (luma)
        var yTexture: CVMetalTexture?
        let yFormat: MTLPixelFormat = is10bit ? .r16Unorm : .r8Unorm
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            yFormat, width, height, 0, &yTexture)

        // UV plane (chroma)
        var uvTexture: CVMetalTexture?
        let uvFormat: MTLPixelFormat = is10bit ? .rg16Unorm : .rg8Unorm
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            uvFormat, width / 2, height / 2, 1, &uvTexture)

        guard let yTex = yTexture.flatMap({ CVMetalTextureGetTexture($0) }),
              let uvTex = uvTexture.flatMap({ CVMetalTextureGetTexture($0) }) else {
            drawBlack(descriptor: descriptor, drawable: drawable)
            return
        }

        // Store CVMetalTextures as instance vars so they survive this scope.
        // Apple docs: "The returned Metal texture is only valid during the
        // lifetime of the CVMetalTexture." Without this the GPU reads from
        // invalidated textures after draw() returns → flicker.
        activeYTexture = yTexture
        activeUVTexture = uvTexture

        // Determine color space, transfer function, and range from frame metadata
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

        // AVCOL_RANGE_JPEG = 2 → full range
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

        // Query EDR headroom from the display.
        #if os(macOS)
        if let screen = view.window?.screen {
            uniforms.edrHeadroom = Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        }
        #else
        uniforms.edrHeadroom = Float(UIScreen.main.currentEDRHeadroom)
        #endif
        uniforms.edrHeadroom = max(uniforms.edrHeadroom, 1.0)

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

        // Populate Dolby Vision per-frame RPU metadata
        var doviUniforms = DoviUniforms()
        if let dovi = PlayerBridge.frameGetDovi(framePtr) {
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
        }

        // Configure CAEDRMetadata so macOS activates HDR mode on the display.
        // Only update when the content type changes to avoid per-frame overhead.
        if uniforms.transferFunc != currentHDRMode {
            currentHDRMode = uniforms.transferFunc
            if let metalLayer = view.layer as? CAMetalLayer {
                if uniforms.transferFunc == 1 {
                    // PQ (HDR10/HDR10+/DV): tell the system the content luminance range.
                    // opticalOutputScale = nits per unit pixel value.
                    // Our shader maps SDR white (203 cd/m²) to pixel value 1.0.
                    let maxNits = uniforms.maxLuminance > 0 ? uniforms.maxLuminance : 1000.0
                    metalLayer.edrMetadata = CAEDRMetadata.hdr10(
                        minLuminance: 0.0001,
                        maxLuminance: maxNits,
                        opticalOutputScale: uniforms.sdrWhite)
                    PYLog.info("HDR mode activated: PQ, max \(maxNits) nits", tag: "Metal")
                } else if uniforms.transferFunc == 2 {
                    // HLG: use the class property (available macOS 10.15+)
                    metalLayer.edrMetadata = CAEDRMetadata.hlg
                    PYLog.info("HDR mode activated: HLG", tag: "Metal")
                } else {
                    // SDR — clear HDR metadata so display returns to SDR mode
                    metalLayer.edrMetadata = nil
                }
            }
        }

        // Snapshot display settings once per frame (written from main thread)
        let settings = transport.displaySettings

        // Auto-crop detection: when requested, grab current pixel buffer
        if transport.pendingCropDetection {
            transport.pendingCropDetection = false
            let retainedBuffer = pixelBuffer  // Swift ARC retains automatically
            let callback = transport.onCropDetected
            DispatchQueue.global(qos: .userInitiated).async { [callback] in
                let crop = BlackBarDetector.detect(pixelBuffer: retainedBuffer)
                DispatchQueue.main.async { callback?(crop) }
            }
        }

        // Compute viewport based on display settings
        let sarNum = PlayerBridge.frameSarNum(framePtr)
        let sarDen = PlayerBridge.frameSarDen(framePtr)
        let viewSize = drawable.layer.drawableSize
        let viewport = computeViewport(
            videoWidth: width, videoHeight: height,
            sarNum: sarNum, sarDen: sarDen,
            viewSize: viewSize, settings: settings)

        // Compute crop uniforms for texture coordinate remapping
        var cropUniforms = CropUniforms()
        if settings.crop.isActive {
            cropUniforms.texOrigin = SIMD2(settings.crop.texOriginX, settings.crop.texOriginY)
            cropUniforms.texScale = SIMD2(settings.crop.texScaleX, settings.crop.texScaleY)
        }

        // Clear to black first (for letterbox/pillarbox bars)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear

        // Render
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.size, index: 0)
        encoder.setFragmentBytes(&doviUniforms, length: MemoryLayout<DoviUniforms>.size, index: 1)
        encoder.setFragmentBytes(&cropUniforms, length: MemoryLayout<CropUniforms>.size, index: 2)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        // Keep CVMetalTextures alive until the GPU finishes this command buffer.
        // Releasing them earlier invalidates the backing MTLTextures.
        let retainY = yTexture
        let retainUV = uvTexture
        commandBuffer.addCompletedHandler { _ in
            _ = retainY
            _ = retainUV
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func computeViewport(
        videoWidth: Int, videoHeight: Int,
        sarNum: Int32, sarDen: Int32,
        viewSize: CGSize,
        settings: VideoDisplaySettings
    ) -> MTLViewport {
        let nativeDAR = (Double(videoWidth) * Double(sarNum)) /
                        (Double(videoHeight) * Double(max(sarDen, 1)))

        // Effective DAR: adjust for crop in auto/fill modes, or use forced ratio
        var effectiveDAR: Double
        if let forced = settings.aspectRatioMode.forcedDAR {
            effectiveDAR = forced
        } else {
            effectiveDAR = nativeDAR
            if settings.crop.isActive {
                effectiveDAR *= Double(settings.crop.texScaleX) /
                               Double(settings.crop.texScaleY)
            }
        }

        let viewW = Double(viewSize.width)
        let viewH = Double(viewSize.height)
        let viewAR = viewW / viewH
        var vpW = viewW
        var vpH = viewH

        switch settings.aspectRatioMode {
        case .stretch:
            break // Fill entire view, no aspect correction

        case .fill:
            // Invert fit: overflow the shorter dimension so no black bars remain
            if effectiveDAR > viewAR {
                // Video wider: expand height to fill, width overflows
                vpW = viewH * effectiveDAR
                vpH = viewH
            } else if effectiveDAR < viewAR {
                // Video taller: expand width to fill, height overflows
                vpH = viewW / effectiveDAR
                vpW = viewW
            }

        default:
            // Fit with letterbox/pillarbox
            if effectiveDAR > viewAR {
                vpH = vpW / effectiveDAR
            } else if effectiveDAR < viewAR {
                vpW = vpH * effectiveDAR
            }
        }

        // Apply zoom (minimum 1x)
        let zoom = max(1.0, settings.zoom)
        vpW *= zoom
        vpH *= zoom

        // Center, then apply pan offset
        var vpX = (viewW - vpW) / 2.0
        var vpY = (viewH - vpH) / 2.0

        // Pan: map normalized [-1,1] to the max pan range (how much the viewport overflows)
        let maxPanX = max(0, (vpW - viewW) / 2.0)
        let maxPanY = max(0, (vpH - viewH) / 2.0)
        vpX += settings.panX * maxPanX
        vpY += settings.panY * maxPanY

        return MTLViewport(originX: vpX, originY: vpY,
                           width: vpW, height: vpH,
                           znear: 0, zfar: 1)
    }

    private func drawBlack(descriptor: MTLRenderPassDescriptor, drawable: CAMetalDrawable) {
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
