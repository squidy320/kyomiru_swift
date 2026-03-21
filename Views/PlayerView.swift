import SwiftUI
#if os(iOS)
import AVFoundation
import AVKit
#endif

#if os(iOS)
@MainActor
final class PlayerSessionController: ObservableObject, Identifiable {
    let id = UUID()
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let services: AppServices
    let markEpisodeWatched: @MainActor (Int, Int) async -> Void

    @Published var player: AVPlayer?
    @Published var errorMessage: String?
    @Published var activeSkip: AniSkipSegment?

    var isPictureInPictureActive = false
    var shouldRestoreAfterPictureInPicture = false

    private var playerItem: AVPlayerItem?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var itemObservers: [NSKeyValueObservation] = []
    private var playbackStallObserver: NSObjectProtocol?
    private var skipSegments: [AniSkipSegment] = []
    private var didMarkWatched = false
    private var isSeeking = false
    private var shouldLogBufferState = true
    private var pendingSeekRequest: PendingSeekRequest?
    private var pendingResumeTime: Double?
    private var isRemoteStream = false
    private var hasStartedPlayback = false

    init(
        episode: SoraEpisode,
        sources: [SoraSource],
        mediaId: Int,
        malId: Int?,
        mediaTitle: String?,
        startAt: Double?,
        services: AppServices,
        markEpisodeWatched: @escaping @MainActor (Int, Int) async -> Void
    ) {
        self.episode = episode
        self.sources = sources
        self.mediaId = mediaId
        self.malId = malId
        self.mediaTitle = mediaTitle
        self.startAt = startAt
        self.services = services
        self.markEpisodeWatched = markEpisodeWatched
    }

    deinit {
        Task { @MainActor in
            self.invalidateObservers()
        }
    }

    func startPlaybackIfNeeded() {
        guard !hasStartedPlayback else { return }
        hasStartedPlayback = true
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

        loadSkipSegments()
        addObservers(to: avPlayer, item: item)
        avPlayer.play()
    }

    func stopPlayback() {
        guard let player else { return }
        invalidateObservers()
        pendingSeekRequest = nil
        pendingResumeTime = nil
        isSeeking = false
        shouldLogBufferState = true
        isRemoteStream = false
        activeSkip = nil
        didMarkWatched = false
        hasStartedPlayback = false
        isPictureInPictureActive = false
        shouldRestoreAfterPictureInPicture = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerItem = nil
    }

    func clearError() {
        errorMessage = nil
    }

    func handleOverlaySkipAction() {
        if let activeSkip {
            seekToSkipEnd(activeSkip)
        } else {
            seekForwardByDefaultInterval()
        }
    }

    var overlaySkipButtonTitle: String {
        if let activeSkip {
            return skipButtonTitle(for: activeSkip)
        }
        return "+85s"
    }

    private var currentPlaybackTime: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func invalidateObservers() {
        if let player, let timeObserver {
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
    }

    private func addObservers(to player: AVPlayer, item: AVPlayerItem) {
        let startTime = startAt ?? (PlaybackHistoryStore.shared.position(for: episode.id) ?? 0)
        pendingResumeTime = startTime > 0 ? startTime : nil

        statusObserver = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            guard let self else { return }
            switch observed.status {
            case .readyToPlay:
                if !self.isRemoteStream {
                    self.applyPendingResumeIfNeeded(reason: "readyToPlay")
                }
                self.performPendingSeekIfPossible(reason: "statusReady")
            case .failed:
                self.errorMessage = observed.error?.localizedDescription ?? "Playback failed."
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
            item.observe(\.isPlaybackLikelyToKeepUp, options: [.initial, .new]) { [weak self] observed, _ in
                guard let self else { return }
                if self.shouldLogBufferState {
                    AppLog.debug(.player, "buffer: likelyToKeepUp=\(observed.isPlaybackLikelyToKeepUp)")
                }
                if observed.isPlaybackLikelyToKeepUp, !self.isRemoteStream {
                    self.applyPendingResumeIfNeeded(reason: "likelyToKeepUp")
                    self.performPendingSeekIfPossible(reason: "keepUp")
                }
            },
            item.observe(\.seekableTimeRanges, options: [.initial, .new]) { [weak self] _, _ in
                guard let self else { return }
                if !self.isRemoteStream {
                    self.applyPendingResumeIfNeeded(reason: "seekableRanges")
                }
                self.performPendingSeekIfPossible(reason: "seekableRanges")
            }
        ]

        playbackStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            AppLog.debug(.player, "buffer: stalled remote=\(self.isRemoteStream) seeking=\(self.isSeeking)")
            guard self.isRemoteStream else { return }
            if self.pendingSeekRequest != nil {
                self.performPendingSeekIfPossible(reason: "stall")
            } else {
                player.play()
            }
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            if self.isRemoteStream, seconds >= 1 {
                self.applyPendingResumeIfNeeded(reason: "playbackAdvanced")
            }
            self.updateActiveSkip(at: seconds)
            if self.isSeeking { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration > 0 {
                let fraction = seconds / duration
                if !self.didMarkWatched, fraction >= 0.85 {
                    self.didMarkWatched = true
                    Task { await self.markEpisodeWatched(self.mediaId, self.episode.number) }
                    PlaybackHistoryStore.shared.clearMedia(mediaId: self.mediaId)
                }
                Task { @MainActor in
                    self.services.playbackEngine.updateProgress(
                        for: String(self.mediaId),
                        currentTime: seconds,
                        duration: duration
                    )
                    self.services.playbackEngine.updateProgress(
                        for: "episode:\(self.episode.id)",
                        currentTime: seconds,
                        duration: duration
                    )
                    if !self.didMarkWatched {
                        PlaybackHistoryStore.shared.save(position: seconds, for: self.episode.id)
                        PlaybackHistoryStore.shared.saveDuration(duration, for: self.episode.id)
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
        if let cached = services.downloadManager.cachedSkipSegments(malId: malId, episode: episode.number) {
            skipSegments = cached
            updateActiveSkip(at: currentPlaybackTime)
            AppLog.debug(.player, "aniskip: cache hit malId=\(malId) ep=\(episode.number) count=\(cached.count)")
        } else {
            skipSegments = []
            AppLog.debug(.player, "aniskip: cache miss malId=\(malId) ep=\(episode.number)")
        }
        Task { [weak self] in
            guard let self else { return }
            let segments = await self.services.aniSkipService.fetchSkipSegments(malId: malId, episode: self.episode.number)
            guard !segments.isEmpty else {
                AppLog.debug(.player, "aniskip: no segments malId=\(malId) ep=\(self.episode.number)")
                return
            }
            self.skipSegments = segments
            self.updateActiveSkip(at: self.currentPlaybackTime)
            AppLog.debug(.player, "aniskip: fetched malId=\(malId) ep=\(self.episode.number) count=\(segments.count)")
            self.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: self.episode.number)
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

    private func seekForwardByDefaultInterval() {
        let target = currentPlaybackTime + 85
        requestSeek(to: target, reason: "skip:+85", shouldResumePlayback: true)
    }

    private func requestSeek(to seconds: Double, reason: String, shouldResumePlayback: Bool? = nil) {
        let shouldResume = shouldResumePlayback ?? (player?.timeControlStatus != .paused || player?.rate ?? 0 > 0)
        pendingSeekRequest = PendingSeekRequest(seconds: seconds, reason: reason, shouldResumePlayback: shouldResume)
        AppLog.debug(.player, "seek: queued time=\(seconds) reason=\(reason)")
        performPendingSeekIfPossible(reason: "request")
    }

    private func applyPendingResumeIfNeeded(reason: String) {
        guard let seconds = pendingResumeTime else { return }
        guard let item = playerItem, item.status == .readyToPlay else { return }
        guard isSeekable(item: item, targetSeconds: seconds) else { return }
        pendingResumeTime = nil
        requestSeek(to: seconds, reason: "resume:\(reason)", shouldResumePlayback: true)
    }

    private func performPendingSeekIfPossible(reason: String) {
        guard !isSeeking else { return }
        guard let request = pendingSeekRequest else { return }
        guard let player, let item = player.currentItem else { return }
        guard item.status == .readyToPlay else { return }
        guard isSeekable(item: item, targetSeconds: request.seconds) else {
            AppLog.debug(.player, "seek: waiting seekable time=\(request.seconds) reason=\(request.reason) trigger=\(reason)")
            return
        }

        let clampedSeconds = clampedSeekTime(request.seconds, item: item)
        pendingSeekRequest = nil
        isSeeking = true
        let tolerance = CMTime(seconds: isRemoteStream ? 3.0 : 0.25, preferredTimescale: 600)
        let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let shouldResume = request.shouldResumePlayback

        item.cancelPendingSeeks()
        AppLog.debug(.player, "seek: perform time=\(clampedSeconds) reason=\(request.reason) trigger=\(reason)")
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] finished in
            guard let self else { return }
            AppLog.debug(.player, "seek: finished=\(finished) time=\(clampedSeconds) reason=\(request.reason)")
            self.isSeeking = false

            if let next = self.pendingSeekRequest {
                AppLog.debug(.player, "seek: chaining next time=\(next.seconds) reason=\(next.reason)")
                self.performPendingSeekIfPossible(reason: "chain")
                return
            }

            if shouldResume {
                self.resumePlaybackAfterSeek(player: player)
            }
        }

        if shouldResume, isRemoteStream {
            DispatchQueue.main.async { [weak self, weak player] in
                guard let self, let player else { return }
                self.resumePlaybackAfterSeek(player: player)
            }
        }
    }

    private func isSeekable(item: AVPlayerItem, targetSeconds: Double) -> Bool {
        guard item.status == .readyToPlay else { return false }
        if !isRemoteStream {
            return true
        }

        let ranges = item.seekableTimeRanges.compactMap { value -> ClosedRange<Double>? in
            let range = value.timeRangeValue
            let start = range.start.seconds
            let duration = range.duration.seconds
            guard start.isFinite, duration.isFinite else { return nil }
            let end = start + duration
            guard end > start else { return nil }
            return start...end
        }

        if ranges.isEmpty {
            return false
        }

        return ranges.contains { range in
            targetSeconds >= max(0, range.lowerBound - 2) && targetSeconds <= range.upperBound + 2
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

    private struct PendingSeekRequest: Equatable {
        let seconds: Double
        let reason: String
        let shouldResumePlayback: Bool
    }
}
#endif

struct PlayerView: View {
#if os(iOS)
    @ObservedObject var controller: PlayerSessionController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
#endif

    var body: some View {
        Group {
#if os(iOS)
            AVPlayerScreen(controller: controller)
#else
            Text("Playback is only supported on iOS.")
#endif
        }
    }
}

#if os(iOS)
private struct AVPlayerScreen: View {
    @ObservedObject var controller: PlayerSessionController
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            if let player = controller.player {
                AVPlayerViewControllerRepresentable(
                    player: player,
                    skipButtonTitle: controller.overlaySkipButtonTitle,
                    onSkipTapped: controller.handleOverlaySkipAction,
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
            controller.startPlaybackIfNeeded()
        }
        .alert("Playback Error", isPresented: Binding(
            get: { controller.errorMessage != nil },
            set: { _ in controller.clearError() }
        )) {
            Button("OK", role: .cancel) {
                appState.closeActivePlayerSession()
                dismiss()
            }
        } message: {
            Text(controller.errorMessage ?? "Unknown error")
        }
    }

    private func handlePictureInPictureStarted() {
        controller.isPictureInPictureActive = true
        controller.shouldRestoreAfterPictureInPicture = true
        AppLog.debug(.player, "pip: active=true")
        appState.dismissPlayerForPictureInPicture()
    }

    private func handlePictureInPictureStopped() {
        AppLog.debug(.player, "pip: active=false")
        appState.handlePictureInPictureStopped()
    }

    private func restoreUserInterfaceFromPictureInPicture(_ completion: @escaping (Bool) -> Void) {
        AppLog.debug(.player, "pip: restore requested")
        appState.handlePictureInPictureStopped()
        DispatchQueue.main.async {
            completion(true)
        }
    }

    private func handlePictureInPictureFailed(_ error: Error) {
        AppLog.error(.player, "pip: failed start error=\(error.localizedDescription)")
        appState.handlePictureInPictureFailedToStart()
    }
}

private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipButtonTitle: String
    let onSkipTapped: () -> Void
    let onPictureInPictureStarted: () -> Void
    let onPictureInPictureStopped: () -> Void
    let onRestoreFromPictureInPicture: (@escaping (Bool) -> Void) -> Void
    let onPictureInPictureFailed: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSkipTapped: onSkipTapped,
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
        context.coordinator.updateSkipButtonTitle(skipButtonTitle)
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
        context.coordinator.onSkipTapped = onSkipTapped
        context.coordinator.onPictureInPictureStarted = onPictureInPictureStarted
        context.coordinator.onPictureInPictureStopped = onPictureInPictureStopped
        context.coordinator.onRestoreFromPictureInPicture = onRestoreFromPictureInPicture
        context.coordinator.onPictureInPictureFailed = onPictureInPictureFailed
        uiViewController.delegate = context.coordinator
        context.coordinator.installSkipButtonIfNeeded(in: uiViewController)
        context.coordinator.updateSkipButtonTitle(skipButtonTitle)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        var onSkipTapped: () -> Void
        var onPictureInPictureStarted: () -> Void
        var onPictureInPictureStopped: () -> Void
        var onRestoreFromPictureInPicture: (@escaping (Bool) -> Void) -> Void
        var onPictureInPictureFailed: (Error) -> Void
        private weak var skipButton: UIButton?
        private weak var blurView: SkipOverlayView?
        private weak var progressSlider: UISlider?
        private var syncTask: Task<Void, Never>?
        private var placementConstraints: [NSLayoutConstraint] = []

        init(
            onSkipTapped: @escaping () -> Void,
            onPictureInPictureStarted: @escaping () -> Void,
            onPictureInPictureStopped: @escaping () -> Void,
            onRestoreFromPictureInPicture: @escaping (@escaping (Bool) -> Void) -> Void,
            onPictureInPictureFailed: @escaping (Error) -> Void
        ) {
            self.onSkipTapped = onSkipTapped
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

        func updateSkipButtonTitle(_ title: String) {
            skipButton?.setTitle(title, for: .normal)
            blurView?.isHidden = title.isEmpty
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
