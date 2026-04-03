import SwiftUI
#if os(iOS)
import AVFoundation
import AVKit
import QuartzCore
import UIKit
#if canImport(Libmpv)
import Libmpv

private enum MPVPlaybackCommand {
    case seek(Double)
    case setPaused(Bool)
    case setRate(Double)
    case commandString(String)
    case setSpeedProperty(String)
}

private struct MPVQueuedPlaybackCommand: Identifiable {
    let id: Int
    let command: MPVPlaybackCommand
}

private struct MPVResolvedSource: Equatable {
    let url: URL
    let headers: [String: String]
}

@MainActor
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

@MainActor
private final class MPVPlaybackController: ObservableObject {
    private static let controlsAutoHideDelayNanoseconds: UInt64 = 5_000_000_000

    struct Context {
        let episode: SoraEpisode
        let mediaId: Int
        let malId: Int?
        let mediaTitle: String?
        let startAt: Double?
    }

    @Published var currentTime: Double = 0
    @Published var displayedTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPaused = false
    @Published var isBuffering = true
    @Published var errorMessage: String?
    @Published var showControls = true
    @Published var activeSkip: AniSkipSegment?
    @Published var activeIntroSegment: AniSkipSegment?
    @Published var isPictureInPictureActive = false
    @Published var isPictureInPicturePossible = AVPictureInPictureController.isPictureInPictureSupported()
    @Published var playbackSpeed: Double = 1.0
    @Published var isLongPressSpeedActive = false
    @Published private(set) var commandToken = 0
    @Published private(set) var pendingCommands: [MPVQueuedPlaybackCommand] = []

    let context: Context

    private var appState: AppState?
    private var skipSegments: [AniSkipSegment] = []
    private var introSegments: [AniSkipSegment] = []
    private var didApplyResume = false
    private var pendingResumeTime: Double?
    private var didMarkWatched = false
    private var autoHideTask: Task<Void, Never>?
    private var autoHideGeneration = 0
    private var onRestoreAfterPictureInPicture: (() -> Void)?
    private var onDismissForPictureInPicture: (() -> Void)?
    private var currentSource: MPVResolvedSource?
    private var pendingSeekTime: Double?
    private var pendingSeekIssuedAt: Date?
    private var previousIdleTimerDisabled = false

    init(context: Context) {
        self.context = context
    }

    func configure(
        appState: AppState,
        source: MPVResolvedSource,
        onRestoreAfterPictureInPicture: (() -> Void)?,
        onDismissForPictureInPicture: (() -> Void)?
    ) {
        self.appState = appState
        self.currentSource = source
        self.onRestoreAfterPictureInPicture = onRestoreAfterPictureInPicture
        self.onDismissForPictureInPicture = onDismissForPictureInPicture
        preparePlayback()
        setIdleTimerDisabled(true)
        Task { await loadSkipSegments() }
        scheduleAutoHide()
    }

    func cleanup() {
        autoHideTask?.cancel()
        setIdleTimerDisabled(false)
    }

    func toggleControlsVisibility() {
        if showControls {
            autoHideTask?.cancel()
            autoHideGeneration += 1
            showControls = false
        } else {
            noteInteraction()
        }
    }

    func noteInteraction() {
        autoHideGeneration += 1
        showControls = true
        scheduleAutoHide()
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        sendCommand(.setPaused(paused))
        scheduleAutoHide()
    }

    func togglePaused() {
        setPaused(!isPaused)
    }

    func seek(to seconds: Double) {
        let clampedTime = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, seconds))
        pendingSeekTime = clampedTime
        pendingSeekIssuedAt = Date()
        displayedTime = clampedTime
        updateActiveSkip(at: clampedTime)
        sendCommand(.seek(clampedTime))
        noteInteraction()
    }

    func skip(by interval: Double) {
        let baseTime = pendingSeekTime ?? currentTime
        let target = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, baseTime + interval))
        seek(to: target)
    }

    func handleDoubleTapLeft() {
        skip(by: -10)
    }

    func handleDoubleTapRight() {
        skip(by: 10)
    }

    var shouldShowSkipIntro: Bool {
        activeIntroSegment != nil
    }

    func skipIntro() {
        guard let intro = activeIntroSegment else { return }
        seek(to: intro.end)
    }

    func skip85Relative() {
        skip(by: 85)
    }

    var introProgressRange: ClosedRange<Double>? {
        guard duration > 0 else { return nil }
        guard let intro = introSegments.first else { return nil }
        let start = min(max(intro.start / duration, 0), 1)
        let end = min(max(intro.end / duration, 0), 1)
        guard end > start else { return nil }
        return start...end
    }

    func beginHoldSpeed() {
        guard !isLongPressSpeedActive else { return }
        guard !isPaused else { return }
        isLongPressSpeedActive = true
        autoHideTask?.cancel()
        autoHideGeneration += 1
        showControls = false
        sendCommand(.setSpeedProperty("2.0"))
    }

    func endHoldSpeed() {
        guard isLongPressSpeedActive else { return }
        isLongPressSpeedActive = false
        playbackSpeed = 1.0
        sendCommand(.setSpeedProperty("1.0"))
        noteInteraction()
    }

    func cyclePlaybackSpeed() {
        let speeds: [Double] = [1.0, 1.25, 1.5, 2.0]
        let index = speeds.firstIndex(of: playbackSpeed) ?? 0
        let next = speeds[(index + 1) % speeds.count]
        playbackSpeed = next
        sendCommand(.setSpeedProperty(String(format: "%.2f", next)))
        noteInteraction()
    }

    func handleReady() {
        isBuffering = false
        guard !didApplyResume, let pendingResumeTime else { return }
        didApplyResume = true
        seek(to: pendingResumeTime)
        self.pendingResumeTime = nil
    }

    func handleTimeChanged(_ time: Double) {
        guard abs(time - currentTime) >= 0.2 || pendingSeekTime != nil else { return }
        currentTime = time
        
        if let pendingSeekTime, abs(time - pendingSeekTime) <= 1.0 {
            self.pendingSeekTime = nil
            pendingSeekIssuedAt = nil
        } else if let pendingSeekTime, abs(time - pendingSeekTime) > 1.0 {
            let age = Date().timeIntervalSince(pendingSeekIssuedAt ?? .distantPast)
            if age < 1.5 {
                displayedTime = pendingSeekTime
                updateActiveSkip(at: pendingSeekTime)
                syncProgress(currentTime: pendingSeekTime, duration: duration)
                return
            }
            self.pendingSeekTime = nil
            pendingSeekIssuedAt = nil
        }
        
        displayedTime = time
        syncProgress(currentTime: time, duration: duration)
        updateActiveSkip(at: time)
        
        if let appState, appState.settings.autoSkipSegments, let active = activeSkip {
            AppLog.debug(.player, "aniskip: mpv auto-skipping type=\(active.type)")
            seek(to: active.end)
        }
    }

    func handleDurationChanged(_ duration: Double) {
        guard abs(self.duration - duration) >= 0.5 || (self.duration == 0) != (duration == 0) else { return }
        self.duration = duration
        if displayedTime > duration, duration > 0 {
            displayedTime = duration
        }
    }

    func handlePauseChanged(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            autoHideTask?.cancel()
            showControls = true
        } else {
            scheduleAutoHide()
        }
    }

    func handleBufferingChanged(_ buffering: Bool) {
        guard isBuffering != buffering else { return }
        isBuffering = buffering
        if buffering {
            autoHideTask?.cancel()
            showControls = true
        } else {
            scheduleAutoHide()
        }
    }

    func handleEnded() {
        currentTime = duration
        displayedTime = duration
        pendingSeekTime = nil
        pendingSeekIssuedAt = nil
        isPaused = true
        markWatchedIfNeeded()
    }

    func handleError(_ message: String) {
        AppLog.error(.player, "mpv error: \(message)")
        errorMessage = message
    }

    func startPictureInPicture() {
        guard let source = currentSource else { return }
        guard !isPictureInPictureActive else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            errorMessage = "Picture in Picture is not supported on this device."
            return
        }
        MPVPictureInPictureSession.shared.start(
            source: source,
            startTime: currentTime,
            mediaId: context.mediaId,
            episodeId: context.episode.id,
            episodeNumber: context.episode.number,
            appState: appState,
            onStart: { [weak self] in
                guard let self else { return }
                self.isPictureInPictureActive = true
                self.onDismissForPictureInPicture?()
            },
            onStop: { [weak self] restoredPosition in
                guard let self else { return }
                self.isPictureInPictureActive = false
                self.pendingResumeTime = restoredPosition
                self.didApplyResume = false
                self.pendingSeekTime = restoredPosition
                self.displayedTime = restoredPosition
            },
            onRestore: { [weak self] restoredPosition in
                guard let self else { return }
                self.pendingResumeTime = restoredPosition
                self.didApplyResume = false
                self.pendingSeekTime = restoredPosition
                self.displayedTime = restoredPosition
                self.onRestoreAfterPictureInPicture?()
            },
            onError: { [weak self] message in
                self?.isPictureInPictureActive = false
                self?.errorMessage = message
            }
        )
    }

    func startPictureInPictureIfPossible() {
        guard !isPaused else { return }
        guard currentSource != nil else { return }
        guard !isPictureInPictureActive else { return }
        startPictureInPicture()
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
        PlaybackHistoryStore.shared.saveLastEpisode(
            mediaId: context.mediaId,
            episodeId: context.episode.id,
            episodeNumber: context.episode.number
        )
        if let startAt = context.startAt, startAt > 0 {
            pendingResumeTime = startAt
            displayedTime = startAt
        } else if let saved = PlaybackHistoryStore.shared.position(for: context.episode.id), saved >= 5 {
            pendingResumeTime = saved
            displayedTime = saved
        } else {
            displayedTime = 0
            PlaybackHistoryStore.shared.clearEpisode(episodeId: context.episode.id)
        }
    }

    private func syncProgress(currentTime: Double, duration: Double) {
        guard duration > 0 else { return }
        appState?.services.playbackEngine.updateProgress(for: String(context.mediaId), currentTime: currentTime, duration: duration)
        appState?.services.playbackEngine.updateProgress(for: "episode:\(context.episode.id)", currentTime: currentTime, duration: duration)

        if !didMarkWatched {
            PlaybackHistoryStore.shared.saveDuration(duration, for: context.episode.id)
            if currentTime >= 5 {
                PlaybackHistoryStore.shared.save(position: currentTime, for: context.episode.id)
            } else {
                PlaybackHistoryStore.shared.clearEpisode(episodeId: context.episode.id)
                PlaybackHistoryStore.shared.saveDuration(duration, for: context.episode.id)
            }
        }
        markWatchedIfNeeded()
    }

    private func markWatchedIfNeeded() {
        guard !didMarkWatched else { return }
        guard duration > 0 else { return }
        let fraction = currentTime / duration
        guard fraction >= 0.85 else { return }
        didMarkWatched = true
        PlaybackHistoryStore.shared.clearMedia(mediaId: context.mediaId)
        if let appState {
            Task { await appState.markEpisodeWatched(mediaId: context.mediaId, episodeNumber: context.episode.number) }
        }
    }

    private func sendCommand(_ command: MPVPlaybackCommand) {
        commandToken += 1
        pendingCommands.append(MPVQueuedPlaybackCommand(id: commandToken, command: command))
        if pendingCommands.count > 32 {
            pendingCommands.removeFirst(pendingCommands.count - 32)
        }
    }

    private func loadSkipSegments() async {
        guard let appState, let malId = context.malId else { return }
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: context.episode.number) {
            skipSegments = cached
            introSegments = cached.filter { $0.type.lowercased() == "op" }.sorted(by: { $0.start < $1.start })
            updateActiveSkip(at: displayedTime)
        }
        let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: context.episode.number)
        guard !segments.isEmpty else { return }
        skipSegments = segments
        introSegments = segments.filter { $0.type.lowercased() == "op" }.sorted(by: { $0.start < $1.start })
        updateActiveSkip(at: displayedTime)
        appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: context.episode.number)
    }

    private func updateActiveSkip(at time: Double) {
        let matches = skipSegments.filter { time >= $0.start && time <= $0.end }
        activeSkip = matches.min(by: { $0.end < $1.end })
        let introMatches = introSegments.filter { time >= $0.start && time <= $0.end }
        activeIntroSegment = introMatches.min(by: { $0.end < $1.end })
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard showControls, !isPaused, !isBuffering else { return }
        let generation = autoHideGeneration
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: Self.controlsAutoHideDelayNanoseconds)
            guard !Task.isCancelled else { return }
            guard generation == self.autoHideGeneration else { return }
            self.showControls = false
        }
    }

    private func setIdleTimerDisabled(_ disabled: Bool) {
        if disabled {
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
    }
}

@MainActor
private final class MPVPictureInPictureSession: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = MPVPictureInPictureSession()

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var controller: AVPictureInPictureController?
    private var hostWindow: UIWindow?
    private var timeObserver: Any?
    private var itemStatusObserver: NSKeyValueObservation?
    private var onStart: (() -> Void)?
    private var onStop: ((Double) -> Void)?
    private var onRestore: ((Double) -> Void)?
    private var onError: ((String) -> Void)?
    private weak var appState: AppState?
    private var didMarkWatched = false
    private var didAttemptStart = false

    func start(
        source: MPVResolvedSource,
        startTime: Double,
        mediaId: Int,
        episodeId: String,
        episodeNumber: Int,
        appState: AppState?,
        onStart: @escaping () -> Void,
        onStop: @escaping (Double) -> Void,
        onRestore: @escaping (Double) -> Void,
        onError: @escaping (String) -> Void
    ) {
        stopInternal()

        self.appState = appState
        self.onStart = onStart
        self.onStop = onStop
        self.onRestore = onRestore
        self.onError = onError
        self.didMarkWatched = false
        self.didAttemptStart = false

#if !targetEnvironment(macCatalyst)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback, options: [])
            try session.setActive(true)
        } catch {
            AppLog.error(.player, "mpv pip audio session setup failed: \(error.localizedDescription)")
        }
#endif

        let asset: AVURLAsset
        if source.headers.isEmpty {
            asset = AVURLAsset(url: source.url)
        } else {
            asset = AVURLAsset(url: source.url, options: [
                "AVURLAssetHTTPHeaderFieldsKey": source.headers
            ])
        }
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        self.player = player

        let windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        let hostWindow = windowScene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: UIScreen.main.bounds)
        hostWindow.frame = UIScreen.main.bounds
        hostWindow.windowLevel = .normal + 1
        hostWindow.backgroundColor = .clear

        let hostController = UIViewController()
        hostController.view.backgroundColor = .clear
        hostController.view.frame = hostWindow.bounds
        hostController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        hostWindow.rootViewController = hostController
        hostWindow.isHidden = false
        hostController.view.layoutIfNeeded()
        self.hostWindow = hostWindow

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = hostController.view.bounds
        playerLayer.needsDisplayOnBoundsChange = true
        playerLayer.videoGravity = .resizeAspect
        hostController.view.layer.addSublayer(playerLayer)
        self.playerLayer = playerLayer

        guard let pip = AVPictureInPictureController(playerLayer: playerLayer) else {
            onError("Picture in Picture could not be created for this source.")
            stopInternal()
            return
        }
        pip.delegate = self
        if #available(iOS 14.2, *) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
        }
        pip.requiresLinearPlayback = false
        self.controller = pip

        itemStatusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard let self else { return }
            switch observed.status {
            case .readyToPlay:
                guard !self.didAttemptStart else { return }
                self.didAttemptStart = true
                player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                player.play()
                self.installTimeObserver(mediaId: mediaId, episodeId: episodeId, episodeNumber: episodeNumber)
                DispatchQueue.main.async {
                    pip.startPictureInPicture()
                }
            case .failed:
                self.onError?(observed.error?.localizedDescription ?? "Picture in Picture failed to prepare.")
                self.stopInternal()
            default:
                break
            }
        }
    }

    private func installTimeObserver(mediaId: Int, episodeId: String, episodeNumber: Int) {
        guard let player else { return }
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            guard duration > 0 else { return }
            self.appState?.services.playbackEngine.updateProgress(for: String(mediaId), currentTime: seconds, duration: duration)
            self.appState?.services.playbackEngine.updateProgress(for: "episode:\(episodeId)", currentTime: seconds, duration: duration)
            PlaybackHistoryStore.shared.saveDuration(duration, for: episodeId)
            if seconds >= 5 {
                PlaybackHistoryStore.shared.save(position: seconds, for: episodeId)
            }
            if !self.didMarkWatched, seconds / duration >= 0.85 {
                self.didMarkWatched = true
                PlaybackHistoryStore.shared.clearMedia(mediaId: mediaId)
                if let appState = self.appState {
                    Task { await appState.markEpisodeWatched(mediaId: mediaId, episodeNumber: episodeNumber) }
                }
            }
        }
    }

    private func currentPlaybackTime() -> Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onStart?()
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        onStop?(currentPlaybackTime())
        stopInternal()
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        onRestore?(currentPlaybackTime())
        completionHandler(true)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        onError?(error.localizedDescription)
        stopInternal()
    }

    private func stopInternal() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        itemStatusObserver?.invalidate()
        itemStatusObserver = nil
        player?.pause()
        player = nil
        playerLayer?.player = nil
        playerLayer?.removeFromSuperlayer()
        playerLayer = nil
        controller = nil
        hostWindow?.isHidden = true
        hostWindow = nil
        onStart = nil
        onStop = nil
        onRestore = nil
        onError = nil
        appState = nil
    }
}

struct MPVPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onRestoreAfterPictureInPicture: (() -> Void)?
    let onFallbackToAVPlayer: (String) -> Void

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var playbackController: MPVPlaybackController
    @State private var isScrubbing = false
    @State private var wasPausedBeforeScrubbing = false
    @State private var holdSpeedActivationTask: Task<Void, Never>?

    init(
        episode: SoraEpisode,
        sources: [SoraSource],
        mediaId: Int,
        malId: Int?,
        mediaTitle: String?,
        startAt: Double?,
        onRestoreAfterPictureInPicture: (() -> Void)? = nil,
        onFallbackToAVPlayer: @escaping (String) -> Void
    ) {
        self.episode = episode
        self.sources = sources
        self.mediaId = mediaId
        self.malId = malId
        self.mediaTitle = mediaTitle
        self.startAt = startAt
        self.onRestoreAfterPictureInPicture = onRestoreAfterPictureInPicture
        self.onFallbackToAVPlayer = onFallbackToAVPlayer
        _playbackController = StateObject(
            wrappedValue: MPVPlaybackController(
                context: .init(
                    episode: episode,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle,
                    startAt: startAt
                )
            )
        )
    }

    private var source: MPVResolvedSource? {
        resolvedMPVSource(sources: sources, mediaTitle: mediaTitle, episodeNumber: episode.number)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let source {
                MPVPlayerRepresentable(
                    source: source,
                    controller: playbackController
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .overlay(alignment: .center) {
                    if playbackController.isBuffering {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.white)
                    }
                }
                .overlay { interactionLayer }
                .overlay { overlayChromeLayer }
            } else {
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
                    .task {
                        onFallbackToAVPlayer("No playable source was available for mpv, so this session was switched back to AVPlayer.")
                    }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            guard let source else { return }
            playbackController.configure(
                appState: appState,
                source: source,
                onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture,
                onDismissForPictureInPicture: { dismiss() }
            )
        }
        .onDisappear {
            holdSpeedActivationTask?.cancel()
            holdSpeedActivationTask = nil
            playbackController.endHoldSpeed()
            playbackController.cleanup()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .background else { return }
            playbackController.startPictureInPictureIfPossible()
        }
        .alert("Playback Error", isPresented: Binding(
            get: { playbackController.errorMessage != nil },
            set: { _ in playbackController.errorMessage = nil }
        )) {
            Button("Switch to AVPlayer") {
                onFallbackToAVPlayer("mpv could not continue playback, so this session was switched back to AVPlayer.")
            }
            Button("Close", role: .cancel) {
                dismiss()
            }
        } message: {
            Text(playbackController.errorMessage ?? "")
        }
        .statusBar(hidden: true)
    }

    private var overlayChromeLayer: some View {
        GeometryReader { geometry in
            overlayChrome(in: geometry)
        }
    }

    private func overlayChrome(in geometry: GeometryProxy) -> some View {
        let safeTop = geometry.safeAreaInsets.top
        let safeBottom = geometry.safeAreaInsets.bottom
        let isLandscape = geometry.size.width > geometry.size.height
        return ZStack {
            Color.clear
                .ignoresSafeArea()
                .overlay(alignment: .top) { topBar(safeTop: safeTop, isLandscape: isLandscape) }
                .overlay(alignment: .center) { centerControls(isLandscape: isLandscape) }
                .overlay(alignment: .bottom) { bottomBar(safeBottom: safeBottom, isLandscape: isLandscape) }
                .overlay(alignment: .bottomTrailing) { skip85Button(safeBottom: safeBottom, isLandscape: isLandscape) }
        }
        .opacity(playbackController.showControls && !playbackController.isLongPressSpeedActive ? 1 : 0)
        .allowsHitTesting(playbackController.showControls && !playbackController.isLongPressSpeedActive)
        .animation(.easeInOut(duration: 0.2), value: playbackController.showControls)
    }

    private func topBar(safeTop: CGFloat, isLandscape: Bool) -> some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
            }

            Spacer()

            VStack(spacing: 2) {
                Text(mediaTitle ?? "Now Playing")
                    .font(.headline)
                    .lineLimit(1)
                Text("Episode \(episode.number)")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: 220)

            Spacer()
            if playbackController.isPictureInPicturePossible {
                Button {
                    playbackController.startPictureInPicture()
                } label: {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .padding(.horizontal, isLandscape ? 18 : 10)
        .padding(.top, max(safeTop, 6))
        .padding(.bottom, 4)
    }

    private func centerControls(isLandscape: Bool) -> some View {
        HStack(spacing: isLandscape ? 58 : 46) {
            Button {
                playbackController.handleDoubleTapLeft()
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: isLandscape ? 38 : 34, weight: .semibold))
                    .foregroundStyle(.white)
            }

            Button {
                playbackController.togglePaused()
            } label: {
                Image(systemName: playbackController.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: isLandscape ? 62 : 56, weight: .bold))
                    .foregroundStyle(.white)
            }

            Button {
                playbackController.handleDoubleTapRight()
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: isLandscape ? 38 : 34, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.bottom, isLandscape ? 6 : 24)
    }

    private func bottomBar(safeBottom: CGFloat, isLandscape: Bool) -> some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { playbackController.displayedTime },
                    set: { newValue in
                        playbackController.displayedTime = newValue
                    }
                ),
                in: 0...(max(playbackController.duration, 1)),
                onEditingChanged: handleScrubbingChanged
            )
            .tint(.white)
            .controlSize(.small)

            HStack {
                Text(mpvTimeString(playbackController.displayedTime))
                Spacer()
                Text("-\(mpvTimeString(max(playbackController.duration - playbackController.displayedTime, 0)))")
                Button {
                    playbackController.cyclePlaybackSpeed()
                } label: {
                    Text(speedButtonTitle)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.black.opacity(0.45))
                        .overlay(
                            Capsule()
                                .stroke(Color.white.opacity(0.25), lineWidth: 1)
                        )
                        .clipShape(Capsule())
                }
            }
            .font(.system(size: 14, weight: .regular, design: .rounded).monospacedDigit())
            .foregroundStyle(.white.opacity(0.95))
        }
        .padding(.horizontal, isLandscape ? 28 : 18)
        .padding(.bottom, max(safeBottom, isLandscape ? 10 : 14))
    }

    private func skip85Button(safeBottom: CGFloat, isLandscape: Bool) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            playbackController.skip85Relative()
        } label: {
            Text("Skip 85s")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.45))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                )
                .clipShape(Capsule())
        }
        .padding(.trailing, 16)
        .padding(.bottom, max(safeBottom, isLandscape ? 64 : 78))
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        playbackController.noteInteraction()
        if editing {
            isScrubbing = true
            wasPausedBeforeScrubbing = playbackController.isPaused
            playbackController.displayedTime = playbackController.currentTime
            playbackController.setPaused(true)
        } else {
            isScrubbing = false
            playbackController.seek(to: playbackController.displayedTime)
            if !wasPausedBeforeScrubbing {
                playbackController.setPaused(false)
            }
        }
    }

    private var speedButtonTitle: String {
        switch playbackController.playbackSpeed {
        case 1.0: return "1.0x"
        case 1.25: return "1.25x"
        case 1.5: return "1.5x"
        case 2.0: return "2.0x"
        default: return String(format: "%.2fx", playbackController.playbackSpeed)
        }
    }

    private var interactionLayer: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        playbackController.handleDoubleTapLeft()
                    }
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        playbackController.handleDoubleTapRight()
                    }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                TapGesture(count: 1)
                    .onEnded { playbackController.toggleControlsVisibility() }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        scheduleHoldSpeedActivation()
                    }
                    .onEnded { _ in
                        cancelHoldSpeedActivation()
                        playbackController.endHoldSpeed()
                    }
            )
        }
    }

    private func scheduleHoldSpeedActivation() {
        guard holdSpeedActivationTask == nil else { return }
        holdSpeedActivationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            playbackController.beginHoldSpeed()
        }
    }

    private func cancelHoldSpeedActivation() {
        holdSpeedActivationTask?.cancel()
        holdSpeedActivationTask = nil
    }
}

@MainActor
private protocol MPVViewControllerDelegate: AnyObject {
    func mpvViewControllerDidBecomeReady(_ controller: MPVViewController)
    func mpvViewController(_ controller: MPVViewController, didUpdateTime time: Double)
    func mpvViewController(_ controller: MPVViewController, didUpdateDuration duration: Double)
    func mpvViewController(_ controller: MPVViewController, didChangePauseState isPaused: Bool)
    func mpvViewController(_ controller: MPVViewController, didChangeBufferingState isBuffering: Bool)
    func mpvViewControllerDidFinishPlayback(_ controller: MPVViewController)
    func mpvViewController(_ controller: MPVViewController, didFailWithError message: String)
}

@MainActor
extension MPVPlaybackController: MPVViewControllerDelegate {
    func mpvViewControllerDidBecomeReady(_ controller: MPVViewController) {
        handleReady()
    }

    func mpvViewController(_ controller: MPVViewController, didUpdateTime time: Double) {
        handleTimeChanged(time)
    }

    func mpvViewController(_ controller: MPVViewController, didUpdateDuration duration: Double) {
        handleDurationChanged(duration)
    }

    func mpvViewController(_ controller: MPVViewController, didChangePauseState isPaused: Bool) {
        handlePauseChanged(isPaused)
    }

    func mpvViewController(_ controller: MPVViewController, didChangeBufferingState isBuffering: Bool) {
        handleBufferingChanged(isBuffering)
    }

    func mpvViewControllerDidFinishPlayback(_ controller: MPVViewController) {
        handleEnded()
    }

    func mpvViewController(_ controller: MPVViewController, didFailWithError message: String) {
        handleError(message)
    }
}

private struct MPVPlayerRepresentable: UIViewControllerRepresentable {
    let source: MPVResolvedSource
    @ObservedObject var controller: MPVPlaybackController

    func makeUIViewController(context: Context) -> MPVViewController {
        let viewController = MPVViewController()
        viewController.delegate = controller
        viewController.load(source: source)
        return viewController
    }

    func updateUIViewController(_ uiViewController: MPVViewController, context: Context) {
        uiViewController.delegate = controller
        uiViewController.updateSourceIfNeeded(source)
        if !controller.pendingCommands.isEmpty {
            uiViewController.handle(commands: controller.pendingCommands)
        }
    }
}

private final class MPVSampleBufferPiPBridge: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    let sampleBufferLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?

    var isPaused: () -> Bool = { true }
    var setPaused: (Bool) -> Void = { _ in }
    var currentTime: () -> Double = { 0 }
    var duration: () -> Double = { 0 }
    var skipBy: (Double) -> Void = { _ in }

    func configure(in hostView: UIView) {
        sampleBufferLayer.frame = CGRect(x: 0, y: 0, width: 2, height: 2)
        sampleBufferLayer.opacity = 0.01
        sampleBufferLayer.videoGravity = .resizeAspect
        hostView.layer.addSublayer(sampleBufferLayer)

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: sampleBufferLayer,
            playbackDelegate: self
        )
        let pip = AVPictureInPictureController(contentSource: source)
        pip.canStartPictureInPictureAutomaticallyFromInline = true
        pip.requiresLinearPlayback = false
        pip.delegate = self
        controller = pip
    }

    func start() {
        controller?.startPictureInPicture()
    }

    func stop() {
        controller?.stopPictureInPicture()
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) {
        sampleBufferLayer.enqueue(sampleBuffer)
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        setPaused(!playing)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        isPaused()
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: max(duration(), 0), preferredTimescale: 600))
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, currentTimeForPlayback time: CMTime) -> CMTime {
        CMTime(seconds: max(currentTime(), 0), preferredTimescale: 600)
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion: @escaping () -> Void
    ) {
        skipBy(skipInterval.seconds)
        completion()
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}
    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, playbackTimeDidChange playbackTime: CMTime) {}
}

private final class MPVViewController: UIViewController {
    weak var delegate: MPVViewControllerDelegate?

    private let videoHostView = MPVRenderHostView()
    private let pipBridge = MPVSampleBufferPiPBridge()
    private var mpvHandle: OpaquePointer?
    private var eventsQueue = DispatchQueue(label: "kyomiru.mpv.events", qos: .userInitiated)
    private var observationTimer: Timer?
    private var currentSource: MPVResolvedSource?
    private var lastCommandToken = -1
    private var isReady = false
    private var lastReportedTime: Double?
    private var lastReportedDuration: Double?
    private var lastReportedPause: Bool?
    private var lastReportedBuffering: Bool?
    private var didReportEOF = false
    private var lastLayoutBounds: CGRect = .zero
    private var hasScheduledInitialRedraw = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.clipsToBounds = true

        videoHostView.backgroundColor = .black
        videoHostView.clipsToBounds = true
        videoHostView.frame = view.bounds
        videoHostView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(videoHostView)

        pipBridge.configure(in: view)
        pipBridge.isPaused = { [weak self] in self?.getPauseState() ?? true }
        pipBridge.setPaused = { [weak self] paused in self?.setFlagProperty(name: "pause", value: paused) }
        pipBridge.currentTime = { [weak self] in self?.getCurrentTime() ?? 0 }
        pipBridge.duration = { [weak self] in self?.getDurationValue() ?? 0 }
        pipBridge.skipBy = { [weak self] delta in
            guard let self else { return }
            let base = self.getCurrentTime()
            self.sendCommand(["seek", "\(base + delta)", "absolute+exact"])
        }
        updateRenderLayerLayout()
        initializeMPV()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateRenderLayerLayout()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        updateRenderLayerLayout()
        forceRefreshCurrentFrameIfNeeded()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateRenderLayerLayout()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.updateRenderLayerLayout()
        }, completion: { [weak self] _ in
            self?.updateRenderLayerLayout()
            self?.forceRefreshCurrentFrameIfNeeded()
        })
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent {
            teardownMPV()
        }
    }

    func load(source: MPVResolvedSource) {
        currentSource = source
        if mpvHandle == nil {
            initializeMPV()
        }
        loadCurrentSource()
    }

    func updateSourceIfNeeded(_ source: MPVResolvedSource) {
        guard currentSource != source else { return }
        load(source: source)
    }

    func handle(commands: [MPVQueuedPlaybackCommand]) {
        let newCommands = commands.filter { $0.id > lastCommandToken }.sorted { $0.id < $1.id }
        guard !newCommands.isEmpty else { return }

        for entry in newCommands {
            lastCommandToken = entry.id

            switch entry.command {
            case .seek(let seconds):
                sendCommand(["seek", "\(seconds)", "absolute+exact"])
            case .setPaused(let paused):
                setFlagProperty(name: "pause", value: paused)
            case .setRate(let rate):
                setDoubleProperty(name: "speed", value: rate)
            case .commandString(let command):
                command.withCString { cCommand in
                    _ = mpv_command_string(mpvHandle, cCommand)
                }
            case .setSpeedProperty(let speed):
                guard let handle = mpvHandle else { continue }
                speed.withCString { cSpeed in
                    _ = mpv_set_property_string(handle, "speed", cSpeed)
                }
            }
        }
    }

    private func initializeMPV() {
        guard mpvHandle == nil else { return }
        guard let handle = mpv_create() else {
            delegate?.mpvViewController(self, didFailWithError: "mpv could not be created.")
            return
        }

        mpvHandle = handle
        mpv_set_option_string(handle, "vo", "gpu")
        mpv_set_option_string(handle, "hwdec", "auto-safe")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "osd-level", "0")
        mpv_set_option_string(handle, "input-default-bindings", "yes")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "sub-auto", "fuzzy")
        mpv_set_option_string(handle, "video-sync", "audio")

        var wid = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(videoHostView.renderLayer).toOpaque())))
        withUnsafeMutablePointer(to: &wid) { ptr in
            _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, ptr)
        }

        let result = mpv_initialize(handle)
        guard result >= 0 else {
            delegate?.mpvViewController(self, didFailWithError: "mpv failed to initialize.")
            teardownMPV()
            return
        }
        "no".withCString { cString in
            _ = mpv_set_property_string(handle, "osc", cString)
        }
        var osdLevel: Int64 = 0
        withUnsafeMutablePointer(to: &osdLevel) { ptr in
            "osd-level".withCString { cName in
                _ = mpv_set_property(handle, cName, MPV_FORMAT_INT64, ptr)
            }
        }

        startObserving()
        if currentSource != nil {
            loadCurrentSource()
        }
    }

    private func loadCurrentSource() {
        guard let handle = mpvHandle, let source = currentSource else { return }
        isReady = false
        didReportEOF = false
        hasScheduledInitialRedraw = false
        lastReportedTime = nil
        lastReportedDuration = nil
        lastReportedPause = nil
        lastReportedBuffering = nil
        delegate?.mpvViewController(self, didChangeBufferingState: true)

        if !source.headers.isEmpty {
            let headerString = source.headers.map { "\($0): \($1)" }.joined(separator: "\r\n")
            headerString.withCString { cString in
                _ = mpv_set_property_string(handle, "http-header-fields", cString)
            }
        } else {
            "".withCString { cString in
                _ = mpv_set_property_string(handle, "http-header-fields", cString)
            }
        }

        sendCommand(["loadfile", source.url.absoluteString, "replace"])
    }

    private func startObserving() {
        observationTimer?.invalidate()
        observationTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollState()
        }
        observationTimer?.tolerance = 0.2
        RunLoop.main.add(observationTimer!, forMode: .common)
    }

    private func pollState() {
        guard let handle = mpvHandle else { return }
        let timePos = getDoubleProperty(name: "time-pos", handle: handle)
        let duration = getDoubleProperty(name: "duration", handle: handle)
        let pause = getFlagProperty(name: "pause", handle: handle)
        let eof = getFlagProperty(name: "eof-reached", handle: handle)
        let cache = getFlagProperty(name: "seeking", handle: handle) || getFlagProperty(name: "paused-for-cache", handle: handle)

        if duration > 0, !isReady {
            isReady = true
            delegate?.mpvViewControllerDidBecomeReady(self)
            if !hasScheduledInitialRedraw {
                hasScheduledInitialRedraw = true
                DispatchQueue.main.async { [weak self] in
                    self?.forceRefreshCurrentFrameIfNeeded()
                }
            }
        }

        if lastReportedDuration == nil || abs((lastReportedDuration ?? 0) - duration) >= 0.5 {
            lastReportedDuration = duration
            delegate?.mpvViewController(self, didUpdateDuration: duration)
        }

        if lastReportedTime == nil || abs((lastReportedTime ?? 0) - timePos) >= 0.2 || abs(timePos - duration) <= 0.2 {
            lastReportedTime = timePos
            delegate?.mpvViewController(self, didUpdateTime: timePos)
        }

        if lastReportedPause != pause {
            lastReportedPause = pause
            delegate?.mpvViewController(self, didChangePauseState: pause)
        }

        let buffering = cache || !isReady
        if lastReportedBuffering != buffering {
            lastReportedBuffering = buffering
            delegate?.mpvViewController(self, didChangeBufferingState: buffering)
        }

        if eof && !didReportEOF {
            didReportEOF = true
            delegate?.mpvViewControllerDidFinishPlayback(self)
        }

        // Frame enqueue point for true mpv PiP:
        // when mpv render loop emits CMSampleBuffer, call pipBridge.enqueue(sampleBuffer)
    }

    func enqueuePiPSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        pipBridge.enqueue(sampleBuffer)
    }

    private func getCurrentTime() -> Double {
        guard let handle = mpvHandle else { return 0 }
        return getDoubleProperty(name: "time-pos", handle: handle)
    }

    private func getDurationValue() -> Double {
        guard let handle = mpvHandle else { return 0 }
        return getDoubleProperty(name: "duration", handle: handle)
    }

    private func getPauseState() -> Bool {
        guard let handle = mpvHandle else { return true }
        return getFlagProperty(name: "pause", handle: handle)
    }

    private func sendCommand(_ values: [String]) {
        guard let handle = mpvHandle else { return }
        let duplicated = values.map { strdup($0) }
        defer { duplicated.forEach { free($0) } }

        var args = duplicated.map { ptr in
            ptr.map { UnsafePointer<CChar>($0) }
        }
        args.append(nil)
        args.withUnsafeMutableBufferPointer { buffer in
            _ = mpv_command(handle, buffer.baseAddress)
        }
    }

    private func getDoubleProperty(name: String, handle: OpaquePointer) -> Double {
        var value: Double = 0
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            name.withCString { cName in
                mpv_get_property(handle, cName, MPV_FORMAT_DOUBLE, ptr)
            }
        }
        return status >= 0 && value.isFinite ? value : 0
    }

    private func getFlagProperty(name: String, handle: OpaquePointer) -> Bool {
        var value: Int32 = 0
        let status = withUnsafeMutablePointer(to: &value) { ptr in
            name.withCString { cName in
                mpv_get_property(handle, cName, MPV_FORMAT_FLAG, ptr)
            }
        }
        return status >= 0 && value != 0
    }

    private func setDoubleProperty(name: String, value: Double) {
        guard let handle = mpvHandle else { return }
        var mutableValue = value
        withUnsafeMutablePointer(to: &mutableValue) { ptr in
            name.withCString { cName in
                _ = mpv_set_property(handle, cName, MPV_FORMAT_DOUBLE, ptr)
            }
        }
    }

    private func setFlagProperty(name: String, value: Bool) {
        guard let handle = mpvHandle else { return }
        var mutableValue: Int32 = value ? 1 : 0
        withUnsafeMutablePointer(to: &mutableValue) { ptr in
            name.withCString { cName in
                _ = mpv_set_property(handle, cName, MPV_FORMAT_FLAG, ptr)
            }
        }
    }

    private func teardownMPV() {
        observationTimer?.invalidate()
        observationTimer = nil
        lastReportedTime = nil
        lastReportedDuration = nil
        lastReportedPause = nil
        lastReportedBuffering = nil
        didReportEOF = false
        if let handle = mpvHandle {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
        }
    }

    deinit {
        teardownMPV()
    }

    private func updateRenderLayerLayout() {
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return }
        let layoutChanged = bounds != lastLayoutBounds
        lastLayoutBounds = bounds

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoHostView.frame = bounds
        let renderLayer = videoHostView.renderLayer
        renderLayer.frame = videoHostView.bounds
        renderLayer.bounds = videoHostView.bounds
        renderLayer.position = CGPoint(x: videoHostView.bounds.midX, y: videoHostView.bounds.midY)
        let scale = view.window?.screen.scale ?? view.contentScaleFactor
        renderLayer.contentsScale = scale
        renderLayer.drawableSize = CGSize(
            width: max(videoHostView.bounds.width * scale, 1),
            height: max(videoHostView.bounds.height * scale, 1)
        )
        CATransaction.commit()

        if layoutChanged {
            DispatchQueue.main.async { [weak self] in
                self?.forceRefreshCurrentFrameIfNeeded()
            }
        }
    }

    private func forceRefreshCurrentFrameIfNeeded() {
        guard isViewLoaded else { return }
        guard view.window != nil else { return }
        guard isReady else { return }
        let currentTime = getCurrentTime()
        guard currentTime.isFinite, currentTime >= 0 else { return }
        sendCommand(["seek", "\(currentTime)", "absolute+exact"])
    }
}

private final class MPVRenderHostView: UIView {
    @objc weak var delegate: AnyObject?

    override class var layerClass: AnyClass {
        MPVMetalLayer.self
    }

    var renderLayer: MPVMetalLayer {
        guard let renderLayer = layer as? MPVMetalLayer else {
            fatalError("Expected MPVMetalLayer backing layer")
        }
        return renderLayer
    }
}

private final class MPVMetalLayer: CAMetalLayer {
    override init() {
        super.init()
        pixelFormat = .bgra8Unorm
        framebufferOnly = false
        contentsScale = UIScreen.main.scale
        isOpaque = true
        backgroundColor = UIColor.black.cgColor
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
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
    let onRestoreAfterPictureInPicture: (() -> Void)?
    let onFallbackToAVPlayer: (String) -> Void

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .task {
                onFallbackToAVPlayer("mpv support is not available in this build, so this session was switched back to AVPlayer.")
            }
    }
}
#endif
#endif
