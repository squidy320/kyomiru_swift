import AVFoundation
import SwiftUI
#if os(iOS)
import Metal
#endif

#if os(iOS)
import UIKit
typealias PlatformView = UIView
#elseif os(macOS)
import AppKit
typealias PlatformView = NSView
#endif

final class SampleBufferDisplayView: PlatformView {
    private(set) var displayLayer: AVSampleBufferDisplayLayer

#if os(iOS)
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
#endif

    override init(frame: CGRect) {
        displayLayer = AVSampleBufferDisplayLayer()
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        displayLayer = AVSampleBufferDisplayLayer()
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
#if os(iOS)
        if let layer = self.layer as? AVSampleBufferDisplayLayer {
            displayLayer = layer
        } else {
            layer.addSublayer(displayLayer)
        }
#else
        wantsLayer = true
        layer = displayLayer
#endif
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

#if os(iOS)
    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
    }
#else
    override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }
#endif
}

#if os(iOS)
struct SampleBufferDisplayRepresentable: UIViewRepresentable {
    let onViewReady: (SampleBufferDisplayView) -> Void

    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        view.isUserInteractionEnabled = false
        view.isOpaque = false
        view.alpha = 0.01
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        onViewReady(view)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {
        // Avoid reattaching the layer on every SwiftUI update to prevent flashing.
    }
}

final class MetalRenderView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }

    var metalLayer: CAMetalLayer {
        layer as! CAMetalLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.scale
        metalLayer.pixelFormat = .bgra8Unorm
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
    }
}

struct MetalLayerRepresentable: UIViewRepresentable {
    let onLayerReady: (CAMetalLayer) -> Void

    func makeUIView(context: Context) -> MetalRenderView {
        let view = MetalRenderView()
        onLayerReady(view.metalLayer)
        return view
    }

    func updateUIView(_ uiView: MetalRenderView, context: Context) {
        // Avoid reattaching the layer on every SwiftUI update.
    }
}
#else
struct SampleBufferDisplayRepresentable: NSViewRepresentable {
    let onViewReady: (SampleBufferDisplayView) -> Void

    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        onViewReady(view)
        return view
    }

    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        // Avoid reattaching the layer on every SwiftUI update to prevent flashing.
    }
}
#endif
