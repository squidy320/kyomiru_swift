import AVFoundation
import Foundation
import SwiftUI
import QuartzCore
#if os(iOS)
import Metal
import UIKit
#endif

#if os(iOS) || targetEnvironment(macCatalyst)
struct SubtitleStyle {
    let foregroundColor: UIColor
    let strokeColor: UIColor
    let strokeWidth: CGFloat
    let fontSize: CGFloat
    let isVisible: Bool

    static let `default` = SubtitleStyle(
        foregroundColor: .white,
        strokeColor: .black,
        strokeWidth: 1.0,
        fontSize: 18.0,
        isVisible: false
    )
}
#endif

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
    @Published var debugStats: MPVDebugStats?

    private var core: MPVCore?
    private var statusTimer: Timer?
    private var wantsDebugStats = false
    private var pendingLoad: (url: URL, headers: [String: String], startTime: Double?)?
    private var sampleLayer: AVSampleBufferDisplayLayer?
    private var pipStartTask: Task<Void, Never>?
#if os(iOS) && !targetEnvironment(macCatalyst)
    private var pipController: PiPController?
#endif

    func attachMetal(layer: CALayer) {
        if core == nil {
            core = MPVCore(hostLayer: layer)
        }
        if let pending = pendingLoad {
            core?.load(url: pending.url, headers: pending.headers, startTime: pending.startTime)
            pendingLoad = nil
            startStatusTimer()
        }
    }

    func attachSample(layer: AVSampleBufferDisplayLayer) {
        sampleLayer = layer
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
                onStop: { [weak self] in self?.core?.stopPiPRendering() }
            )
        }
#endif
    }

    func load(url: URL, headers: [String: String], startTime: Double?) {
        guard let core else {
            pendingLoad = (url, headers, startTime)
            return
        }
        core.load(url: url, headers: headers, startTime: startTime)
        startStatusTimer()
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func setDebugOverlayEnabled(_ enabled: Bool) {
        wantsDebugStats = enabled
        if !enabled { debugStats = nil }
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
        pendingLoad = nil
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipStartTask?.cancel()
        pipStartTask = nil
#endif
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.stopPictureInPicture()
        pipController = nil
#endif
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        core?.applySubtitleStyle(style)
    }

    func setSubtitleVisible(_ visible: Bool) {
        core?.setSubtitleVisible(visible)
    }

    func addSubtitleTrack(urlString: String) {
        core?.addSubtitleTrack(urlString: urlString)
    }

    func clearCurrentSubtitleTrack() {
        core?.clearCurrentSubtitleTrack()
    }

#if os(iOS) && !targetEnvironment(macCatalyst)
    func startPictureInPictureIfPossible() -> Bool {
        guard let sampleLayer else { return false }
        core?.startPiPRendering(displayLayer: sampleLayer)
        guard let pipController else { return false }
        pipStartTask?.cancel()
        let canStart = pipController.isPictureInPicturePossible
        if canStart {
            pipController.startPictureInPicture()
        }
        // Retry briefly and pause if PiP never activates.
        pipStartTask = Task { [weak self] in
            guard let self, let pipController = self.pipController else { return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            if pipController.isPictureInPictureActive { return }
            if pipController.isPictureInPicturePossible {
                pipController.startPictureInPicture()
                try? await Task.sleep(nanoseconds: 350_000_000)
                if pipController.isPictureInPictureActive { return }
            }
            self.core?.stopPiPRendering()
            self.pause()
        }
        return canStart
    }

    func stopPictureInPicture() {
        pipController?.stopPictureInPicture()
        core?.stopPiPRendering()
    }

    var isPictureInPictureActive: Bool {
        pipController?.isPictureInPictureActive ?? false
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
        if newDuration > 0 { isReady = true }
#if os(iOS) && !targetEnvironment(macCatalyst)
        pipController?.invalidatePlaybackState()
#endif
        if wantsDebugStats {
            debugStats = core.renderStats()
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
            .allowsHitTesting(false)
#endif
            SampleBufferDisplayRepresentable { view in
                player.attachSample(layer: view.displayLayer)
            }
            .background(Color.black)
            .opacity(0) // Hidden; used for PiP rendering.
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
    private var pipRenderContext: OpaquePointer?
    private var pipCoordinator: MPVRenderCoordinator?
    private var eventTimer: DispatchSourceTimer?

    init(hostLayer: CALayer) {
        queue.sync {
            handle = mpv_create()
            guard let handle else {
                AppLog.error(.player, "mpv_create failed")
                return
            }

            let pointer = Unmanaged.passUnretained(hostLayer).toOpaque()
            var wid = Int64(bitPattern: UInt64(UInt(bitPattern: pointer)))
            mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &wid)

            // Luna-style options: GPU output with MoltenVK for Metal.
            mpv_set_option_string(handle, "vo", "gpu-next")
            mpv_set_option_string(handle, "gpu-api", "vulkan")
            mpv_set_option_string(handle, "gpu-context", "moltenvk")
            mpv_set_option_string(handle, "hwdec", "videotoolbox")
            mpv_set_option_string(handle, "idle", "yes")
            mpv_set_option_string(handle, "ytdl", "yes")
            mpv_set_option_string(handle, "sub-ass", "yes")
            mpv_set_option_string(handle, "hr-seek", "yes")
            mpv_set_option_string(handle, "terminal", "yes")
            mpv_set_option_string(handle, "keep-open", "yes")
            mpv_set_option_string(handle, "interpolation", "no")
            mpv_set_option_string(handle, "subs-fallback", "yes")
            mpv_set_option_string(handle, "msg-level", "all=warn")
            mpv_set_option_string(handle, "demuxer-thread", "yes")
            mpv_set_option_string(handle, "sub-ass-override", "yes")
            mpv_set_option_string(handle, "video-sync", "display-resample")
            mpv_set_option_string(handle, "audio-normalize-downmix", "yes")

            let initStatus = mpv_initialize(handle)
            guard initStatus >= 0 else {
                AppLog.error(.player, "mpv_initialize failed")
                mpv_destroy(handle)
                self.handle = nil
                return
            }

#if DEBUG
            mpv_request_log_messages(handle, "info")
#else
            mpv_request_log_messages(handle, "warn")
#endif
            startEventLoop()
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
                if ext == "ts" {
                    mpv_set_property_string(handle, "demuxer", "lavf")
                    mpv_set_property_string(handle, "demuxer-lavf-format", "mpegts")
                    mpv_set_property_string(handle, "demuxer-lavf-o", "fflags=+genpts")
                } else {
                    mpv_set_property_string(handle, "demuxer", "")
                    mpv_set_property_string(handle, "demuxer-lavf-format", "")
                    mpv_set_property_string(handle, "demuxer-lavf-o", "")
                }
            }

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
        queue.async { self.command(["seek", String(seconds), "absolute", "exact"]) }
    }

    func seekBy(_ delta: Double) {
        queue.async { self.command(["seek", String(delta), "relative", "exact"]) }
    }

    func setRate(_ value: Double) {
        queue.async {
            guard let handle = self.handle else { return }
            var rate = value
            mpv_set_property(handle, "speed", MPV_FORMAT_DOUBLE, &rate)
        }
    }

    func setSubtitleVisible(_ visible: Bool) {
        setProperty(name: "sub-visibility", value: visible ? "yes" : "no")
    }

    func addSubtitleTrack(urlString: String) {
        guard !urlString.isEmpty else { return }
        queue.async {
            guard let handle = self.handle else { return }
            self.command(["sub-add", urlString, "select"])
        }
    }

    func clearCurrentSubtitleTrack() {
        queue.async {
            guard let handle = self.handle else { return }
            self.command(["sub-remove"])
        }
    }

    func applySubtitleStyle(_ style: SubtitleStyle) {
        setProperty(name: "sub-font-size", value: String(format: "%.2f", style.fontSize))
        setProperty(name: "sub-color", value: style.foregroundColor.mpvColorString)
        setProperty(name: "sub-border-color", value: style.strokeColor.mpvColorString)
        setProperty(name: "sub-border-size", value: String(format: "%.2f", max(style.strokeWidth, 0)))
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

    func startPiPRendering(displayLayer: AVSampleBufferDisplayLayer) {
        queue.async {
            guard let handle = self.handle else { return }
            if self.pipRenderContext != nil { return }

            var context: OpaquePointer?
            var apiTypeCString = MPV_RENDER_API_TYPE_SW.utf8CString
            apiTypeCString.withUnsafeMutableBufferPointer { buffer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                     data: UnsafeMutableRawPointer(buffer.baseAddress)),
                    mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)
                ]
                if mpv_render_context_create(&context, handle, &params) < 0 {
                    AppLog.error(.player, "mpv_render_context_create (PiP) failed")
                    return
                }
            }
            guard let context else {
                AppLog.error(.player, "mpv_render_context_create (PiP) returned nil")
                return
            }
            self.pipRenderContext = context
            let coordinator = MPVRenderCoordinator(handle: handle, renderContext: context)
            self.pipCoordinator = coordinator
            coordinator.setDisplayLayer(displayLayer)

            let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
                guard let ctx else { return }
                let coordinator = Unmanaged<MPVRenderCoordinator>.fromOpaque(ctx).takeUnretainedValue()
                coordinator.requestDisplayLink()
            }
            mpv_render_context_set_update_callback(context, callback, Unmanaged.passUnretained(coordinator).toOpaque())
            coordinator.requestDisplayLink()
        }
    }

    func stopPiPRendering() {
        queue.async {
            self.stopPiPRenderingLocked()
        }
    }

    func shutdown() {
        queue.sync {
            stopEventLoop()
            stopPiPRenderingLocked()
            if let handle = handle {
                mpv_terminate_destroy(handle)
                self.handle = nil
            }
        }
    }

    private func stopPiPRenderingLocked() {
        if let coordinator = self.pipCoordinator {
            coordinator.deactivate()
            coordinator.stopDisplayLink()
        }
        if let context = self.pipRenderContext {
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
        }
        self.pipRenderContext = nil
        self.pipCoordinator = nil
    }

    func renderStats() -> MPVDebugStats? {
        pipCoordinator?.snapshot()
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

    private func setProperty(name: String, value: String) {
        queue.async {
            guard let handle = self.handle else { return }
            let status = value.withCString { valuePointer in
                name.withCString { namePointer in
                    mpv_set_property_string(handle, namePointer, valuePointer)
                }
            }
            if status < 0 {
                AppLog.debug(.player, "mpv setProperty failed name=\(name) status=\(status)")
            }
        }
    }

    private func startEventLoop() {
        if eventTimer != nil { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 0.1, leeway: .milliseconds(20))
        timer.setEventHandler { [weak self] in
            guard let self, let handle = self.handle else { return }
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
    private var pipDisplayLink: CADisplayLink?
    private var pipDisplayLinkProxy: PiPDisplayLinkProxy?
    private var pipDisplayLinkRequested = false
    private var pipFramePumpScheduled = false
    private var isActive = true
    private var framesEnqueued: Int = 0
    private var framesRendered: Int = 0
    private var lastUpdateTime: CFTimeInterval = 0
    private var lastEnqueueTime: CFTimeInterval = 0
    private var lastUpdateMask: UInt64 = 0
    private var timebase: CMTimebase?
    private var firstFrameHostTime: CFTimeInterval?
    private var lastFrameHostTime: CFTimeInterval?
    private var fpsEstimate: Double = 0
    private var formatCString = Array("bgra".utf8CString)
    private var didFlushForFormatChange = false

    init(handle: OpaquePointer, renderContext: OpaquePointer) {
        self.handle = handle
        self.renderContext = renderContext
    }

    func setDisplayLayer(_ layer: AVSampleBufferDisplayLayer) {
        queue.async {
            self.displayLayer = layer
            DispatchQueue.main.async {
                layer.videoGravity = .resizeAspect
                layer.backgroundColor = CGColor(gray: 0, alpha: 1)
                self.configureTimebaseIfNeeded()
            }
            self.requestDisplayLink()
        }
    }

    func requestDisplayLink() {
        queue.async {
            guard self.displayLayer != nil else { return }
            guard self.isActive else { return }
            self.pipDisplayLinkRequested = true
            self.startDisplayLinkLocked()
        }
    }

    func stopDisplayLink() {
        queue.async {
            self.pipDisplayLinkRequested = false
            self.pipFramePumpScheduled = false
            self.stopDisplayLinkLocked()
        }
    }

    func deactivate() {
        queue.async {
            self.isActive = false
            self.pipDisplayLinkRequested = false
            self.pipFramePumpScheduled = false
        }
    }

    private func startDisplayLinkLocked() {
        guard pipDisplayLink == nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pipDisplayLink == nil else { return }
            let proxy = PiPDisplayLinkProxy(owner: self)
            let displayLink = CADisplayLink(target: proxy, selector: #selector(PiPDisplayLinkProxy.onDisplayLinkTick))
            displayLink.preferredFramesPerSecond = 30
            displayLink.add(to: .main, forMode: .common)
            self.pipDisplayLinkProxy = proxy
            self.pipDisplayLink = displayLink
        }
    }

    private func stopDisplayLinkLocked() {
        DispatchQueue.main.async { [weak self] in
            self?.pipDisplayLink?.invalidate()
            self?.pipDisplayLink = nil
            self?.pipDisplayLinkProxy = nil
        }
    }

    func onDisplayLinkTick() {
        pumpPiPFrame()
    }

    private func pumpPiPFrame() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.isActive else { return }
            guard self.pipDisplayLinkRequested || self.pipFramePumpScheduled else { return }
            self.pipFramePumpScheduled = true
            self.performRenderUpdate()
            self.pipFramePumpScheduled = false
        }
    }

    private func performRenderUpdate() {
        guard isActive else { return }
        let updateRaw = mpv_render_context_update(renderContext)
        lastUpdateMask = updateRaw
        lastUpdateTime = CACurrentMediaTime()
        let frameMask = UInt64(MPV_RENDER_UPDATE_FRAME.rawValue)
        if (updateRaw & frameMask) != 0 {
            pipDisplayLinkRequested = false
            renderFrame()
        }
    }

    private func renderFrame() {
        guard let layer = displayLayer else { return }
        let size = resolveVideoSize(layer: layer)
        if size.width <= 1 || size.height <= 1 { return }

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

        var needsFlush = false
        if formatDescription == nil || lastSize != size {
            var newDesc: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                         imageBuffer: pixelBuffer,
                                                         formatDescriptionOut: &newDesc)
            formatDescription = newDesc
            lastSize = size
            needsFlush = true
        }
        guard let formatDescription else { return }

        let presentationTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: presentationTime,
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

        DispatchQueue.main.async { [weak self] in
            guard let self, let layer = self.displayLayer else { return }
            let status: AVQueuedSampleBufferRenderingStatus
            let error: Error?
            if #available(iOS 18.0, *) {
                status = layer.sampleBufferRenderer.status
                error = layer.sampleBufferRenderer.error
            } else {
                status = layer.status
                error = layer.error
            }
            if status == .failed {
                if let error {
                    AppLog.error(.player, "mpv PiP layer failed: \(error.localizedDescription)")
                }
                if #available(iOS 18.0, *) {
                    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
                } else {
                    layer.flushAndRemoveImage()
                }
            }

            if needsFlush {
                if #available(iOS 18.0, *) {
                    layer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
                } else {
                    layer.flushAndRemoveImage()
                }
                self.didFlushForFormatChange = true
            } else if self.didFlushForFormatChange {
                if #available(iOS 18.0, *) {
                    layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
                } else {
                    layer.flush()
                }
                self.didFlushForFormatChange = false
            }

            if layer.controlTimebase == nil {
                var newTimebase: CMTimebase?
                if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
                                                   sourceClock: CMClockGetHostTimeClock(),
                                                   timebaseOut: &newTimebase) == noErr,
                   let newTimebase {
                    CMTimebaseSetRate(newTimebase, rate: 1.0)
                    CMTimebaseSetTime(newTimebase, time: presentationTime)
                    layer.controlTimebase = newTimebase
                    self.timebase = newTimebase
                }
            }

            if #available(iOS 18.0, *) {
                layer.sampleBufferRenderer.enqueue(sampleBuffer)
            } else {
                layer.enqueue(sampleBuffer)
            }
            self.framesEnqueued += 1
            self.lastEnqueueTime = CACurrentMediaTime()
            self.framesRendered += 1
        }
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

private final class PiPDisplayLinkProxy: NSObject {
    private weak var owner: MPVRenderCoordinator?

    init(owner: MPVRenderCoordinator) {
        self.owner = owner
    }

    @objc func onDisplayLinkTick() {
        owner?.onDisplayLinkTick()
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

#if os(iOS) || targetEnvironment(macCatalyst)
private extension UIColor {
    var mpvColorString: String {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%.3f/%.3f/%.3f/%.3f", r, g, b, a)
    }
}
#endif

#else

@MainActor
final class MPVPlayerModel: ObservableObject {
    @Published var isPlaying = false
    @Published var isReady = false
    @Published var position: Double = 0
    @Published var duration: Double = 0
    @Published var rate: Double = 1
    @Published var errorMessage: String? = "mpv is not bundled with this build."

    func attachMetal(layer: CALayer) {}
    func attachSample(layer: AVSampleBufferDisplayLayer) {}
    func load(url: URL, headers: [String: String], startTime: Double?) {
        errorMessage = "mpv is not bundled with this build."
    }
    func togglePlay() {}
    func play() {}
    func pause() {}
    func seek(to seconds: Double) {}
    func seekBy(_ delta: Double) {}
    func setRate(_ value: Double) {}
    func applySubtitleStyle(_ style: SubtitleStyle) {}
    func setSubtitleVisible(_ visible: Bool) {}
    func addSubtitleTrack(urlString: String) {}
    func clearCurrentSubtitleTrack() {}
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
