import SwiftUI
import AVFoundation

#if os(macOS)

struct DVDisplayLayerView: NSViewRepresentable {
    let playerBridge: PlayerBridge

    func makeNSView(context: Context) -> DVDisplayNSView {
        let view = DVDisplayNSView()
        playerBridge.setDVDisplayLayer(view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: DVDisplayNSView, context: Context) {}
}

class DVDisplayNSView: NSView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Enable extended dynamic range on the layer tree
        layer!.preferredDynamicRange = .high
        layer!.addSublayer(displayLayer)
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor.black
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        displayLayer.preferredDynamicRange = .high
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

#else

struct DVDisplayLayerView: UIViewRepresentable {
    let playerBridge: PlayerBridge

    func makeUIView(context: Context) -> DVDisplayUIView {
        let view = DVDisplayUIView()
        playerBridge.setDVDisplayLayer(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DVDisplayUIView, context: Context) {}
}

class DVDisplayUIView: UIView {
    let displayLayer = AVSampleBufferDisplayLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(displayLayer)
        layer.preferredDynamicRange = .high
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
        displayLayer.preferredDynamicRange = .high
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }
}

#endif
