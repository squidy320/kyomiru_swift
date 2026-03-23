import SwiftUI
#if os(iOS)
import AVFoundation
import AVKit
import UIKit
#if canImport(Libmpv)
import Libmpv
#endif
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
            if appState.settings.playerEngine == .mpv {
#if canImport(Libmpv)
                MPVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle,
                    startAt: startAt,
                    onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture
                )
#else
                AVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle,
                    startAt: startAt,
                    onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture
                )
#endif
            } else {
                AVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle,
                    startAt: startAt,
                    onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture
                )
            }
#else
            Text("Playback is only supported on iOS.")
#endif
        }
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

#if canImport(Libmpv)
private struct MPVPlayerScreen: View {
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

    @StateObject private var playbackState: MPVPlaybackState
    @State private var skipSegments: [AniSkipSegment] = []
    @State private var activeSkip: AniSkipSegment?
    @State private var didMarkWatched = false
    @State private var controlsVisible = true
    @State private var sliderValue: Double = 0
    @State private var isScrubbing = false
    @State private var pendingResumeTime: Double?
    @State private var didApplyInitialResumeSeek = false
    @State private var hideControlsTask: DispatchWorkItem?
    @State private var holdSpeedActive = false

    init(
        episode: SoraEpisode,
        sources: [SoraSource],
        mediaId: Int,
        malId: Int?,
        mediaTitle: String?,
        startAt: Double?,
        onRestoreAfterPictureInPicture: (() -> Void)?
    ) {
        self.episode = episode
        self.sources = sources
        self.mediaId = mediaId
        self.malId = malId
        self.mediaTitle = mediaTitle
        self.startAt = startAt
        self.onRestoreAfterPictureInPicture = onRestoreAfterPictureInPicture
        _playbackState = StateObject(wrappedValue: MPVPlaybackState())
    }

    private var selectedSource: SoraSource? {
        sources.first
    }

    private var resolvedPlaybackURL: URL? {
        guard let source = selectedSource else { return nil }
        return PlaybackService.resolvePlayableURL(for: source.url, title: mediaTitle, episode: episode.number)
    }

    private var resolvedHeaders: [String: String] {
        guard let source = selectedSource, let resolvedPlaybackURL else { return [:] }
        return resolvedPlaybackURL.isFileURL ? [:] : source.headers
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let resolvedPlaybackURL {
                MPVPlayerContainer(
                    playbackState: playbackState,
                    url: resolvedPlaybackURL,
                    headers: resolvedHeaders
                )
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    toggleControls()
                }
                .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 24, pressing: { pressing in
                    handleHoldSpeedChanged(pressing)
                }, perform: {})
            } else {
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
            }

            if playbackState.isBuffering {
                ProgressView()
                    .scaleEffect(1.2)
                    .tint(.white)
            }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .animation(appState.settings.reduceMotion ? nil : .easeInOut(duration: 0.18), value: controlsVisible)
        .statusBarHidden(true)
        .onAppear(perform: handleAppear)
        .onDisappear(perform: handleDisappear)
        .onChange(of: playbackState.currentTime) { newValue in
            handlePlaybackTimeChanged(newValue)
        }
        .onChange(of: playbackState.duration) { _ in
            applyPendingResumeIfNeeded(reason: "duration")
        }
        .onChange(of: playbackState.isReady) { isReady in
            if isReady {
                applyPendingResumeIfNeeded(reason: "ready")
            }
        }
        .alert("Playback Error", isPresented: Binding(
            get: { playbackState.errorMessage != nil },
            set: { _ in playbackState.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {
                dismiss()
            }
        } message: {
            Text(playbackState.errorMessage ?? "Unknown error")
        }
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                }

                Spacer()

                Text("MPV")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer()

            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    controlButton(systemName: "gobackward.15") {
                        playbackState.seekBy(-15)
                        resetControlsAutoHide()
                    }

                    controlButton(systemName: playbackState.isPaused ? "play.fill" : "pause.fill") {
                        playbackState.togglePause()
                        resetControlsAutoHide()
                    }

                    controlButton(systemName: "goforward.15") {
                        playbackState.seekBy(15)
                        resetControlsAutoHide()
                    }

                    Spacer()

                    if let activeSkip {
                        Button {
                            seekToSkipEnd(activeSkip)
                        } label: {
                            Text(skipButtonTitle(for: activeSkip))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(.ultraThinMaterial, in: Capsule())
                        }
                    }
                }

                GlassCard {
                    VStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { isScrubbing ? sliderValue : playbackState.currentTime },
                                set: { sliderValue = $0 }
                            ),
                            in: 0...max(playbackState.duration, 1),
                            onEditingChanged: { editing in
                                isScrubbing = editing
                                if editing {
                                    sliderValue = playbackState.currentTime
                                    resetControlsAutoHide()
                                } else {
                                    playbackState.seek(to: sliderValue)
                                    resetControlsAutoHide()
                                }
                            }
                        )
                        .tint(Theme.accent)

                        HStack {
                            Text(formattedTime(isScrubbing ? sliderValue : playbackState.currentTime))
                            Spacer()
                            Text(formattedTime(playbackState.duration))
                        }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
    }

    private func handleAppear() {
        guard selectedSource != nil else {
            playbackState.errorMessage = "No playable sources available."
            return
        }

        PlaybackHistoryStore.shared.saveLastEpisode(
            mediaId: mediaId,
            episodeId: episode.id,
            episodeNumber: episode.number
        )

        if let explicitStart = startAt, explicitStart > 0 {
            pendingResumeTime = explicitStart
        } else if let savedPosition = PlaybackHistoryStore.shared.position(for: episode.id),
                  savedPosition >= Self.minimumSavedResumeSeconds {
            pendingResumeTime = savedPosition
        } else {
            pendingResumeTime = nil
        }

        loadSkipSegments()
        resetControlsAutoHide()
    }

    private func handleDisappear() {
        hideControlsTask?.cancel()
        playbackState.stop()
    }

    private func handlePlaybackTimeChanged(_ seconds: Double) {
        guard seconds.isFinite else { return }
        if !isScrubbing {
            sliderValue = seconds
        }
        updateActiveSkip(at: seconds)
        applyPendingResumeIfNeeded(reason: "time")

        let duration = playbackState.duration
        guard duration > 0 else { return }

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
                }
            }
        }
    }

    private func applyPendingResumeIfNeeded(reason: String) {
        guard let pendingResumeTime, !didApplyInitialResumeSeek else { return }
        guard playbackState.isReady, playbackState.duration > 0 else { return }
        if playbackState.currentTime > 2 {
            didApplyInitialResumeSeek = true
            self.pendingResumeTime = nil
            return
        }

        didApplyInitialResumeSeek = true
        self.pendingResumeTime = nil
        AppLog.debug(.player, "mpv seek: resume time=\(pendingResumeTime) reason=\(reason)")
        playbackState.seek(to: pendingResumeTime)
    }

    private func toggleControls() {
        controlsVisible.toggle()
        if controlsVisible {
            resetControlsAutoHide()
        } else {
            hideControlsTask?.cancel()
        }
    }

    private func resetControlsAutoHide() {
        hideControlsTask?.cancel()
        guard !appState.settings.reduceMotion else { return }
        let task = DispatchWorkItem {
            controlsVisible = false
        }
        hideControlsTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: task)
    }

    private func handleHoldSpeedChanged(_ isActive: Bool) {
        guard playbackState.isReady else { return }
        if isActive {
            guard !playbackState.isPaused, !holdSpeedActive else { return }
            holdSpeedActive = true
            playbackState.setSpeed(appState.settings.playerHoldSpeed.rawValue)
        } else if holdSpeedActive {
            holdSpeedActive = false
            playbackState.setSpeed(1.0)
        }
    }

    private func loadSkipSegments() {
        guard let malId else {
            skipSegments = []
            activeSkip = nil
            return
        }
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: episode.number) {
            skipSegments = cached
            updateActiveSkip(at: playbackState.currentTime)
        } else {
            skipSegments = []
        }
        Task {
            let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: episode.number)
            guard !segments.isEmpty else { return }
            await MainActor.run {
                skipSegments = segments
                updateActiveSkip(at: playbackState.currentTime)
            }
            appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: episode.number)
        }
    }

    private func updateActiveSkip(at time: Double) {
        guard !skipSegments.isEmpty else {
            activeSkip = nil
            return
        }
        let matches = skipSegments.filter { time >= $0.start && time <= $0.end }
        activeSkip = matches.min(by: { $0.end < $1.end })
    }

    private func seekToSkipEnd(_ segment: AniSkipSegment) {
        activeSkip = nil
        playbackState.seek(to: segment.end)
        resetControlsAutoHide()
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

    private func formattedTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

private final class MPVPlaybackState: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPaused: Bool = false
    @Published var isBuffering: Bool = false
    @Published var isReady: Bool = false
    @Published var errorMessage: String?

    weak var controller: MPVMetalViewController?

    func attach(controller: MPVMetalViewController) {
        self.controller = controller
    }

    func togglePause() {
        controller?.togglePause()
    }

    func seek(to seconds: Double) {
        controller?.seek(to: seconds)
    }

    func seekBy(_ delta: Double) {
        controller?.seekBy(delta)
    }

    func setSpeed(_ speed: Double) {
        controller?.setPlaybackSpeed(speed)
    }

    func stop() {
        controller?.stop()
    }
}

private struct MPVPlayerContainer: UIViewControllerRepresentable {
    @ObservedObject var playbackState: MPVPlaybackState
    let url: URL
    let headers: [String: String]

    func makeUIViewController(context: Context) -> MPVMetalViewController {
        let controller = MPVMetalViewController(playbackState: playbackState, url: url, headers: headers)
        playbackState.attach(controller: controller)
        return controller
    }

    func updateUIViewController(_ uiViewController: MPVMetalViewController, context: Context) {
        uiViewController.updateSource(url: url, headers: headers)
        playbackState.attach(controller: uiViewController)
    }
}

private final class MPVMetalRenderView: UIView {
    let playerLayer = MPVMetalLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        backgroundColor = .black
        layer.addSublayer(playerLayer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
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

private final class MPVMetalViewController: UIViewController {
    private let playbackState: MPVPlaybackState
    private let renderView = MPVMetalRenderView()
    private var metalLayer: MPVMetalLayer
    private var currentURL: URL
    private var currentHeaders: [String: String]
    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "kyomiru.mpv", qos: .userInitiated)
    private var hasLoadedSource = false

    init(playbackState: MPVPlaybackState, url: URL, headers: [String: String]) {
        self.playbackState = playbackState
        self.currentURL = url
        self.currentHeaders = headers
        self.metalLayer = renderView.playerLayer
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = renderView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        metalLayer.contentsScale = UIScreen.main.nativeScale
        metalLayer.framebufferOnly = true
        metalLayer.backgroundColor = UIColor.black.cgColor
        setupMpv()
        loadCurrentSourceIfNeeded()
    }

    deinit {
        teardown()
    }

    func updateSource(url: URL, headers: [String: String]) {
        let didChange = currentURL != url || currentHeaders != headers
        currentURL = url
        currentHeaders = headers
        if didChange, mpv != nil {
            loadCurrentSourceIfNeeded(force: true)
        }
    }

    func togglePause() {
        getFlag("pause") ? play() : pause()
    }

    func play() {
        setFlag("pause", false)
    }

    func pause() {
        setFlag("pause", true)
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        command("seek", args: [String(clamped), "absolute+exact"])
    }

    func seekBy(_ delta: Double) {
        command("seek", args: [String(delta), "relative+exact"])
    }

    func setPlaybackSpeed(_ speed: Double) {
        var value = speed
        guard let mpv else { return }
        mpv_set_property(mpv, "speed", MPV_FORMAT_DOUBLE, &value)
    }

    func stop() {
        teardown()
    }

    private func setupMpv() {
        let player = mpv_create()
        guard let player else {
            playbackState.errorMessage = "Failed to create MPV player."
            return
        }
        mpv = player

#if DEBUG
        _ = mpv_request_log_messages(player, "debug")
#else
        _ = mpv_request_log_messages(player, "warn")
#endif

        _ = mpv_set_option(player, "wid", MPV_FORMAT_INT64, &metalLayer)
        _ = mpv_set_option_string(player, "vo", "gpu-next")
        _ = mpv_set_option_string(player, "gpu-api", "vulkan")
        _ = mpv_set_option_string(player, "gpu-context", "moltenvk")
        _ = mpv_set_option_string(player, "hwdec", "videotoolbox")
        _ = mpv_set_option_string(player, "video-rotate", "no")
        _ = mpv_set_option_string(player, "force-seekable", "yes")
        _ = mpv_set_option_string(player, "cache", "yes")
        _ = mpv_set_option_string(player, "demuxer-seekable-cache", "yes")
        _ = mpv_set_option_string(player, "profile", "fast")

        let initializeResult = mpv_initialize(player)
        if initializeResult < 0 {
            playbackState.errorMessage = String(cString: mpv_error_string(initializeResult))
            teardown()
            return
        }

        mpv_observe_property(player, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(player, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(player, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(player, 0, "paused-for-cache", MPV_FORMAT_FLAG)

        mpv_set_wakeup_callback(player, { context in
            guard let context else { return }
            let controller = Unmanaged<MPVMetalViewController>.fromOpaque(context).takeUnretainedValue()
            controller.readEvents()
        }, UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
    }

    private func loadCurrentSourceIfNeeded(force: Bool = false) {
        guard let mpv else { return }
        guard force || !hasLoadedSource else { return }
        hasLoadedSource = true

        applyHeaders(currentHeaders, to: mpv)

        let target = currentURL.absoluteString
        let result = command("loadfile", args: [target, "replace"], checkForErrors: false)
        if result < 0 {
            playbackState.errorMessage = String(cString: mpv_error_string(result))
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.playbackState.isReady = true
            }
        }
    }

    private func applyHeaders(_ headers: [String: String], to mpv: OpaquePointer) {
        let normalized = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        if let userAgent = normalized["user-agent"] {
            _ = mpv_set_option_string(mpv, "user-agent", userAgent)
        }
        if let referer = normalized["referer"] {
            _ = mpv_set_option_string(mpv, "referrer", referer)
        }

        let headerFields = headers
            .filter {
                $0.key.caseInsensitiveCompare("user-agent") != .orderedSame &&
                $0.key.caseInsensitiveCompare("referer") != .orderedSame
            }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: ",")
        if !headerFields.isEmpty {
            _ = mpv_set_option_string(mpv, "http-header-fields", headerFields)
        }
    }

    private func teardown() {
        guard let mpv else { return }
        mpv_set_wakeup_callback(mpv, nil, nil)
        mpv_terminate_destroy(mpv)
        self.mpv = nil
    }

    private func readEvents() {
        queue.async { [weak self] in
            guard let self, let mpv = self.mpv else { return }

            while true {
                guard let event = mpv_wait_event(mpv, 0) else { break }
                if event.pointee.event_id == MPV_EVENT_NONE {
                    break
                }

                switch event.pointee.event_id {
                case MPV_EVENT_PROPERTY_CHANGE:
                    guard let property = UnsafePointer<mpv_event_property>(OpaquePointer(event.pointee.data))?.pointee else {
                        continue
                    }
                    let name = String(cString: property.name)
                    switch name {
                    case "time-pos", "duration":
                        let value = UnsafePointer<Double>(OpaquePointer(property.data))?.pointee ?? 0
                        DispatchQueue.main.async {
                            if name == "time-pos" {
                                self.playbackState.currentTime = value
                            } else {
                                self.playbackState.duration = value
                            }
                        }
                    case "pause", "paused-for-cache":
                        let flagValue = (UnsafePointer<Int64>(OpaquePointer(property.data))?.pointee ?? 0) > 0
                        DispatchQueue.main.async {
                            if name == "pause" {
                                self.playbackState.isPaused = flagValue
                            } else {
                                self.playbackState.isBuffering = flagValue
                            }
                        }
                    default:
                        break
                    }
                case MPV_EVENT_FILE_LOADED:
                    DispatchQueue.main.async {
                        self.playbackState.isReady = true
                        self.playbackState.errorMessage = nil
                    }
                case MPV_EVENT_END_FILE:
                    DispatchQueue.main.async {
                        self.playbackState.isPaused = true
                    }
                case MPV_EVENT_SHUTDOWN:
                    return
                case MPV_EVENT_LOG_MESSAGE:
                    if let message = UnsafeMutablePointer<mpv_event_log_message>(OpaquePointer(event.pointee.data)) {
                        let prefix = message.pointee.prefix.map { String(cString: $0) } ?? "mpv"
                        let level = message.pointee.level.map { String(cString: $0) } ?? "info"
                        let text = message.pointee.text.map { String(cString: $0) } ?? ""
                        AppLog.debug(.player, "[\(prefix)] \(level): \(text)")
                    }
                default:
                    break
                }
            }
        }
    }

    @discardableResult
    private func command(_ command: String, args: [String?] = [], checkForErrors: Bool = true) -> Int32 {
        guard let mpv else { return Int32.min }
        var cargs = makeCArgs(command, args).map { $0.flatMap { UnsafePointer<CChar>(strdup($0)) } }
        defer {
            for pointer in cargs where pointer != nil {
                free(UnsafeMutablePointer(mutating: pointer))
            }
        }
        let result = mpv_command(mpv, &cargs)
        if checkForErrors, result < 0 {
            let message = String(cString: mpv_error_string(result))
            DispatchQueue.main.async {
                self.playbackState.errorMessage = message
            }
        }
        return result
    }

    private func makeCArgs(_ command: String, _ args: [String?]) -> [String?] {
        var values = args
        values.insert(command, at: 0)
        values.append(nil)
        return values
    }

    private func getFlag(_ name: String) -> Bool {
        guard let mpv else { return true }
        var data = Int64()
        mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &data)
        return data > 0
    }

    private func setFlag(_ name: String, _ value: Bool) {
        guard let mpv else { return }
        var data: Int64 = value ? 1 : 0
        mpv_set_property(mpv, name, MPV_FORMAT_FLAG, &data)
    }
}
#endif
#endif
