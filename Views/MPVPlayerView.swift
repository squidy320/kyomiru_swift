import SwiftUI
#if os(iOS)
import AVFoundation
import QuartzCore
import UIKit
#if canImport(Libmpv)
import Libmpv

private enum MPVPlaybackCommand {
    case seek(Double)
}

private protocol MPVViewControllerDelegate: AnyObject {
    func mpvReady(_ controller: MPVViewController)
    func mpv(_ controller: MPVViewController, didUpdateTime time: Double)
    func mpv(_ controller: MPVViewController, didUpdateDuration duration: Double)
    func mpv(_ controller: MPVViewController, didChangePauseState isPaused: Bool)
    func mpv(_ controller: MPVViewController, didChangeBufferingState isBuffering: Bool)
    func mpvDidReachEnd(_ controller: MPVViewController)
    func mpv(_ controller: MPVViewController, didFailWithMessage message: String)
}

private struct MPVResolvedSource: Equatable {
    let url: URL
    let headers: [String: String]
}

private func resolvedMPVSource(
    sources: [SoraSource],
    mediaTitle: String?,
    episodeNumber: Int
) -> MPVResolvedSource? {
    guard let source = sources.first else { return nil }
    let resolvedURL = PlaybackService.resolvePlayableURL(for: source.url, title: mediaTitle, episode: episodeNumber)
    return MPVResolvedSource(url: resolvedURL, headers: resolvedURL.isFileURL ? [:] : source.headers)
}

private func mpvSkipTitle(for segment: AniSkipSegment) -> String {
    switch segment.type.lowercased() {
    case "op": return "Skip Intro"
    case "ed": return "Skip Outro"
    case "recap": return "Skip Recap"
    case "preview": return "Skip Preview"
    default: return "Skip"
    }
}

private func mpvTimeString(_ value: Double) -> String {
    guard value.isFinite else { return "--:--" }
    let seconds = max(Int(value.rounded(.down)), 0)
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let remainder = seconds % 60
    return hours > 0
        ? String(format: "%d:%02d:%02d", hours, minutes, remainder)
        : String(format: "%02d:%02d", minutes, remainder)
}

struct MPVPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onFallbackToAVPlayer: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var skipSegments: [AniSkipSegment] = []
    @State private var activeSkip: AniSkipSegment?
    @State private var command: MPVPlaybackCommand?
    @State private var commandToken = 0
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPaused = false
    @State private var isBuffering = true
    @State private var didMarkWatched = false
    @State private var pendingResumeTime: Double?
    @State private var didApplyResume = false
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var showControls = true
    @State private var errorMessage: String?
    @State private var autoHideTask: Task<Void, Never>?

    private var source: MPVResolvedSource? {
        resolvedMPVSource(sources: sources, mediaTitle: mediaTitle, episodeNumber: episode.number)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let source {
                MPVPlayerRepresentable(
                    source: source,
                    paused: isPaused,
                    command: command,
                    commandToken: commandToken,
                    onReady: handleReady,
                    onTimeChanged: handleTimeChanged(_:),
                    onDurationChanged: { duration = $0 },
                    onPauseChanged: { isPaused = $0 },
                    onBufferingChanged: { isBuffering = $0 },
                    onEnded: handleEnded,
                    onError: handleError(_:)
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    scheduleAutoHide()
                }

                overlay
            } else {
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
                    .task {
                        onFallbackToAVPlayer("No playable source was available for mpv, so this session was switched back to AVPlayer.")
                    }
            }
        }
        .onAppear {
            preparePlayback()
            loadSkipSegments()
            scheduleAutoHide()
        }
        .onDisappear { autoHideTask?.cancel() }
        .alert("Playback Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { _ in errorMessage = nil }
        )) {
            Button("Switch to AVPlayer") {
                onFallbackToAVPlayer("mpv could not continue playback, so this session was switched back to AVPlayer.")
            }
            Button("Close", role: .cancel) { dismiss() }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var overlay: some View {
        VStack {
            if showControls {
                HStack {
                    Spacer()
                    Text("mpv")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.82))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.black.opacity(0.45)))
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }

            Spacer()

            if isBuffering {
                ProgressView().tint(.white)
            }

            if let activeSkip, showControls {
                Button(mpvSkipTitle(for: activeSkip)) {
                    seek(to: activeSkip.end)
                    self.activeSkip = nil
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundColor(.white)
                .padding(.bottom, 12)
            }

            if showControls {
                VStack(spacing: 12) {
                    HStack(spacing: 16) {
                        Button {
                            isPaused.toggle()
                            scheduleAutoHide()
                        } label: {
                            Image(systemName: isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 48, height: 48)
                                .background(Circle().fill(Color.white.opacity(0.14)))
                        }
                        .foregroundColor(.white)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(mediaTitle ?? "Episode \(episode.number)")
                                .foregroundColor(.white)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1)
                            Text("Episode \(episode.number)")
                                .foregroundColor(.white.opacity(0.72))
                                .font(.system(size: 12))
                        }
                        Spacer()
                    }

                    Slider(
                        value: Binding(
                            get: { isScrubbing ? scrubTime : currentTime },
                            set: { scrubTime = $0 }
                        ),
                        in: 0...max(duration, 1),
                        onEditingChanged: { editing in
                            isScrubbing = editing
                            if editing {
                                scrubTime = currentTime
                                autoHideTask?.cancel()
                            } else {
                                seek(to: scrubTime)
                                scheduleAutoHide()
                            }
                        }
                    )
                    .tint(.white)

                    HStack {
                        Text(mpvTimeString(isScrubbing ? scrubTime : currentTime))
                        Spacer()
                        Text(mpvTimeString(duration))
                    }
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.78))
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 22).fill(Color.black.opacity(0.58)))
                .padding(.horizontal, 16)
                .padding(.bottom, 22)
                .transition(.opacity)
            }
        }
    }

    private func preparePlayback() {
#if !targetEnvironment(macCatalyst)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            AppLog.error(.player, "mpv audio session setup failed: \(error.localizedDescription)")
        }
#endif
        PlaybackHistoryStore.shared.saveLastEpisode(mediaId: mediaId, episodeId: episode.id, episodeNumber: episode.number)
        if let startAt, startAt > 0 {
            pendingResumeTime = startAt
        } else if let saved = PlaybackHistoryStore.shared.position(for: episode.id), saved >= 5 {
            pendingResumeTime = saved
        } else {
            PlaybackHistoryStore.shared.clearEpisode(episodeId: episode.id)
        }
    }

    private func handleReady() {
        guard !didApplyResume, let pendingResumeTime else { return }
        didApplyResume = true
        seek(to: pendingResumeTime)
        self.pendingResumeTime = nil
    }

    private func handleTimeChanged(_ time: Double) {
        currentTime = time
        if !isScrubbing { scrubTime = time }
        updateActiveSkip(at: time)
        guard duration > 0 else { return }
        let fraction = time / duration
        if !didMarkWatched, fraction >= 0.85 {
            didMarkWatched = true
            Task { await appState.markEpisodeWatched(mediaId: mediaId, episodeNumber: episode.number) }
            PlaybackHistoryStore.shared.clearMedia(mediaId: mediaId)
        }
        appState.services.playbackEngine.updateProgress(for: String(mediaId), currentTime: time, duration: duration)
        appState.services.playbackEngine.updateProgress(for: "episode:\(episode.id)", currentTime: time, duration: duration)
        if !didMarkWatched {
            PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
            if time >= 5 {
                PlaybackHistoryStore.shared.save(position: time, for: episode.id)
            }
        }
    }

    private func handleEnded() {
        currentTime = duration
        isPaused = true
        if !didMarkWatched {
            didMarkWatched = true
            Task { await appState.markEpisodeWatched(mediaId: mediaId, episodeNumber: episode.number) }
            PlaybackHistoryStore.shared.clearMedia(mediaId: mediaId)
        }
    }

    private func handleError(_ message: String) {
        AppLog.error(.player, "mpv error: \(message)")
        errorMessage = message
    }

    private func seek(to seconds: Double) {
        command = .seek(seconds)
        commandToken += 1
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard !isPaused else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { showControls = false }
        }
    }

    private func loadSkipSegments() {
        guard let malId else { return }
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: episode.number) {
            skipSegments = cached
        }
        Task {
            let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: episode.number)
            guard !segments.isEmpty else { return }
            await MainActor.run { skipSegments = segments }
            appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: episode.number)
        }
    }

    private func updateActiveSkip(at time: Double) {
        let matches = skipSegments.filter { time >= $0.start && time <= $0.end }
        activeSkip = matches.min(by: { $0.end < $1.end })
    }
}

private struct MPVPlayerRepresentable: UIViewControllerRepresentable {
    let source: MPVResolvedSource
    let paused: Bool
    let command: MPVPlaybackCommand?
    let commandToken: Int
    let onReady: () -> Void
    let onTimeChanged: (Double) -> Void
    let onDurationChanged: (Double) -> Void
    let onPauseChanged: (Bool) -> Void
    let onBufferingChanged: (Bool) -> Void
    let onEnded: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onReady: onReady, onTimeChanged: onTimeChanged, onDurationChanged: onDurationChanged, onPauseChanged: onPauseChanged, onBufferingChanged: onBufferingChanged, onEnded: onEnded, onError: onError)
    }

    func makeUIViewController(context: Context) -> MPVViewController {
        let controller = MPVViewController()
        controller.delegate = context.coordinator
        context.coordinator.lastSource = source
        controller.load(source: source)
        controller.setPaused(paused)
        return controller
    }

    func updateUIViewController(_ uiViewController: MPVViewController, context: Context) {
        if context.coordinator.lastSource != source {
            context.coordinator.lastSource = source
            uiViewController.load(source: source)
        }
        uiViewController.setPaused(paused)
        if context.coordinator.lastCommandToken != commandToken {
            context.coordinator.lastCommandToken = commandToken
            if case .seek(let seconds)? = command {
                uiViewController.seek(to: seconds)
            }
        }
    }

    static func dismantleUIViewController(_ uiViewController: MPVViewController, coordinator: Coordinator) {
        uiViewController.shutdown()
    }

    final class Coordinator: NSObject, MPVViewControllerDelegate {
        let onReady: () -> Void
        let onTimeChanged: (Double) -> Void
        let onDurationChanged: (Double) -> Void
        let onPauseChanged: (Bool) -> Void
        let onBufferingChanged: (Bool) -> Void
        let onEnded: () -> Void
        let onError: (String) -> Void
        var lastCommandToken = 0
        var lastSource: MPVResolvedSource?

        init(
            onReady: @escaping () -> Void,
            onTimeChanged: @escaping (Double) -> Void,
            onDurationChanged: @escaping (Double) -> Void,
            onPauseChanged: @escaping (Bool) -> Void,
            onBufferingChanged: @escaping (Bool) -> Void,
            onEnded: @escaping () -> Void,
            onError: @escaping (String) -> Void
        ) {
            self.onReady = onReady
            self.onTimeChanged = onTimeChanged
            self.onDurationChanged = onDurationChanged
            self.onPauseChanged = onPauseChanged
            self.onBufferingChanged = onBufferingChanged
            self.onEnded = onEnded
            self.onError = onError
        }

        func mpvReady(_ controller: MPVViewController) { onReady() }
        func mpv(_ controller: MPVViewController, didUpdateTime time: Double) { onTimeChanged(time) }
        func mpv(_ controller: MPVViewController, didUpdateDuration duration: Double) { onDurationChanged(duration) }
        func mpv(_ controller: MPVViewController, didChangePauseState isPaused: Bool) { onPauseChanged(isPaused) }
        func mpv(_ controller: MPVViewController, didChangeBufferingState isBuffering: Bool) { onBufferingChanged(isBuffering) }
        func mpvDidReachEnd(_ controller: MPVViewController) { onEnded() }
        func mpv(_ controller: MPVViewController, didFailWithMessage message: String) { onError(message) }
    }
}

private final class MPVViewController: UIViewController {
    weak var delegate: MPVViewControllerDelegate?
    private let metalLayer = MPVMetalLayer()
    private let queue = DispatchQueue(label: "kyomiru.mpv", qos: .userInitiated)
    private var mpv: OpaquePointer?
    private var isSetup = false
    private var currentSource: MPVResolvedSource?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        view.layer.addSublayer(metalLayer)
        setupIfNeeded()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        metalLayer.frame = view.bounds
    }

    func load(source: MPVResolvedSource) {
        currentSource = source
        setupIfNeeded()
        guard let mpv else { return }
        let headers = source.headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" }.joined(separator: ",")
        check(mpv_set_option_string(mpv, "http-header-fields", headers))
        run("loadfile", args: [source.url.absoluteString, "replace"])
    }

    func setPaused(_ paused: Bool) {
        guard let mpv else { return }
        var value: Int32 = paused ? 1 : 0
        mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &value)
    }

    func seek(to seconds: Double) {
        run("seek", args: [String(seconds), "absolute+exact"])
    }

    func shutdown() {
        NotificationCenter.default.removeObserver(self)
        guard let mpv else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
        self.mpv = nil
        isSetup = false
    }

    deinit {
        shutdown()
    }

    private func setupIfNeeded() {
        guard !isSetup else { return }
        isSetup = true
        mpv = mpv_create()
        guard let mpv else {
            delegate?.mpv(self, didFailWithMessage: "mpv could not be created.")
            return
        }
#if DEBUG
        check(mpv_request_log_messages(mpv, "info"))
#else
        check(mpv_request_log_messages(mpv, "no"))
#endif
        var wid = metalLayer
        check(mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid))
        check(mpv_set_option_string(mpv, "vo", "gpu-next"))
        check(mpv_set_option_string(mpv, "gpu-api", "vulkan"))
        check(mpv_set_option_string(mpv, "gpu-context", "moltenvk"))
        check(mpv_set_option_string(mpv, "hwdec", "videotoolbox"))
        check(mpv_set_option_string(mpv, "subs-match-os-language", "yes"))
        check(mpv_set_option_string(mpv, "subs-fallback", "yes"))
        check(mpv_initialize(mpv))
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let controller = Unmanaged<MPVViewController>.fromOpaque(context).takeUnretainedValue()
            controller.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func run(_ command: String, args: [String]) {
        guard let mpv else { return }
        var cArgs = ([command] + args).map { strdup($0) }
        cArgs.append(nil)
        defer {
            for arg in cArgs where arg != nil { free(arg) }
        }
        check(mpv_command(mpv, &cArgs))
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self else { return }
            while let mpv = self.mpv {
                let event = mpv_wait_event(mpv, 0)
                guard let event else { break }
                if event.pointee.event_id == MPV_EVENT_NONE { break }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: UnsafeMutablePointer<mpv_event>) {
        switch event.pointee.event_id {
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let propertyPointer = event.pointee.data?.assumingMemoryBound(to: mpv_event_property.self) else { return }
            let property = propertyPointer.pointee
            let name = String(cString: property.name)
            DispatchQueue.main.async { self.handleProperty(name: name, data: property.data) }
        case MPV_EVENT_FILE_LOADED:
            DispatchQueue.main.async { self.delegate?.mpvReady(self) }
        case MPV_EVENT_END_FILE:
            DispatchQueue.main.async { self.delegate?.mpvDidReachEnd(self) }
        default:
            break
        }
    }

    private func handleProperty(name: String, data: UnsafeMutableRawPointer?) {
        switch name {
        case "time-pos":
            delegate?.mpv(self, didUpdateTime: data?.assumingMemoryBound(to: Double.self).pointee ?? 0)
        case "duration":
            delegate?.mpv(self, didUpdateDuration: data?.assumingMemoryBound(to: Double.self).pointee ?? 0)
        case "pause":
            delegate?.mpv(self, didChangePauseState: (data?.assumingMemoryBound(to: Int32.self).pointee ?? 0) != 0)
        case "paused-for-cache":
            delegate?.mpv(self, didChangeBufferingState: (data?.assumingMemoryBound(to: Int32.self).pointee ?? 0) != 0)
        default:
            break
        }
    }

    private func check(_ status: Int32) {
        guard status < 0 else { return }
        let message = String(cString: mpv_error_string(status))
        DispatchQueue.main.async { self.delegate?.mpv(self, didFailWithMessage: message) }
    }
}

private final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 {
                super.drawableSize = newValue
            }
        }
    }
}

#else
struct MPVPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onFallbackToAVPlayer: (String) -> Void

    var body: some View {
        Color.black.ignoresSafeArea().task {
            onFallbackToAVPlayer("The mpv runtime is unavailable in this build, so this session was switched back to AVPlayer.")
        }
    }
}
#endif
#endif
