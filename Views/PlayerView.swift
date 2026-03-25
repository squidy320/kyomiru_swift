import SwiftUI
#if os(iOS)
import AVFoundation
import AVKit
import UIKit
#endif

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onRestoreAfterPictureInPicture: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @State private var forceAVPlayerForSession = false
    @State private var sessionFallbackMessage: String?

    init(
        episode: SoraEpisode,
        sources: [SoraSource],
        mediaId: Int,
        malId: Int?,
        mediaTitle: String?,
        startAt: Double? = nil,
        onRestoreAfterPictureInPicture: (() -> Void)? = nil
    ) {
        self.episode = episode
        self.sources = sources
        self.mediaId = mediaId
        self.malId = malId
        self.mediaTitle = mediaTitle
        self.startAt = startAt
        self.onRestoreAfterPictureInPicture = onRestoreAfterPictureInPicture
    }

    var body: some View {
        Group {
#if os(iOS)
            switch effectiveBackend {
            case .avPlayer:
                AVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle,
                    startAt: startAt,
                    onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture
                )
            case .mpv:
                MPVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle,
                    startAt: startAt,
                    onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture
                ) { message in
                    sessionFallbackMessage = message
                    forceAVPlayerForSession = true
                }
            }
#else
            Text("Playback is only supported on iOS.")
#endif
        }
        .alert("Playback Engine Changed", isPresented: Binding(
            get: { sessionFallbackMessage != nil },
            set: { _ in sessionFallbackMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(sessionFallbackMessage ?? "")
        }
    }

    private var effectiveBackend: PlayerBackend {
        forceAVPlayerForSession ? .avPlayer : appState.settings.playerBackend
    }
}

#if os(iOS)
private struct AVPlayerScreen: View {
    private static let minimumSavedResumeSeconds: Double = 5
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onRestoreAfterPictureInPicture: (() -> Void)?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var timeObserver: Any?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var itemObservers: [NSKeyValueObservation] = []
    @State private var playbackStallObserver: NSObjectProtocol?
    @State private var errorMessage: String?
    @State private var skipSegments: [AniSkipSegment] = []
    @State private var activeSkip: AniSkipSegment?
    @State private var didMarkWatched = false
    @State private var isSeeking = false
    @State private var didApplyInitialResumeSeek = false
    @State private var shouldLogBufferState = true
    @State private var pendingResumeTime: Double?
    @State private var isRemoteStream = false
    @State private var isPictureInPictureActive = false
    @State private var didDismissForPictureInPicture = false
    @State private var shouldRestoreAfterPictureInPicture = false
    @State private var didRequestRestoreAfterPictureInPicture = false
    @State private var wasPlayingBeforeHoldSpeed = false
    @State private var previousPlaybackRate: Float = 1.0

    var body: some View {
        ZStack {
            if let player {
                AVPlayerViewControllerRepresentable(
                    player: player,
                    skipButtonTitle: overlaySkipButtonTitle,
                    onSkipTapped: handleOverlaySkipAction,
                    onHoldSpeedChanged: handleHoldSpeedChanged,
                    onPictureInPictureStarted: handlePictureInPictureStarted,
                    onPictureInPictureStopped: handlePictureInPictureStopped,
                    onRestoreFromPictureInPicture: restoreUserInterfaceFromPictureInPicture,
                    onPictureInPictureFailed: handlePictureInPictureFailed
                )
                .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
            }
        }
        .onAppear {
            loadSkipSegments()
            startPlayback()
        }
        .onDisappear(perform: handleDisappear)
        .alert("Playback Error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { _ in errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {
                dismiss()
            }
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func startPlayback() {
        if player != nil { return }
#if os(iOS) && !targetEnvironment(macCatalyst)
        do {
            let session = AVAudioSession.sharedInstance()
            do {
                try session.setCategory(.playback, mode: .moviePlayback, options: [])
            } catch {
                AppLog.error(.player, "audio session moviePlayback failed: \(error.localizedDescription)")
                try session.setCategory(.playback, mode: .default, options: [])
            }
            try session.setActive(true)
        } catch {
            AppLog.error(.player, "audio session setup failed: \(error.localizedDescription)")
        }
#endif
        PlaybackHistoryStore.shared.saveLastEpisode(
            mediaId: mediaId,
            episodeId: episode.id,
            episodeNumber: episode.number
        )

        guard let source = sources.first else {
            errorMessage = "No playable sources available."
            return
        }

        let resolved = PlaybackService.resolvePlayableURL(for: source.url, title: mediaTitle, episode: episode.number)
        isRemoteStream = !resolved.isFileURL
        let headers = resolved.isFileURL ? [:] : source.headers

        let asset: AVURLAsset
        if headers.isEmpty {
            asset = AVURLAsset(url: resolved)
        } else {
            asset = AVURLAsset(url: resolved, options: [
                "AVURLAssetHTTPHeaderFieldsKey": headers
            ])
        }

        let item = AVPlayerItem(asset: asset)
        if isRemoteStream {
            item.preferredForwardBufferDuration = 0
            if #available(iOS 10.0, *) {
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            }
        }
        playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = true
        player = avPlayer

        addObservers(to: avPlayer, item: item)
        avPlayer.play()
    }

    private func handleDisappear() {
        if isPictureInPictureActive || didDismissForPictureInPicture {
            AppLog.debug(.player, "pip: keeping playback alive while view disappears")
            return
        }
        stopPlayback()
    }

    private func stopPlayback() {
        guard let player else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        if let playbackStallObserver {
            NotificationCenter.default.removeObserver(playbackStallObserver)
            self.playbackStallObserver = nil
        }
        pendingResumeTime = nil
        isSeeking = false
        didApplyInitialResumeSeek = false
        shouldLogBufferState = true
        isRemoteStream = false
        activeSkip = nil
        didMarkWatched = false
        isPictureInPictureActive = false
        didDismissForPictureInPicture = false
        shouldRestoreAfterPictureInPicture = false
        didRequestRestoreAfterPictureInPicture = false
        wasPlayingBeforeHoldSpeed = false
        previousPlaybackRate = 1.0
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerItem = nil
    }

    private func addObservers(to player: AVPlayer, item: AVPlayerItem) {
        didApplyInitialResumeSeek = false
        if let explicitStart = startAt, explicitStart > 0 {
            pendingResumeTime = explicitStart
        } else if let savedPosition = PlaybackHistoryStore.shared.position(for: episode.id),
                  savedPosition >= Self.minimumSavedResumeSeconds {
            pendingResumeTime = savedPosition
        } else {
            pendingResumeTime = nil
            PlaybackHistoryStore.shared.clearEpisode(episodeId: episode.id)
        }

        statusObserver = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            switch observed.status {
            case .readyToPlay:
                applyPendingResumeIfNeeded(reason: "readyToPlay")
            case .failed:
                errorMessage = observed.error?.localizedDescription ?? "Playback failed."
            default:
                break
            }
        }

        itemObservers = [
            item.observe(\.isPlaybackBufferEmpty, options: [.new]) { observed, _ in
                if observed.isPlaybackBufferEmpty {
                    AppLog.debug(.player, "buffer: empty")
                }
            },
            item.observe(\.isPlaybackBufferFull, options: [.new]) { observed, _ in
                if observed.isPlaybackBufferFull {
                    AppLog.debug(.player, "buffer: full")
                }
            },
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { observed, _ in
                if shouldLogBufferState {
                    AppLog.debug(.player, "buffer: likelyToKeepUp=\(observed.isPlaybackLikelyToKeepUp)")
                }
                if observed.isPlaybackLikelyToKeepUp, !isRemoteStream {
                    applyPendingResumeIfNeeded(reason: "likelyToKeepUp")
                }
            },
            item.observe(\.seekableTimeRanges, options: [.initial, .new]) { _, _ in
                if !isRemoteStream {
                    applyPendingResumeIfNeeded(reason: "seekableRanges")
                }
            }
        ]

        playbackStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            AppLog.debug(.player, "buffer: stalled remote=\(isRemoteStream) seeking=\(isSeeking)")
            guard isRemoteStream else { return }
            player.play()
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            if isRemoteStream, seconds >= 1 {
                applyPendingResumeIfNeeded(reason: "playbackAdvanced")
            }
            updateActiveSkip(at: seconds)
            if isSeeking { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration > 0 {
                let fraction = seconds / duration
                if !didMarkWatched, fraction >= 0.85 {
                    didMarkWatched = true
                    Task { await appState.markEpisodeWatched(mediaId: mediaId, episodeNumber: episode.number) }
                    PlaybackHistoryStore.shared.clearMedia(mediaId: mediaId)
                }
                Task { @MainActor in
                    appState.services.playbackEngine.updateProgress(
                        for: String(mediaId),
                        currentTime: seconds,
                        duration: duration
                    )
                    appState.services.playbackEngine.updateProgress(
                        for: "episode:\(episode.id)",
                        currentTime: seconds,
                        duration: duration
                    )
                    if !didMarkWatched {
                        PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
                        if seconds >= Self.minimumSavedResumeSeconds {
                            PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                        } else {
                            PlaybackHistoryStore.shared.clearEpisode(episodeId: episode.id)
                            PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
                        }
                    }
                }
            }
        }
    }

    private func loadSkipSegments() {
        guard let malId else {
            skipSegments = []
            activeSkip = nil
            AppLog.debug(.player, "aniskip: no malId for mediaId=\(mediaId) ep=\(episode.number)")
            return
        }
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: episode.number) {
            skipSegments = cached
            updateActiveSkip(at: currentPlaybackTime)
            AppLog.debug(.player, "aniskip: cache hit malId=\(malId) ep=\(episode.number) count=\(cached.count)")
        } else {
            skipSegments = []
            AppLog.debug(.player, "aniskip: cache miss malId=\(malId) ep=\(episode.number)")
        }
        Task {
            let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: episode.number)
            guard !segments.isEmpty else {
                AppLog.debug(.player, "aniskip: no segments malId=\(malId) ep=\(episode.number)")
                return
            }
            await MainActor.run {
                skipSegments = segments
                updateActiveSkip(at: currentPlaybackTime)
                AppLog.debug(.player, "aniskip: fetched malId=\(malId) ep=\(episode.number) count=\(segments.count)")
            }
            appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: episode.number)
        }
    }

    private func updateActiveSkip(at time: Double) {
        guard !skipSegments.isEmpty else {
            if activeSkip != nil { activeSkip = nil }
            return
        }
        let matches = skipSegments.filter { time >= $0.start && time <= $0.end }
        if let match = matches.min(by: { $0.end < $1.end }) {
            if activeSkip?.start != match.start || activeSkip?.end != match.end || activeSkip?.type != match.type {
                activeSkip = match
                AppLog.debug(.player, "aniskip: active type=\(match.type) start=\(match.start) end=\(match.end) time=\(time)")
            }
        } else if activeSkip != nil {
            activeSkip = nil
        }
    }

    private func seekToSkipEnd(_ segment: AniSkipSegment) {
        activeSkip = nil
        requestSeek(to: segment.end, reason: "skip:\(segment.type)", shouldResumePlayback: true)
    }

    private func requestSeek(to seconds: Double, reason: String, shouldResumePlayback: Bool? = nil) {
        guard let player, let item = player.currentItem else { return }
        guard item.status == .readyToPlay else {
            AppLog.debug(.player, "seek: ignored until ready time=\(seconds) reason=\(reason)")
            return
        }
        let shouldResume = shouldResumePlayback ?? (player.timeControlStatus != .paused || player.rate > 0)
        performDirectSeek(
            player: player,
            item: item,
            seconds: seconds,
            reason: reason,
            shouldResumePlayback: shouldResume
        )
    }

    private func applyPendingResumeIfNeeded(reason: String) {
        guard let seconds = pendingResumeTime else { return }
        guard let item = playerItem, item.status == .readyToPlay else { return }
        guard let player else { return }
        if didApplyInitialResumeSeek {
            pendingResumeTime = nil
            return
        }
        if isRemoteStream && currentPlaybackTime > 3 {
            pendingResumeTime = nil
            didApplyInitialResumeSeek = true
            return
        }
        pendingResumeTime = nil
        didApplyInitialResumeSeek = true
        performDirectSeek(
            player: player,
            item: item,
            seconds: seconds,
            reason: "resume:\(reason)",
            shouldResumePlayback: true
        )
    }

    private func performDirectSeek(
        player: AVPlayer,
        item: AVPlayerItem,
        seconds: Double,
        reason: String,
        shouldResumePlayback: Bool
    ) {
        let clampedSeconds = clampedSeekTime(seconds, item: item)
        let tolerance = CMTime(seconds: isRemoteStream ? 1.0 : 0.25, preferredTimescale: 600)
        let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)

        isSeeking = true
        item.cancelPendingSeeks()
        AppLog.debug(.player, "seek: perform time=\(clampedSeconds) reason=\(reason)")
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            AppLog.debug(.player, "seek: finished=\(finished) time=\(clampedSeconds) reason=\(reason)")
            isSeeking = false
            if shouldResumePlayback {
                resumePlaybackAfterSeek(player: player)
            }
        }

        if shouldResumePlayback {
            resumePlaybackAfterSeek(player: player)
        }
    }

    private func clampedSeekTime(_ seconds: Double, item: AVPlayerItem) -> Double {
        var clamped = max(0, seconds)
        let duration = item.duration.seconds
        if duration.isFinite, duration > 1 {
            clamped = min(clamped, duration - 0.5)
        }
        return clamped
    }

    private func resumePlaybackAfterSeek(player: AVPlayer) {
        player.play()
    }

    private func skipButtonTitle(for segment: AniSkipSegment) -> String {
        switch segment.type.lowercased() {
        case "op":
            return "Skip Intro"
        case "ed":
            return "Skip Outro"
        case "recap":
            return "Skip Recap"
        case "preview":
            return "Skip Preview"
        default:
            return "Skip"
        }
    }

    private var overlaySkipButtonTitle: String? {
        guard let activeSkip else { return nil }
        return skipButtonTitle(for: activeSkip)
    }

    private var currentPlaybackTime: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func handleOverlaySkipAction() {
        guard let activeSkip else { return }
        seekToSkipEnd(activeSkip)
    }

    private func handleHoldSpeedChanged(_ isActive: Bool) {
        guard let player else { return }

        if isActive {
            guard player.timeControlStatus != .paused || player.rate > 0 else { return }
            wasPlayingBeforeHoldSpeed = true
            previousPlaybackRate = player.rate > 0 ? player.rate : 1.0
            player.rate = Float(appState.settings.playerHoldSpeed.rawValue)
            AppLog.debug(.player, "hold speed active rate=\(appState.settings.playerHoldSpeed.rawValue)")
        } else {
            guard wasPlayingBeforeHoldSpeed else { return }
            let restoreRate = previousPlaybackRate > 0 ? previousPlaybackRate : 1.0
            player.rate = restoreRate
            wasPlayingBeforeHoldSpeed = false
            previousPlaybackRate = 1.0
            AppLog.debug(.player, "hold speed ended restoreRate=\(restoreRate)")
        }
    }

    private func handlePictureInPictureStarted() {
        isPictureInPictureActive = true
        didDismissForPictureInPicture = true
        shouldRestoreAfterPictureInPicture = true
        didRequestRestoreAfterPictureInPicture = false
        AppLog.debug(.player, "pip: started")
        DispatchQueue.main.async {
            dismiss()
        }
    }

    private func handlePictureInPictureStopped() {
        AppLog.debug(.player, "pip: stopped")
        isPictureInPictureActive = false
        if shouldRestoreAfterPictureInPicture && didDismissForPictureInPicture && !didRequestRestoreAfterPictureInPicture {
            didRequestRestoreAfterPictureInPicture = true
            onRestoreAfterPictureInPicture?()
        }
    }

    private func restoreUserInterfaceFromPictureInPicture(_ completion: @escaping (Bool) -> Void) {
        AppLog.debug(.player, "pip: restore requested")
        isPictureInPictureActive = false
        didRequestRestoreAfterPictureInPicture = true
        onRestoreAfterPictureInPicture?()
        DispatchQueue.main.async {
            completion(true)
        }
    }

    private func handlePictureInPictureFailed(_ error: Error) {
        AppLog.error(.player, "pip: failed start error=\(error.localizedDescription)")
        isPictureInPictureActive = false
        didDismissForPictureInPicture = false
        shouldRestoreAfterPictureInPicture = false
        didRequestRestoreAfterPictureInPicture = false
    }

}

private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipButtonTitle: String?
    let onSkipTapped: () -> Void
    let onHoldSpeedChanged: (Bool) -> Void
    let onPictureInPictureStarted: () -> Void
    let onPictureInPictureStopped: () -> Void
    let onRestoreFromPictureInPicture: (@escaping (Bool) -> Void) -> Void
    let onPictureInPictureFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSkipTapped: onSkipTapped,
            onHoldSpeedChanged: onHoldSpeedChanged,
            onPictureInPictureStarted: onPictureInPictureStarted,
            onPictureInPictureStopped: onPictureInPictureStopped,
            onRestoreFromPictureInPicture: onRestoreFromPictureInPicture,
            onPictureInPictureFailed: onPictureInPictureFailed
        )
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        context.coordinator.installSkipButtonIfNeeded(in: controller)
        context.coordinator.installHoldSpeedRecognizerIfNeeded(in: controller)
        context.coordinator.updateSkipButtonTitle(skipButtonTitle)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        context.coordinator.onSkipTapped = onSkipTapped
        context.coordinator.onHoldSpeedChanged = onHoldSpeedChanged
        context.coordinator.onPictureInPictureStarted = onPictureInPictureStarted
        context.coordinator.onPictureInPictureStopped = onPictureInPictureStopped
        context.coordinator.onRestoreFromPictureInPicture = onRestoreFromPictureInPicture
        context.coordinator.onPictureInPictureFailed = onPictureInPictureFailed
        uiViewController.delegate = context.coordinator
        context.coordinator.installSkipButtonIfNeeded(in: uiViewController)
        context.coordinator.installHoldSpeedRecognizerIfNeeded(in: uiViewController)
        context.coordinator.updateSkipButtonTitle(skipButtonTitle)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate, UIGestureRecognizerDelegate {
        var onSkipTapped: () -> Void
        var onHoldSpeedChanged: (Bool) -> Void
        var onPictureInPictureStarted: () -> Void
        var onPictureInPictureStopped: () -> Void
        var onRestoreFromPictureInPicture: (@escaping (Bool) -> Void) -> Void
        var onPictureInPictureFailed: (Error) -> Void
        private weak var skipButton: UIButton?
        private weak var blurView: SkipOverlayView?
        private weak var progressSlider: UISlider?
        private weak var holdRecognizer: UILongPressGestureRecognizer?
        private var syncTask: Task<Void, Never>?
        private var placementConstraints: [NSLayoutConstraint] = []
        private var isSkipButtonEnabled = false

        init(
            onSkipTapped: @escaping () -> Void,
            onHoldSpeedChanged: @escaping (Bool) -> Void,
            onPictureInPictureStarted: @escaping () -> Void,
            onPictureInPictureStopped: @escaping () -> Void,
            onRestoreFromPictureInPicture: @escaping (@escaping (Bool) -> Void) -> Void,
            onPictureInPictureFailed: @escaping (Error) -> Void
        ) {
            self.onSkipTapped = onSkipTapped
            self.onHoldSpeedChanged = onHoldSpeedChanged
            self.onPictureInPictureStarted = onPictureInPictureStarted
            self.onPictureInPictureStopped = onPictureInPictureStopped
            self.onRestoreFromPictureInPicture = onRestoreFromPictureInPicture
            self.onPictureInPictureFailed = onPictureInPictureFailed
        }

        deinit {
            syncTask?.cancel()
        }

        func installSkipButtonIfNeeded(in controller: AVPlayerViewController) {
            if skipButton != nil, blurView != nil {
                attachButtonNearProgressBarIfNeeded(in: controller)
                ensureSyncTask(for: controller)
                return
            }

            let blur = SkipOverlayView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            blur.translatesAutoresizingMaskIntoConstraints = false
            blur.clipsToBounds = true
            blur.layer.cornerRadius = 18
            blur.layer.cornerCurve = .continuous
            blur.layer.borderWidth = 1
            blur.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor
            blur.isUserInteractionEnabled = true

            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            button.isUserInteractionEnabled = true
            button.isExclusiveTouch = true
            button.addTarget(self, action: #selector(handleSkipTap), for: .touchUpInside)
            button.addTarget(self, action: #selector(handleSkipTouchDown), for: .touchDown)

            blur.contentView.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
                button.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
                button.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor)
            ])

            skipButton = button
            blurView = blur
            attachButtonNearProgressBarIfNeeded(in: controller)
            ensureSyncTask(for: controller)
        }

        func updateSkipButtonTitle(_ title: String?) {
            skipButton?.setTitle(title, for: .normal)
            isSkipButtonEnabled = !(title?.isEmpty ?? true)
            blurView?.isHidden = !isSkipButtonEnabled
            blurView?.isUserInteractionEnabled = isSkipButtonEnabled
        }

        func installHoldSpeedRecognizerIfNeeded(in controller: AVPlayerViewController) {
            if holdRecognizer != nil { return }
            let recognizer = UILongPressGestureRecognizer(target: self, action: #selector(handleHoldSpeed(_:)))
            recognizer.minimumPressDuration = 0.25
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            controller.view.addGestureRecognizer(recognizer)
            holdRecognizer = recognizer
        }

        private func ensureSyncTask(for controller: AVPlayerViewController) {
            guard syncTask == nil || syncTask?.isCancelled == true else { return }
            syncTask = Task { @MainActor [weak self, weak controller] in
                while !Task.isCancelled {
                    guard let self, let controller else { break }
                    self.attachButtonNearProgressBarIfNeeded(in: controller)
                    self.syncButtonVisibility()
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
        }

        private func attachButtonNearProgressBarIfNeeded(in controller: AVPlayerViewController) {
            guard let blurView else { return }

            if let slider = findProgressSlider(in: controller.view) {
                progressSlider = slider
                let host = slider.superview ?? controller.view!
                if blurView.superview !== host {
                    blurView.removeFromSuperview()
                    host.addSubview(blurView)
                    NSLayoutConstraint.deactivate(placementConstraints)
                    blurView.translatesAutoresizingMaskIntoConstraints = false
                    placementConstraints = [
                        blurView.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
                        blurView.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -12)
                    ]
                    NSLayoutConstraint.activate(placementConstraints)
                }
                host.bringSubviewToFront(blurView)
            } else if blurView.superview == nil, let overlay = controller.contentOverlayView {
                overlay.addSubview(blurView)
                NSLayoutConstraint.deactivate(placementConstraints)
                placementConstraints = [
                    blurView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
                    blurView.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -56)
                ]
                NSLayoutConstraint.activate(placementConstraints)
                overlay.bringSubviewToFront(blurView)
            }
        }

        private func syncButtonVisibility() {
            guard let blurView else { return }
            guard isSkipButtonEnabled else {
                blurView.alpha = 0
                blurView.isUserInteractionEnabled = false
                blurView.isHidden = true
                return
            }
            if let slider = progressSlider {
                let shouldShow = !slider.isHidden && slider.alpha > 0.05 && !(slider.superview?.isHidden ?? false)
                blurView.alpha = shouldShow ? (slider.superview?.alpha ?? slider.alpha) : 0
                blurView.isUserInteractionEnabled = shouldShow
                blurView.isHidden = !shouldShow
            } else {
                blurView.alpha = 1
                blurView.isHidden = false
            }
        }

        private func findProgressSlider(in root: UIView) -> UISlider? {
            var matches: [UISlider] = []

            func collect(from view: UIView) {
                if let slider = view as? UISlider,
                   slider.bounds.width > 120,
                   !slider.isHidden,
                   slider.alpha > 0.01 {
                    matches.append(slider)
                }
                for subview in view.subviews {
                    collect(from: subview)
                }
            }

            collect(from: root)
            guard !matches.isEmpty else { return nil }

            return matches.max { lhs, rhs in
                let leftPoint = lhs.convert(lhs.bounds.origin, to: root)
                let rightPoint = rhs.convert(rhs.bounds.origin, to: root)
                if abs(leftPoint.y - rightPoint.y) < 8 {
                    return lhs.bounds.width < rhs.bounds.width
                }
                return leftPoint.y < rightPoint.y
            }
        }

        @objc
        private func handleSkipTap() {
            onSkipTapped()
        }

        @objc
        private func handleSkipTouchDown() {
            blurView?.alpha = 1
            blurView?.isHidden = false
        }

        @objc
        private func handleHoldSpeed(_ recognizer: UILongPressGestureRecognizer) {
            switch recognizer.state {
            case .began:
                onHoldSpeedChanged(true)
            case .ended, .cancelled, .failed:
                onHoldSpeedChanged(false)
            default:
                break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard gestureRecognizer === holdRecognizer else { return true }
            if touch.view is UIControl {
                return false
            }
            var view = touch.view
            while let current = view {
                if current is UIControl || current is UISlider || current is UIButton || current is SkipOverlayView {
                    return false
                }
                view = current.superview
            }
            return true
        }

        func playerViewControllerWillStartPictureInPicture(_ playerViewController: AVPlayerViewController) {
            onPictureInPictureStarted()
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            onPictureInPictureStopped()
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
        ) {
            onRestoreFromPictureInPicture(completionHandler)
        }

        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            onPictureInPictureFailed(error)
        }
    }

    final class SkipOverlayView: UIVisualEffectView {
        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            let expandedBounds = bounds.insetBy(dx: -12, dy: -8)
            return expandedBounds.contains(point)
        }
    }
}

#endif
