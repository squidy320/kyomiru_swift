import AVFoundation
import Foundation
import SwiftUI

#if canImport(Libmpv)
import Libmpv

@MainActor
final class MPVPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1
    @Published var errorMessage: String?

    private let core = MPVCore()
    private var statusTimer: Timer?

    func attach(layer: AVSampleBufferDisplayLayer) {
        core.attach(layer: layer)
    }

    func load(url: URL, headers: [String: String], startTime: Double?) {
        core.load(url: url, headers: headers, startTime: startTime)
        startStatusTimer()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        core.setPaused(false)
        isPlaying = true
        scheduleAutoRefresh()
    }

    func pause() {
        core.setPaused(true)
        isPlaying = false
    }

    func seek(to seconds: Double) {
        core.seek(to: seconds)
        scheduleAutoRefresh()
    }

    func seekBy(_ delta: Double) {
        core.seekBy(delta)
        scheduleAutoRefresh()
    }

    func setRate(_ value: Double) {
        rate = value
        core.setRate(value)
    }

    func shutdown() {
        statusTimer?.invalidate()
        statusTimer = nil
        core.shutdown()
    }

    private func startStatusTimer() {
        if statusTimer != nil { return }
        statusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        RunLoop.main.add(statusTimer!, forMode: .common)
    }

    private func scheduleAutoRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        let newPosition = core.getDoubleProperty("time-pos") ?? 0
        let newDuration = core.getDoubleProperty("duration") ?? 0
        let paused = core.getFlagProperty("pause") ?? false
        let newRate = core.getDoubleProperty("speed") ?? rate

        position = newPosition
        duration = newDuration
        rate = newRate
        isPlaying = !paused
        if newDuration > 0 {
            isReady = true
        }
    }
}

struct MPVVideoView: View {
    @ObservedObject var player: MPVPlayerModel

    var body: some View {
        SampleBufferDisplayRepresentable { layer in
            player.attach(layer: layer)
        }
        .background(Color.black)
    }
}

private final class MPVCore {
    private let queue = DispatchQueue(label: "mpv.core.queue", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var renderCoordinator: MPVRenderCoordinator?

    init() {
        queue.sync {
            handle = mpv_create()
            guard let handle else { return }

            mpv_set_option_string(handle, "vo", "libmpv")
            mpv_set_option_string(handle, "hwdec", "auto")
            mpv_set_option_string(handle, "keep-open", "yes")
            mpv_set_option_string(handle, "osc", "no")
            mpv_set_option_string(handle, "input-default-bindings", "no")
            mpv_set_option_string(handle, "input-vo-keyboard", "no")
            mpv_set_option_string(handle, "save-position-on-quit", "no")
            mpv_set_option_string(handle, "cache", "yes")

            if mpv_initialize(handle) < 0 {
                mpv_destroy(handle)
                self.handle = nil
                return
            }

            var apiType = UnsafePointer<CChar>(strdup(MPV_RENDER_API_TYPE_SW))
            defer { free(UnsafeMutablePointer(mutating: apiType)) }
            var params = [
                mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
            ]
            var context: OpaquePointer?
            if mpv_render_context_create(&context, handle, &params) < 0 {
                mpv_terminate_destroy(handle)
                self.handle = nil
                return
            }
            guard let context else {
                mpv_terminate_destroy(handle)
                self.handle = nil
                return
            }
            renderContext = context

            let coordinator = MPVRenderCoordinator(handle: handle, renderContext: context)
            renderCoordinator = coordinator
            let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
                guard let ctx else { return }
                let coordinator = Unmanaged<MPVRenderCoordinator>.fromOpaque(ctx).takeUnretainedValue()
                coordinator.scheduleRender()
            }
            mpv_render_context_set_update_callback(context, callback, Unmanaged.passUnretained(coordinator).toOpaque())
        }
    }

    func attach(layer: AVSampleBufferDisplayLayer) {
        queue.async {
            self.renderCoordinator?.setDisplayLayer(layer)
        }
    }

    func load(url: URL, headers: [String: String], startTime: Double?) {
        queue.async {
            guard let handle = self.handle else { return }
            if headers.isEmpty {
                mpv_set_property_string(handle, "http-header-fields", "")
            } else {
                let headerLines = headers.map { "\($0): \($1)" }.joined(separator: "\r\n")
                mpv_set_property_string(handle, "http-header-fields", headerLines)
            }

            let target = url.isFileURL ? url.path : url.absoluteString
            self.command(["loadfile", target, "replace"])
            if let startTime, startTime > 0.5 {
                self.command(["seek", String(startTime), "absolute", "exact"])
            }
            self.setPaused(false)
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async {
            guard let handle = self.handle else { return }
            var flag = paused ? 1 : 0
            mpv_set_property(handle, "pause", MPV_FORMAT_FLAG, &flag)
        }
    }

    func seek(to seconds: Double) {
        queue.async {
            self.command(["seek", String(seconds), "absolute", "exact"])
        }
    }

    func seekBy(_ delta: Double) {
        queue.async {
            self.command(["seek", String(delta), "relative", "exact"])
        }
    }

    func setRate(_ value: Double) {
        queue.async {
            guard let handle = self.handle else { return }
            var rate = value
            mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &rate)
        }
    }

    func getDoubleProperty(_ name: String) -> Double? {
        queue.sync {
            guard let handle = handle else { return nil }
            var out: Double = 0
            let result = mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &out)
            return result >= 0 ? out : nil
        }
    }

    func getFlagProperty(_ name: String) -> Bool? {
        queue.sync {
            guard let handle = handle else { return nil }
            var out: Int32 = 0
            let result = mpv_get_property(handle, name, MPV_FORMAT_FLAG, &out)
            return result >= 0 ? (out != 0) : nil
        }
    }

    func shutdown() {
        queue.sync {
            if let context = renderContext {
                mpv_render_context_set_update_callback(context, nil, nil)
                mpv_render_context_free(context)
                renderContext = nil
            }
            if let handle = handle {
                mpv_terminate_destroy(handle)
                self.handle = nil
            }
        }
    }

    private func command(_ args: [String]) {
        guard let handle = handle else { return }
        var cStrings = args.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var cArgs = cStrings.map { UnsafePointer<CChar>($0) }
        cArgs.append(nil)
        cArgs.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
    }
}

private final class MPVRenderCoordinator {
    private let handle: OpaquePointer
    private let renderContext: OpaquePointer
    private let queue = DispatchQueue(label: "mpv.render.queue", qos: .userInitiated)
    private var displayLayer: AVSampleBufferDisplayLayer?
    private var formatDescription: CMVideoFormatDescription?
    private var lastSize: CGSize = .zero
    private var isRendering = false
    private var formatCString = Array("bgr0".utf8CString)

    init(handle: OpaquePointer, renderContext: OpaquePointer) {
        self.handle = handle
        self.renderContext = renderContext
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async {
            self.displayLayer = layer
            self.displayLayer?.videoGravity = .resizeAspect
            self.displayLayer?.backgroundColor = CGColor(gray: 0, alpha: 1)
        }
    }

    func scheduleRender() {
        queue.async {
            if self.isRendering { return }
            self.isRendering = true
            self.renderFrame()
            self.isRendering = false
        }
    }

    private func renderFrame() {
        guard let layer = displayLayer else { return }
        let updateRaw = mpv_render_context_update(renderContext)
        let updateBits = UInt32(truncatingIfNeeded: updateRaw)
        if (updateBits & MPV_RENDER_UPDATE_FRAME) == 0 {
            return
        }

        let size = resolveVideoSize(layer: layer)
        if size.width <= 1 || size.height <= 1 {
            return
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         Int(size.width),
                                         Int(size.height),
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pixelBuffer)
        guard status == kCVReturnSuccess, let pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }

        var swSize = [Int32(size.width), Int32(size.height)]
        var swStride = Int32(bytesPerRow)
        formatCString.withUnsafeMutableBufferPointer { formatPtr in
            swSize.withUnsafeMutableBufferPointer { sizePtr in
                guard let sizeBase = sizePtr.baseAddress,
                      let formatBase = formatPtr.baseAddress else { return }
                withUnsafeMutablePointer(to: &swStride) { stridePtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(sizeBase)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePtr)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(formatBase)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: baseAddress),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                    ]
                    mpv_render_context_render(renderContext, &params)
                }
            }
        }

        if formatDescription == nil || lastSize != size {
            var newDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &newDesc)
            formatDescription = newDesc
            lastSize = size
        }
        guard let formatDescription else { return }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: .invalid,
                                        decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let result = CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                        imageBuffer: pixelBuffer,
                                                        dataReady: true,
                                                        makeDataReadyCallback: nil,
                                                        refcon: nil,
                                                        formatDescription: formatDescription,
                                                        sampleTiming: &timing,
                                                        sampleBufferOut: &sampleBuffer)
        guard result == noErr, let sampleBuffer else { return }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0,
           let attachment = CFArrayGetValueAtIndex(attachments, 0) {
            let dict = unsafeBitCast(attachment, to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }

        layer.enqueue(sampleBuffer)
    }

    private func resolveVideoSize(layer: AVSampleBufferDisplayLayer) -> CGSize {
        var width: Int64 = 0
        var height: Int64 = 0
        mpv_get_property(handle, "width", MPV_FORMAT_INT64, &width)
        mpv_get_property(handle, "height", MPV_FORMAT_INT64, &height)

        if width <= 0 || height <= 0 {
            let fallback = layer.bounds.size
            return CGSize(width: max(fallback.width, 0), height: max(fallback.height, 0))
        }
        return CGSize(width: CGFloat(width), height: CGFloat(height))
    }
}

#else

@MainActor
final class MPVPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1
    @Published var errorMessage: String? = "mpv is not bundled with this build."

    func attach(layer: AVSampleBufferDisplayLayer) {}
    func load(url: URL, headers: [String: String], startTime: Double?) {
        errorMessage = "mpv is not bundled with this build."
    }
    func togglePlay() {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func seekBy(_ delta: Double) {}
    func setRate(_ value: Double) {}
    func shutdown() {}
}

struct MPVVideoView: View {
    @ObservedObject var player: MPVPlayerModel

    var body: some View {
        ZStack {
            Color.black
            Text(player.errorMessage ?? "mpv unavailable")
                .foregroundColor(.white)
                .font(.system(size: 14, weight: .semibold))
        }
    }
}

#endif
