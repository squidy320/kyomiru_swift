import AVFoundation
import Foundation
import SwiftUI
import QuartzCore
#if os(iOS)
import Metal
#endif

#if canImport(Libmpv)
import Libmpv

@MainActor
final class MPVPlayerModel: ObservableObject {
    enum RendererMode: Equatable {
        case metal
        case software
    }

    @Published var isPlaying = false
    @Published var isReady = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1
    @Published var errorMessage: String?
    @Published var debugStats: MPVDebugStats?
    @Published private(set) var rendererMode: RendererMode = .metal

    private var core: MPVCore?
    private var desiredMode: RendererMode = .metal
    private var metalLayer: CAMetalLayer?
    private var sampleLayer: AVSampleBufferDisplayLayer?
    private var lastLoad: (url: URL, headers: [String: String], startTime: Double?)?
    private var statusTimer: Timer?
    private var wantsDebugStats = false
#if os(iOS) && !targetEnvironment(macCatalyst)
    private var pipController: PiPController?
#endif

    var usesMetal: Bool { rendererMode == .metal }

    func attachMetal(layer: CAMetalLayer) {
        metalLayer = layer
        if desiredMode == .metal, rendererMode != .metal || core == nil {
            switchRenderer(to: .metal)
        }
    }

    func attachSample(layer: AVSampleBufferDisplayLayer) {
        sampleLayer = layer
        if rendererMode == .software {
            core?.attach(displayLayer: layer, hostLayer: nil)
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        if pipController == nil {
            pipController = PiPController(
                sampleBufferDisplayLayer: layer,
                isPlaying: { [weak self] in self?.isPlaying ?? false },
                play: { [weak self] in self?.play() },
                pause: { [weak self] in self?.pause() },
                currentTime: { [weak self] in self?.position ?? 0 },
                duration: { [weak self] in self?.duration ?? 0 },
                skipBy: { [weak self] delta in self?.seekBy(delta) },
                onStop: { [weak self] in self?.switchRenderer(to: .metal) }
            )
        }
#endif
    }

    func load(url: URL, headers: [String: String], startTime: Double?) {
        lastLoad = (url, headers, startTime)
        if core == nil {
            if desiredMode == .metal, metalLayer != nil {
                switchRenderer(to: .metal)
            } else if desiredMode == .software, sampleLayer != nil {
                switchRenderer(to: .software)
            }
        }
        core?.load(url: url, headers: headers, startTime: startTime)
        if core != nil {
            startStatusTimer()
        }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func setDebugOverlayEnabled(_ enabled: Bool) {
        wantsDebugStats = enabled
        if !enabled {
            debugStats = nil
        }
    }

    func play() {
        core?.setPaused(false)
        isPlaying = true
        scheduleAutoRefresh()
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
    }

    func pause() {
        core?.setPaused(true)
        isPlaying = false
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
    }

    func seek(to seconds: Double) {
        core?.seek(to: seconds)
        scheduleAutoRefresh()
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
    }

    func seekBy(_ delta: Double) {
        core?.seekBy(delta)
        scheduleAutoRefresh()
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
    }

    func setRate(_ value: Double) {
        rate = value
        core?.setRate(value)
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
    }

    func shutdown() {
        statusTimer?.invalidate()
        statusTimer = nil
        core?.shutdown()
        core = nil
        lastLoad = nil
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.stopPictureInPicture()
        pipController = nil
#endif
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    func startPictureInPictureIfPossible() -> Bool {
        if rendererMode != .software {
            switchRenderer(to: .software)
        }
        guard let pipController, pipController.isPictureInPicturePossible else { return false }
        pipController.startPictureInPicture()
        return true
    }

    func stopPictureInPicture() {
        pipController?.stopPictureInPicture()
        if rendererMode == .software {
            switchRenderer(to: .metal)
        }
    }
#endif

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
        guard let core else { return }
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
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
        if wantsDebugStats {
            debugStats = core.renderStats()
        }
    }

    private func switchRenderer(to mode: RendererMode) {
        desiredMode = mode
        if mode == .metal, metalLayer == nil {
            AppLog.error(.player, "mpv switch: missing metal layer")
            return
        }
        if mode == .software, sampleLayer == nil {
            AppLog.error(.player, "mpv switch: missing sample layer")
            return
        }

        let resumeTime = core?.getDoubleProperty("time-pos")
        let wasPaused = core?.getFlagProperty("pause") ?? false
        let resumeRate = core?.getDoubleProperty("speed") ?? rate
        core?.shutdown()
        core = nil

        rendererMode = mode
        let hostLayer: CALayer? = (mode == .metal) ? metalLayer : nil
        core = MPVCore(renderer: mode, hostLayer: hostLayer)
        if mode == .software, let sampleLayer {
            core?.attach(displayLayer: sampleLayer, hostLayer: nil)
        }

        if let lastLoad {
            let start = resumeTime ?? lastLoad.startTime
            core?.load(url: lastLoad.url, headers: lastLoad.headers, startTime: start)
            core?.setRate(resumeRate)
            core?.setPaused(wasPaused)
            startStatusTimer()
        }
    }
}

struct MPVVideoView: View {
    @ObservedObject var player: MPVPlayerModel

    var body: some View {
        ZStack(alignment: .topLeading) {
#if os(iOS)
            MetalLayerRepresentable { layer in
                player.attachMetal(layer: layer)
            }
            .background(Color.black)
            .opacity(player.usesMetal ? 1 : 0)
            .allowsHitTesting(false)
#endif

            SampleBufferDisplayRepresentable { view in
                player.attachSample(layer: view.displayLayer)
            }
            .background(Color.black)
            .opacity(player.usesMetal ? 0 : 1)
            .allowsHitTesting(false)
            if let stats = player.debugStats {
                VStack(alignment: .leading, spacing: 6) {
                    Text("MPV Debug")
                        .font(.system(size: 12, weight: .semibold))
                    Text("frames: \(stats.framesRendered)")
                    Text("lastUpdate: \(String(format: "%.2f", stats.secondsSinceUpdate))s")
                    Text("enqueued: \(stats.framesEnqueued)")
                    Text("lastEnqueue: \(String(format: "%.2f", stats.secondsSinceEnqueue))s")
                    Text("updateMask: \(stats.lastUpdateMask)")
                    Text("fps: \(String(format: "%.1f", stats.fps))")
                    Text("size: \(stats.videoSize)")
                    Text("layer: \(stats.layerStatus)")
                    if let error = stats.layerError {
                        Text("error: \(error)")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.black.opacity(0.65))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .padding(8)
            }
        }
    }
}

private final class MPVCore {
    private let queue = DispatchQueue(label: "mpv.core.queue", qos: .userInitiated)
    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    private var renderCoordinator: MPVRenderCoordinator?
    private var eventTimer: DispatchSourceTimer?
    private let renderer: MPVPlayerModel.RendererMode

    init(renderer: MPVPlayerModel.RendererMode, hostLayer: CALayer?) {
        self.renderer = renderer
        queue.sync {
            handle = mpv_create()
            guard let handle else {
                AppLog.error(.player, "mpv_create failed")
                return
            }

            if let hostLayer {
                let pointer = Unmanaged.passUnretained(hostLayer).toOpaque()
                var wid = Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))
                mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)
                AppLog.debug(.player, "mpv init: set wid=\(wid)")
            }

            switch renderer {
            case .metal:
                mpv_set_option_string(handle, "vo", "gpu")
                mpv_set_option_string(handle, "gpu-context", "moltenvk")
                mpv_set_option_string(handle, "hwdec", "videotoolbox")
            case .software:
                mpv_set_option_string(handle, "vo", "libmpv")
                mpv_set_option_string(handle, "hwdec", "no")
            }
            mpv_set_option_string(handle, "keep-open", "yes")
            mpv_set_option_string(handle, "osc", "no")
            mpv_set_option_string(handle, "input-default-bindings", "no")
            mpv_set_option_string(handle, "input-vo-keyboard", "no")
            mpv_set_option_string(handle, "save-position-on-quit", "no")
            mpv_set_option_string(handle, "cache", "yes")

            if mpv_initialize(handle) < 0 {
                AppLog.error(.player, "mpv_initialize failed")
                mpv_destroy(handle)
                self.handle = nil
                return
            }
            AppLog.debug(.player, "mpv init: initialized")

#if DEBUG
            mpv_request_log_messages(handle, "info")
#else
            mpv_request_log_messages(handle, "warn")
#endif

            if renderer == .software {
                var apiType = UnsafePointer<CChar>(strdup(MPV_RENDER_API_TYPE_SW))
                defer { free(UnsafeMutablePointer(mutating: apiType)) }
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                var context: OpaquePointer?
                if mpv_render_context_create(&context, handle, &params) < 0 {
                    AppLog.error(.player, "mpv_render_context_create failed")
                    mpv_terminate_destroy(handle)
                    self.handle = nil
                    return
                }
                guard let context else {
                    AppLog.error(.player, "mpv_render_context_create returned nil context")
                    mpv_terminate_destroy(handle)
                    self.handle = nil
                    return
                }
                renderContext = context
                AppLog.debug(.player, "mpv render context created")

                let coordinator = MPVRenderCoordinator(handle: handle, renderContext: context)
                renderCoordinator = coordinator
                let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
                    guard let ctx else { return }
                    let coordinator = Unmanaged<MPVRenderCoordinator>.fromOpaque(ctx).takeUnretainedValue()
                    coordinator.scheduleRender()
                }
                mpv_render_context_set_update_callback(context, callback, Unmanaged.passUnretained(coordinator).toOpaque())
                AppLog.debug(.player, "mpv update callback set")
            }

            startEventLoop()
        }
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer, hostLayer: CALayer?) {
        queue.async {
            self.renderCoordinator?.setDisplayLayer(displayLayer)
            if let hostLayer {
                self.setWindowIDIfNeeded(hostLayer: hostLayer)
            }
            AppLog.debug(.player, "mpv attach: set displayLayer")
        }
    }

    func load(url: URL, headers: [String: String], startTime: Double?) {
        queue.async {
            guard let handle = self.handle else { return }
            if url.isFileURL {
                let path = url.path
                let exists = FileManager.default.fileExists(atPath: path)
                let ext = url.pathExtension.lowercased()
                AppLog.debug(.player, "mpv loadfile local exists=\(exists) path=\(path)")
                if !exists {
                    AppLog.error(.player, "mpv loadfile missing local file path=\(path)")
                }
                if ext == "ts" {
                    mpv_set_property_string(handle, "demuxer", "lavf")
                    mpv_set_property_string(handle, "demuxer-lavf-format", "mpegts")
                    mpv_set_property_string(handle, "demuxer-lavf-o", "fflags=+genpts")
                } else {
                    mpv_set_property_string(handle, "demuxer", "")
                    mpv_set_property_string(handle, "demuxer-lavf-format", "")
                    mpv_set_property_string(handle, "demuxer-lavf-o", "")
                }
            } else {
                AppLog.debug(.player, "mpv loadfile remote url=\(url.absoluteString)")
            }
            if headers.isEmpty {
                mpv_set_property_string(handle, "http-header-fields", "")
            } else {
                let headerLines = headers.map { "\($0): \($1)" }.joined(separator: "\r\n")
                mpv_set_property_string(handle, "http-header-fields", headerLines)
            }

            let target = url.isFileURL ? url.path : url.absoluteString
            AppLog.debug(.player, "mpv loadfile target=\(target)")
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
            stopEventLoop()
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

    func renderStats() -> MPVDebugStats? {
        guard let coordinator = renderCoordinator else { return nil }
        return coordinator.snapshot()
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

    private func setWindowIDIfNeeded(hostLayer: CALayer) {
        guard let handle else { return }
        let pointer = Unmanaged.passUnretained(hostLayer).toOpaque()
        var wid = Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))
        mpv_set_property(handle, "wid", MPV_FORMAT_INT64, &wid)
    }

    private func startEventLoop() {
        if eventTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, let handle = self.handle else { return }
            // Pump the mpv event queue so render callbacks fire reliably.
            _ = mpv_wait_event(handle, 0)
        }
        eventTimer = timer
        timer.resume()
    }

    private func stopEventLoop() {
        eventTimer?.cancel()
        eventTimer = nil
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
    private var minRenderInterval: CFTimeInterval = 1.0 / 30.0
    private var lastRenderTime: CFTimeInterval = 0
    private var isRenderScheduled = false
    private var lastEnqueueTime: CFTimeInterval = 0
    private var framesEnqueued: Int = 0
    private var framesRendered: Int = 0
    private var lastUpdateTime: CFTimeInterval = 0
    private var lastLogTime: CFTimeInterval = 0
    private var lastUpdateMask: UInt64 = 0
    private var timebase: CMTimebase?
    private var firstFrameHostTime: CFTimeInterval?
    private var lastFrameHostTime: CFTimeInterval?
    private var fpsEstimate: Double = 0
    private var configuredLayer: AVSampleBufferDisplayLayer?

    init(handle: OpaquePointer, renderContext: OpaquePointer) {
        self.handle = handle
        self.renderContext = renderContext
#if os(iOS)
        let maxFPS = UIScreen.main.maximumFramesPerSecond
        let cappedFPS = min(maxFPS, 60)
        minRenderInterval = 1.0 / CFTimeInterval(cappedFPS)
#endif
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async {
            let isNewLayer = self.configuredLayer !== layer
            self.displayLayer = layer
            if isNewLayer {
                self.configuredLayer = layer
                DispatchQueue.main.async {
                    self.displayLayer?.videoGravity = .resizeAspect
                    self.displayLayer?.backgroundColor = CGColor(gray: 0, alpha: 1)
                    self.displayLayer?.flushAndRemoveImage()
                    self.configureTimebaseIfNeeded()
                }
            }
            self.scheduleRender()
        }
    }

    func scheduleRender() {
        queue.async {
            if self.isRenderScheduled { return }
            self.isRenderScheduled = true

            let now = CACurrentMediaTime()
            let elapsed = now - self.lastRenderTime
            let remaining = max(self.minRenderInterval - elapsed, 0)

            self.queue.asyncAfter(deadline: .now() + remaining) { [weak self] in
                guard let self else { return }
                self.isRenderScheduled = false
                self.lastRenderTime = CACurrentMediaTime()
                self.performRenderUpdate()
            }
        }
    }

    private func performRenderUpdate() {
        guard let layer = displayLayer else { return }
        if layer.status == .failed {
            layer.flushAndRemoveImage()
#if DEBUG
            AppLog.error(.player, "display layer failed: \(layer.error?.localizedDescription ?? "unknown")")
#endif
        }
        let updateRaw = mpv_render_context_update(renderContext)
        lastUpdateMask = updateRaw
        lastUpdateTime = CACurrentMediaTime()
#if DEBUG
        let now = lastUpdateTime
        if now - lastLogTime > 2.0 {
            lastLogTime = now
            AppLog.debug(.player, "mpv update=\(updateRaw) size=\(Int(lastSize.width))x\(Int(lastSize.height)) layer=\(layer.status.rawValue)")
        }
#endif
        let frameMask = UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)
        if (updateRaw & frameMask) != 0 {
            renderFrame()
        }
        if updateRaw > 0 {
            scheduleRender()
        }
    }

    private func renderFrame() {
        guard let layer = displayLayer else { return }

        let size = resolveVideoSize(layer: layer)
        if size.width <= 1 || size.height <= 1 {
            // Try again shortly once mpv has a valid size.
#if DEBUG
            let now = CACurrentMediaTime()
            if now - lastLogTime > 2.0 {
                lastLogTime = now
                AppLog.debug(.player, "mpv video size not ready (width=\(size.width) height=\(size.height))")
            }
#endif
            queue.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.scheduleRender()
            }
            return
        }

        var pixelBuffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
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

        var timing = makeTimingInfo()
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

        if layer.requiresFlushToResumeDecoding {
            layer.flush()
        }
        if !layer.isReadyForMoreMediaData {
            scheduleRender()
            return
        }
        layer.enqueue(sampleBuffer)
        framesEnqueued += 1
        lastEnqueueTime = CACurrentMediaTime()
        framesRendered += 1
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

    func snapshot() -> MPVDebugStats {
        let sizeText: String
        if lastSize.width > 0 && lastSize.height > 0 {
            sizeText = "\(Int(lastSize.width))x\(Int(lastSize.height))"
        } else {
            sizeText = "0x0"
        }

        let layerStatusText: String
        let layerErrorText: String?
        if let layer = displayLayer {
            switch layer.status {
            case .unknown: layerStatusText = "unknown"
            case .failed: layerStatusText = "failed"
            case .rendering: layerStatusText = "rendering"
            @unknown default: layerStatusText = "unknown"
            }
            layerErrorText = layer.error?.localizedDescription
        } else {
            layerStatusText = "nil"
            layerErrorText = nil
        }

        let since = max(CACurrentMediaTime() - lastUpdateTime, 0)
        return MPVDebugStats(
            framesRendered: framesRendered,
            secondsSinceUpdate: since,
            videoSize: sizeText,
            layerStatus: layerStatusText,
            layerError: layerErrorText,
            framesEnqueued: framesEnqueued,
            secondsSinceEnqueue: max(CACurrentMediaTime() - lastEnqueueTime, 0),
            lastUpdateMask: lastUpdateMask,
            fps: fpsEstimate
        )
    }

    private func configureTimebaseIfNeeded() {
        guard let layer = displayLayer, layer.controlTimebase == nil else { return }
        var newTimebase: CMTimebase?
        let clock = CMClockGetHostTimeClock()
        let status = CMTimebaseCreateWithMasterClock(allocator: kCFAllocatorDefault,
                                                     masterClock: clock,
                                                     timebaseOut: &newTimebase)
        guard status == noErr, let timebase = newTimebase else {
            AppLog.error(.player, "mpv timebase create failed status=\(status)")
            return
        }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1.0)
        layer.controlTimebase = timebase
        self.timebase = timebase
    }

    private func makeTimingInfo() -> CMSampleTimingInfo {
        let hostTime = CACurrentMediaTime()
        if firstFrameHostTime == nil {
            firstFrameHostTime = hostTime
            if let timebase {
                CMTimebaseSetTime(timebase, time: .zero)
                CMTimebaseSetRate(timebase, rate: 1.0)
            }
        }

        let frameRate = resolveFrameRate() ?? 30.0
        let frameDuration = CMTimeMakeWithSeconds(1.0 / frameRate, preferredTimescale: 600)
        let ptsSeconds = max(hostTime - (firstFrameHostTime ?? hostTime), 0)
        let pts = CMTimeMakeWithSeconds(ptsSeconds, preferredTimescale: 600)

        if let lastHost = lastFrameHostTime {
            let delta = max(hostTime - lastHost, 0.001)
            fpsEstimate = 1.0 / delta
        }
        lastFrameHostTime = hostTime

        return CMSampleTimingInfo(duration: frameDuration,
                                  presentationTimeStamp: pts,
                                  decodeTimeStamp: .invalid)
    }

    private func resolveFrameRate() -> Double? {
        var fps: Double = 0
        if mpv_get_property(handle, "container-fps", MPV_FORMAT_DOUBLE, &fps) >= 0, fps > 1 {
            return fps
        }
        fps = 0
        if mpv_get_property(handle, "fps", MPV_FORMAT_DOUBLE, &fps) >= 0, fps > 1 {
            return fps
        }
        return nil
    }
}

struct MPVDebugStats: Equatable {
    let framesRendered: Int
    let secondsSinceUpdate: Double
    let videoSize: String
    let layerStatus: String
    let layerError: String?
    let framesEnqueued: Int
    let secondsSinceEnqueue: Double
    let lastUpdateMask: UInt64
    let fps: Double
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

    func attach(layer: AVSampleBufferDisplayLayer, hostLayer: CALayer) {}
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
