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

    // MaxFALL (Maximum Frame Average Light Level) in cd/m2
    var maxFALL: Float = 0.0

    // Chroma subsampling format: 0=4:2:0, 1=4:2:2, 2=4:4:4
    var chromaFormat: Int32 = 0

    // Dolby Vision color matrices (from RPU metadata)
    var doviPresent: Int32 = 0
    var doviYccToRgb: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (0,0,0,0,0,0,0,0,0)
    var doviYccOffset: (Float, Float, Float) = (0, 0, 0)
    var doviRgbToLms: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (0,0,0,0,0,0,0,0,0)

    // DV pre-inverted LMS-to-RGB matrix
    var doviLmsToRgb: (Float, Float, Float, Float, Float, Float, Float, Float, Float) = (0,0,0,0,0,0,0,0,0)

    // DV L1 per-scene brightness metadata
    var doviHasL1: Int32 = 0
    var doviL1MinPQ: Float = 0.0   // PQ-encoded [0,1] (raw / 4095)
    var doviL1MaxPQ: Float = 1.0
    var doviL1AvgPQ: Float = 0.0

    // DV L2 display trim metadata
    var doviHasL2: Int32 = 0
    var doviL2Slope: Float = 1.0    // normalized (raw / 2048)
    var doviL2Offset: Float = 1.0
    var doviL2Power: Float = 1.0
    var doviL2ChromaWeight: Float = 0.0
    var doviL2SatGain: Float = 1.0

    // DV reshaping present flag (LUT data passed as separate texture)
    var doviHasReshaping: Int32 = 0

    // Source bit depth (8 or 10)
    var bitDepth: Int32 = 8

    // Mastering display minimum luminance (cd/m2, from MDCV SEI)
    var minLuminance: Float = 0.0
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
    private var lastEDRMaxLuminance: Float = 0

    // Cached EDR headroom — refreshed every frame during HDR playback
    private var cachedEDRHeadroom: Float = 1.0
    // Display's theoretical maximum EDR — used to request elevated headroom
    private var displayPotentialHeadroom: Float = 1.0
    private var screenObserver: NSObjectProtocol?

    // Periodic texture cache flush counter
    private var framesSinceFlush: Int = 0

    // Frame counter for temporal dithering (wraps on overflow)
    private var frameCounter: UInt32 = 0

    // DV reshape LUT buffer (3 components x 1024 entries x 4 bytes = 12KB)
    private var reshapeLUTBuffer: MTLBuffer?
    private var reshapeLUTFingerprint: UInt64 = 0
    private var reshapeLUTValid = false

    // Blue noise texture for dithering (64x64, single-channel)
    private var blueNoiseTexture: MTLTexture?

    // Display link rate management — drop to 4fps when paused to save power
    private weak var mtkView: MTKView?
    private var wasPlaying = true

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

        self.mtkView = mtkView
        setupPipeline(mtkView: mtkView)
        blueNoiseTexture = Self.createBlueNoiseTexture(device: device)

        #if os(macOS)
        updateEDRHeadroom(window: mtkView.window)
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in
                self?.updateEDRHeadroom(window: nil)
            }
        #endif
    }

    deinit {
        if let obs = screenObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private func updateEDRHeadroom(window: NSWindow?) {
        #if os(macOS)
        let screen = window?.screen ?? NSScreen.main
        let newHeadroom = Float(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
        displayPotentialHeadroom = Float(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1.0)
        if abs(newHeadroom - cachedEDRHeadroom) > 0.1 {
            PYLog.info("EDR headroom: \(cachedEDRHeadroom) -> \(newHeadroom) (potential: \(displayPotentialHeadroom))", tag: "Metal")
        }
        cachedEDRHeadroom = newHeadroom
        #else
        cachedEDRHeadroom = Float(UIScreen.main.currentEDRHeadroom)
        #endif
    }

    /// Derives the effective max luminance for CAEDRMetadata.
    /// When DV L1 metadata is present, converts the per-scene max PQ to nits
    /// via ST.2084 inverse EOTF. Falls back to stream-level maxLuminance.
    private static func effectiveMaxLuminance(uniforms: VideoUniforms) -> Float {
        if uniforms.doviHasL1 != 0, uniforms.doviL1MaxPQ > 0 {
            // ST.2084 PQ EOTF: PQ [0,1] -> linear [0,10000] cd/m2
            let pq = Double(uniforms.doviL1MaxPQ)
            let m1 = 0.1593017578125
            let m2 = 78.84375
            let c1 = 0.8359375
            let c2 = 18.8515625
            let c3 = 18.6875
            let np = pow(max(pq, 0.0), 1.0 / m2)
            let L = pow(max(np - c1, 0.0) / max(c2 - c3 * np, 1e-10), 1.0 / m1)
            return max(Float(L * 10000.0), 100.0)
        }
        return uniforms.maxLuminance
    }

    private func reshapeLUTBufferIfNeeded(framePtr: UnsafeMutableRawPointer) -> MTLBuffer? {
        guard PlayerBridge.frameDoviHasReshaping(framePtr) else { return nil }

        let fingerprint = PlayerBridge.frameDoviReshapeFingerprint(framePtr)
        guard fingerprint != 0 else {
            reshapeLUTValid = false
            return nil
        }

        if !reshapeLUTValid || reshapeLUTFingerprint != fingerprint {
            guard let lutData = HDRUniformBuilder.buildDoviReshapeLUT(framePtr: framePtr) else {
                reshapeLUTValid = false
                return nil
            }

            let byteCount = lutData.count * MemoryLayout<Float>.size
            if reshapeLUTBuffer == nil || reshapeLUTBuffer!.length < byteCount {
                reshapeLUTBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
            }
            guard let buffer = reshapeLUTBuffer else {
                reshapeLUTValid = false
                return nil
            }

            lutData.withUnsafeBufferPointer { ptr in
                memcpy(buffer.contents(), ptr.baseAddress!, byteCount)
            }
            reshapeLUTFingerprint = fingerprint
            reshapeLUTValid = true
        }

        return reshapeLUTBuffer
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

    /// Create a 64×64 blue noise texture for dithering using a rank-1 lattice sequence.
    /// This produces a low-discrepancy pattern that looks like grain rather than a grid.
    private static func createBlueNoiseTexture(device: MTLDevice) -> MTLTexture? {
        let size = 64
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: size, height: size, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }

        // Generate blue noise via void-and-cluster inspired rank ordering.
        // Use the R2 low-discrepancy sequence (generalized golden ratio in 2D)
        // to scatter sample points, then rank-order by insertion index.
        let n = size * size
        var values = [UInt8](repeating: 0, count: n)
        let g = 1.32471795724  // plastic constant (tribonacci)
        let a1 = 1.0 / g
        let a2 = 1.0 / (g * g)
        // Generate sequence positions and rank by spatial coverage
        var sequence = [(Int, Int)](repeating: (0, 0), count: n)
        for i in 0..<n {
            let x = Int((Double(i) * a1).truncatingRemainder(dividingBy: 1.0) * Double(size)) % size
            let y = Int((Double(i) * a2).truncatingRemainder(dividingBy: 1.0) * Double(size)) % size
            sequence[i] = (x, y)
        }
        // Rank maps sequence index → pixel value (0..255)
        for i in 0..<n {
            let (x, y) = sequence[i]
            values[y * size + x] = UInt8(clamping: i * 256 / n)
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: values,
            bytesPerRow: size)
        return texture
    }

    func drawableSizeWillChange(size: CGSize) {
        drawableSize = size
    }

    func draw(in view: MTKView) {
        guard let pipelineState else { return }
        let drawTrace = PYSignpost.begin("MetalDraw", category: .render)
        defer { drawTrace.end() }

        // Acquire a video frame from the player BEFORE requesting a drawable.
        // This avoids wasting drawables when we have no new content.
        // Note: targetPts is unused by the C++ implementation — it reads the
        // internal clock directly. Passing 0 avoids a redundant Clock mutex
        // acquisition on every display-link tick (120Hz).
        guard let framePtr = playerBridge.acquireVideoFrame(targetPts: 0) else {
            // Release textures so IOSurface-backed buffers are freed after stop
            if activeYTexture != nil {
                activeYTexture = nil
                activeUVTexture = nil
            }
            lastRenderedPts = Int64.min
            // Reset HDR state so the display returns to normal brightness
            if currentHDRMode > 0, let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.edrMetadata = nil
                metalLayer.preferredDynamicRange = .standard
                currentHDRMode = 0
                transport.isHDRContent = false
                cachedEDRHeadroom = 1.0
                lastEDRMaxLuminance = 0
            }
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
        frameCounter &+= 1

        // Adjust display link rate when playback state changes.
        // Drop to 4fps when paused to save power; restore full rate on play.
        let isPlaying = transport.isPlaying
        if isPlaying != wasPlaying {
            wasPlaying = isPlaying
            #if os(macOS)
            let fps = isPlaying ? (mtkView?.window?.screen?.maximumFramesPerSecond ?? 120) : 4
            #else
            let fps = isPlaying ? UIScreen.main.maximumFramesPerSecond : 4
            #endif
            mtkView?.preferredFramesPerSecond = fps
        }

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

        // Detect pixel format from the actual CVPixelBuffer type.
        let pixFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let is10bit = (pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange ||
                       pixFmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange ||
                       pixFmt == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)
        let is422 = (pixFmt == kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange ||
                     pixFmt == kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange)

        // Y plane (luma)
        var yTexture: CVMetalTexture?
        let yFormat: MTLPixelFormat = is10bit ? .r16Unorm : .r8Unorm
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            yFormat, width, height, 0, &yTexture)

        // UV plane (chroma) — dimensions depend on chroma subsampling:
        //   4:2:0: width/2, height/2
        //   4:2:2: width/2, height (full vertical resolution)
        var uvTexture: CVMetalTexture?
        let uvFormat: MTLPixelFormat = is10bit ? .rg16Unorm : .rg8Unorm
        let uvHeight = is422 ? height : height / 2
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            uvFormat, width / 2, uvHeight, 1, &uvTexture)

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

        // Refresh EDR headroom during HDR playback (tracks ramp-up and throttling).
        // Skip during SDR — headroom is always 1.0 and querying is wasteful.
        #if os(macOS)
        if currentHDRMode > 0, let window = view.window {
            updateEDRHeadroom(window: window)
        }
        #else
        cachedEDRHeadroom = Float(UIScreen.main.currentEDRHeadroom)
        #endif

        // Build HDR uniforms from frame metadata
        var uniforms = HDRUniformBuilder.buildVideoUniforms(
            framePtr: framePtr, edrHeadroom: cachedEDRHeadroom)
        uniforms.bitDepth = is10bit ? 10 : 8

        let reshapeBuffer = uniforms.doviHasReshaping != 0
            ? reshapeLUTBufferIfNeeded(framePtr: framePtr)
            : nil
        if uniforms.doviHasReshaping != 0, reshapeBuffer == nil {
            uniforms.doviHasReshaping = 0
        }

        #if DEBUG
        DVDebugLogger.shared.log(
            uniforms: uniforms,
            reshapingActive: reshapeBuffer != nil && uniforms.doviHasReshaping != 0,
            edrHeadroom: cachedEDRHeadroom)
        #endif

        // Configure CAEDRMetadata and request elevated display headroom.
        // Update dynamic range mode when content type changes (SDR <-> HDR).
        let effectiveMaxLum = Self.effectiveMaxLuminance(uniforms: uniforms)
        if uniforms.transferFunc != currentHDRMode {
            currentHDRMode = uniforms.transferFunc
            transport.isHDRContent = uniforms.transferFunc > 0
            if let metalLayer = view.layer as? CAMetalLayer {
                metalLayer.edrMetadata = HDRUniformBuilder.edrMetadata(
                    transferFunc: uniforms.transferFunc,
                    maxLuminance: effectiveMaxLum,
                    sdrWhite: uniforms.sdrWhite)
                lastEDRMaxLuminance = effectiveMaxLum
                if uniforms.transferFunc > 0 {
                    metalLayer.preferredDynamicRange = .high
                    PYLog.info("Requesting full EDR dynamic range (potential: \(displayPotentialHeadroom))", tag: "Metal")
                } else {
                    metalLayer.preferredDynamicRange = .standard
                }
                #if os(macOS)
                updateEDRHeadroom(window: view.window)
                #endif
                if uniforms.transferFunc == 1 {
                    let maxNits = uniforms.maxLuminance > 0 ? uniforms.maxLuminance : 1000.0
                    PYLog.info("HDR mode activated: PQ, max \(maxNits) nits", tag: "Metal")
                } else if uniforms.transferFunc == 2 {
                    PYLog.info("HDR mode activated: HLG", tag: "Metal")
                } else if uniforms.transferFunc == 3 {
                    PYLog.info("HDR mode activated: DV Profile 5 (IPTPQc2)", tag: "Metal")
                }
            }
        } else if currentHDRMode > 0 {
            // Per-scene EDR metadata update: when DV L1 metadata indicates
            // a significant scene peak change, update CAEDRMetadata so the
            // display can ramp headroom for bright scenes.
            let delta = abs(effectiveMaxLum - lastEDRMaxLuminance)
            let threshold = max(50.0, lastEDRMaxLuminance * 0.1)
            if delta > threshold {
                if let metalLayer = view.layer as? CAMetalLayer {
                    metalLayer.edrMetadata = HDRUniformBuilder.edrMetadata(
                        transferFunc: uniforms.transferFunc,
                        maxLuminance: effectiveMaxLum,
                        sdrWhite: uniforms.sdrWhite)
                    lastEDRMaxLuminance = effectiveMaxLum
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
        if let blueNoise = blueNoiseTexture {
            encoder.setFragmentTexture(blueNoise, index: 2)
        }
        var colorFilterUniforms = ColorFilterUniformBuilder.build(playerBridge: playerBridge, frameCounter: frameCounter)

        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.size, index: 0)
        encoder.setFragmentBytes(&cropUniforms, length: MemoryLayout<CropUniforms>.size, index: 1)
        encoder.setFragmentBytes(&colorFilterUniforms, length: MemoryLayout<ColorFilterUniforms>.size, index: 2)

        // Bind DV reshaping LUT buffer (12KB = 3072 floats, exceeds setFragmentBytes 4KB limit)
        if let reshapeBuffer {
            encoder.setFragmentBuffer(reshapeBuffer, offset: 0, index: 3)
        } else {
            // Shader declares buffer(3) — bind a dummy to avoid validation errors
            var zero: Float = 0
            encoder.setFragmentBytes(&zero, length: MemoryLayout<Float>.size, index: 3)
        }

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

        // Periodically flush the texture cache to release unused textures
        framesSinceFlush += 1
        if framesSinceFlush >= 300 {
            framesSinceFlush = 0
            CVMetalTextureCacheFlush(textureCache, 0)
        }
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
