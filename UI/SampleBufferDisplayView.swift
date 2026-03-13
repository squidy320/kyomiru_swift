import AVFoundation
import SwiftUI

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
    let onLayerReady: (AVSampleBufferDisplayLayer) -> Void

    func makeUIView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        onLayerReady(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: SampleBufferDisplayView, context: Context) {
        // Avoid reattaching the layer on every SwiftUI update to prevent flashing.
    }
}
#else
struct SampleBufferDisplayRepresentable: NSViewRepresentable {
    let onLayerReady: (AVSampleBufferDisplayLayer) -> Void

    func makeNSView(context: Context) -> SampleBufferDisplayView {
        let view = SampleBufferDisplayView()
        onLayerReady(view.displayLayer)
        return view
    }

    func updateNSView(_ nsView: SampleBufferDisplayView, context: Context) {
        // Avoid reattaching the layer on every SwiftUI update to prevent flashing.
    }
}
#endif
