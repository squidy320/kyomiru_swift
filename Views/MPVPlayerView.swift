import SwiftUI
import GLKit
import OpenGLES
import Libmpv
import Observation

@Observable
@MainActor
final class MPVPlayerViewModel {
    private var handle: OpaquePointer?
    private var renderContext: OpaquePointer?

    var isReady = false

    func initializeIfNeeded() {
        guard handle == nil else { return }

        guard let mpv = mpv_create() else { return }
        handle = mpv

        _ = mpv_set_option_string(mpv, "vo", "libmpv")
        _ = mpv_initialize(mpv)
        isReady = true
    }

    func load(url: URL) {
        runCommand(["loadfile", url.absoluteString])
    }

    func seek(to seconds: Double) {
        runCommand(["seek", String(format: "%.3f", seconds), "absolute+exact"])
    }

    func setSpeed(_ speed: Double) {
        guard let mpv = handle else { return }
        var value = speed
        _ = mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    func setPaused(_ paused: Bool) {
        guard let mpv = handle else { return }
        var value: Int32 = paused ? 1 : 0
        _ = mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &value)
    }

    func currentTime() -> Double? {
        guard let mpv = handle else { return nil }
        var value = 0.0
        let result = mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &value)
        return result >= 0 ? value : nil
    }

    func createRenderContext(getProcAddress: @escaping @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?) {
        guard let mpv = handle, renderContext == nil else { return }

        var glInitParams = mpv_opengl_init_params(
            get_proc_address: getProcAddress,
            get_proc_address_ctx: nil
        )

        var apiType = MPV_RENDER_API_TYPE_OPENGL
        var advanced: Int32 = 1

        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: &apiType),
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: &glInitParams),
            mpv_render_param(type: MPV_RENDER_PARAM_ADVANCED_CONTROL, data: &advanced),
            mpv_render_param()
        ]

        mpv_render_context_create(&renderContext, mpv, &params)
    }

    func setRenderUpdateCallback(_ callback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
                                 ctx: UnsafeMutableRawPointer?) {
        guard let rc = renderContext else { return }
        mpv_render_context_set_update_callback(rc, callback, ctx)
    }

    func render(fbo: UInt32, width: Int32, height: Int32, flipY: Int32 = 1) {
        guard let rc = renderContext else { return }
        _ = mpv_render_context_update(rc)

        var fboStruct = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var params: [mpv_render_param] = [
            mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: &fboStruct),
            mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: &flipY),
            mpv_render_param()
        ]

        mpv_render_context_render(rc, &params)
    }

    func destroy() {
        if let rc = renderContext {
            mpv_render_context_free(rc)
            renderContext = nil
        }
        if let mpv = handle {
            mpv_terminate_destroy(mpv)
            handle = nil
        }
        isReady = false
    }

    deinit {
        destroy()
    }

    private func runCommand(_ args: [String]) {
        guard let mpv = handle else { return }
        var cArgs = args.map { ($0 as NSString).utf8String }
        cArgs.append(nil)
        cArgs.withUnsafeBufferPointer { buffer in
            _ = mpv_command(mpv, buffer.baseAddress)
        }
    }
}

private let mpvRenderUpdateCallback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { ctx in
    guard let ctx else { return }
    let view = Unmanaged<MPVOpenGLView>.fromOpaque(ctx).takeUnretainedValue()
    view.requestRender()
}

final class MPVOpenGLView: GLKView {
    private var displayLink: CADisplayLink?
    private var needsRender = false
    private weak var viewModel: MPVPlayerViewModel?

    init(viewModel: MPVPlayerViewModel) {
        let context = EAGLContext(api: .openGLES3) ?? EAGLContext(api: .openGLES2)!
        self.viewModel = viewModel
        super.init(frame: .zero, context: context)

        enableSetNeedsDisplay = true
        drawableDepthFormat = .format24

        EAGLContext.setCurrent(context)
        viewModel.initializeIfNeeded()
        viewModel.createRenderContext { name in
            guard let name else { return nil }
            return UnsafeMutableRawPointer(EAGLGetProcAddress(name))
        }

        viewModel.setRenderUpdateCallback(mpvRenderUpdateCallback,
                                          ctx: Unmanaged.passUnretained(self).toOpaque())

        displayLink = CADisplayLink(target: self, selector: #selector(onDisplayLink))
        displayLink?.add(to: .main, forMode: .common)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func requestRender() {
        needsRender = true
    }

    @objc private func onDisplayLink() {
        guard needsRender else { return }
        needsRender = false
        display()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        guard let vm = viewModel else { return }
        let size = drawableSize
        vm.render(fbo: 0, width: Int32(size.width), height: Int32(size.height), flipY: 1)
    }

    deinit {
        displayLink?.invalidate()
    }
}

final class MPVPlayerHostController: UIViewController {
    private let playerView: MPVOpenGLView

    init(viewModel: MPVPlayerViewModel) {
        self.playerView = MPVOpenGLView(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = playerView
    }

    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}

struct MPVPlayerContainer: UIViewControllerRepresentable {
    let viewModel: MPVPlayerViewModel

    func makeUIViewController(context: Context) -> MPVPlayerHostController {
        MPVPlayerHostController(viewModel: viewModel)
    }

    func updateUIViewController(_ uiViewController: MPVPlayerHostController, context: Context) {}
}
