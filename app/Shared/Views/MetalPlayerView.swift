import SwiftUI
import Metal
import MetalKit
import CoreVideo

private func configureMTKView(playerBridge: PlayerBridge, context: MetalPlayerView.Context) -> MTKView {
    let mtkView = MTKView()
    mtkView.device = MTLCreateSystemDefaultDevice()
    mtkView.colorPixelFormat = .rgba16Float
    mtkView.framebufferOnly = false
    mtkView.isPaused = false
    mtkView.enableSetNeedsDisplay = false

    #if os(macOS)
    mtkView.preferredFramesPerSecond = NSScreen.main?.maximumFramesPerSecond ?? 120
    #else
    mtkView.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
    #endif

    if let layer = mtkView.layer as? CAMetalLayer {
        layer.wantsExtendedDynamicRangeContent = true
        layer.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
    }

    let coordinator = MetalViewCoordinator(playerBridge: playerBridge, mtkView: mtkView)
    context.coordinator.inner = coordinator
    mtkView.delegate = context.coordinator

    return mtkView
}

#if os(macOS)
struct MetalPlayerView: NSViewRepresentable {
    let playerBridge: PlayerBridge

    func makeNSView(context: Context) -> MTKView {
        configureMTKView(playerBridge: playerBridge, context: context)
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MTKViewDelegate {
        var inner: MetalViewCoordinator?
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            inner?.drawableSizeWillChange(size: size)
        }
        func draw(in view: MTKView) { inner?.draw(in: view) }
    }
}
#else
struct MetalPlayerView: UIViewRepresentable {
    let playerBridge: PlayerBridge

    func makeUIView(context: Context) -> MTKView {
        configureMTKView(playerBridge: playerBridge, context: context)
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator: NSObject, MTKViewDelegate {
        var inner: MetalViewCoordinator?
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            inner?.drawableSizeWillChange(size: size)
        }
        func draw(in view: MTKView) { inner?.draw(in: view) }
    }
}
#endif
