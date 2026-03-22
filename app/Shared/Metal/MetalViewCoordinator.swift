import Metal
import MetalKit
import CoreVideo

struct VideoUniforms {
    var colorSpace: Int32 = 0      // 0=BT.709, 1=BT.2020
    var transferFunc: Int32 = 0    // 0=SDR, 1=PQ, 2=HLG
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
        guard let pipelineState,
              let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else {
            return
        }

        // Acquire a video frame from the player
        let clockUs = playerBridge.position
        guard let framePtr = playerBridge.acquireVideoFrame(targetPts: clockUs) else {
            // No frame available — draw black
            drawBlack(descriptor: descriptor, drawable: drawable)
            return
        }

        defer { playerBridge.releaseVideoFrame(framePtr) }

        // Get CVPixelBuffer from the frame
        guard let pixelBuffer = PlayerBridge.framePixelBuffer(framePtr) else {
            drawBlack(descriptor: descriptor, drawable: drawable)
            return
        }

        // Create Metal textures from CVPixelBuffer (biplanar NV12/P010)
        guard let textureCache else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Y plane (luma)
        var yTexture: CVMetalTexture?
        let yFormat: MTLPixelFormat = PlayerBridge.frameHDRType(framePtr) > 0 ? .r16Unorm : .r8Unorm
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            yFormat, width, height, 0, &yTexture)

        // UV plane (chroma)
        var uvTexture: CVMetalTexture?
        let uvFormat: MTLPixelFormat = PlayerBridge.frameHDRType(framePtr) > 0 ? .rg16Unorm : .rg8Unorm
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

        // Determine color space and transfer function
        var uniforms = VideoUniforms()
        let colorTrc = PlayerBridge.frameColorTrc(framePtr)

        // AVCOL_TRC_SMPTE2084 = 16 (PQ), AVCOL_TRC_ARIB_STD_B67 = 18 (HLG)
        if colorTrc == 16 {
            uniforms.transferFunc = 1 // PQ
            uniforms.colorSpace = 1  // BT.2020
        } else if colorTrc == 18 {
            uniforms.transferFunc = 2 // HLG
            uniforms.colorSpace = 1  // BT.2020
        }

        // Query EDR headroom
        #if os(macOS)
        if let screen = view.window?.screen {
            uniforms.edrHeadroom = Float(screen.maximumExtendedDynamicRangeColorComponentValue)
        }
        #endif
        uniforms.edrHeadroom = max(uniforms.edrHeadroom, 1.0)

        // Render
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

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

        // Flush stale entries from the texture cache
        CVMetalTextureCacheFlush(textureCache, 0)
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
