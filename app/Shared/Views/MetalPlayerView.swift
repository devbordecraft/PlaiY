import SwiftUI
import Metal
import MetalKit
import CoreVideo

#if os(macOS)
struct MetalPlayerView: NSViewRepresentable {
    let playerBridge: PlayerBridge

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .rgba16Float
        mtkView.framebufferOnly = false
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        // Render at the display's native refresh rate (e.g. 120Hz ProMotion).
        // The system caps this at the actual display maximum.
        mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120

        if let layer = mtkView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }

        let coordinator = MetalViewCoordinator(playerBridge: playerBridge, mtkView: mtkView)
        context.coordinator.inner = coordinator
        mtkView.delegate = context.coordinator

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var inner: MetalViewCoordinator?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            inner?.drawableSizeWillChange(size: size)
        }

        func draw(in view: MTKView) {
            inner?.draw(in: view)
        }
    }
}
#else
struct MetalPlayerView: UIViewRepresentable {
    let playerBridge: PlayerBridge

    func makeUIView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .rgba16Float
        mtkView.framebufferOnly = false
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false

        // Render at the display's native refresh rate (e.g. 120Hz ProMotion).
        mtkView.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond

        if let layer = mtkView.layer as? CAMetalLayer {
            layer.wantsExtendedDynamicRangeContent = true
            layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        }

        let coordinator = MetalViewCoordinator(playerBridge: playerBridge, mtkView: mtkView)
        context.coordinator.inner = coordinator
        mtkView.delegate = context.coordinator

        return mtkView
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, MTKViewDelegate {
        var inner: MetalViewCoordinator?

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            inner?.drawableSizeWillChange(size: size)
        }

        func draw(in view: MTKView) {
            inner?.draw(in: view)
        }
    }
}
#endif
