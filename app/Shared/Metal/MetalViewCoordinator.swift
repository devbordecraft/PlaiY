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
}

class MetalViewCoordinator {
    private let playerBridge: PlayerBridge
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

    init(playerBridge: PlayerBridge, mtkView: MTKView) {
        self.playerBridge = playerBridge
        self.device = mtkView.device!
        self.commandQueue = device.makeCommandQueue()!

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
        let clockUs = playerBridge.position
        guard let framePtr = playerBridge.acquireVideoFrame(targetPts: clockUs) else {
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
        // Use maximumPotentialExtendedDynamicRangeColorComponentValue (hardware capability)
        // instead of maximumExtendedDynamicRangeColorComponentValue (current state),
        // because the latter is 1.0 until the system detects HDR content — creating a
        // chicken-and-egg problem where tone mapping clips to 1.0 and EDR never activates.
        #if os(macOS)
        if let screen = view.window?.screen {
            uniforms.edrHeadroom = Float(screen.maximumPotentialExtendedDynamicRangeColorComponentValue)
        }
        #endif
        uniforms.edrHeadroom = max(uniforms.edrHeadroom, 1.0)

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

        // Calculate viewport to preserve display aspect ratio.
        // DAR = (coded_width * SAR_num) / (coded_height * SAR_den)
        let sarNum = PlayerBridge.frameSarNum(framePtr)
        let sarDen = PlayerBridge.frameSarDen(framePtr)
        let videoDAR = (Double(width) * Double(sarNum)) / (Double(height) * Double(sarDen))
        let viewSize = drawable.layer.drawableSize
        let viewAR = Double(viewSize.width) / Double(viewSize.height)

        var vpX: Double = 0
        var vpY: Double = 0
        var vpW = Double(viewSize.width)
        var vpH = Double(viewSize.height)

        if videoDAR > viewAR {
            // Video wider than view → pillarbox (black bars top/bottom)
            vpH = vpW / videoDAR
            vpY = (Double(viewSize.height) - vpH) / 2.0
        } else if videoDAR < viewAR {
            // Video taller than view → letterbox (black bars left/right)
            vpW = vpH * videoDAR
            vpX = (Double(viewSize.width) - vpW) / 2.0
        }

        // Clear to black first (for letterbox/pillarbox bars)
        descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        descriptor.colorAttachments[0].loadAction = .clear

        // Render
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        let viewport = MTLViewport(originX: vpX, originY: vpY,
                                   width: vpW, height: vpH,
                                   znear: 0, zfar: 1)
        encoder.setViewport(viewport)
        encoder.setRenderPipelineState(pipelineState)
        encoder.setFragmentTexture(yTex, index: 0)
        encoder.setFragmentTexture(uvTex, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VideoUniforms>.size, index: 0)
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
