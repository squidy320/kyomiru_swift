import SwiftUI
#if os(iOS)
import AVFoundation
import AVKit
#endif

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    @EnvironmentObject private var appState: AppState

    init(
        episode: SoraEpisode,
        sources: [SoraSource],
        mediaId: Int,
        malId: Int?,
        mediaTitle: String?,
        startAt: Double? = nil
    ) {
        self.episode = episode
        self.sources = sources
        self.mediaId = mediaId
        self.malId = malId
        self.mediaTitle = mediaTitle
        self.startAt = startAt
    }

    var body: some View {
        Group {
#if os(iOS)
            AVPlayerScreen(
                episode: episode,
                sources: sources,
                mediaId: mediaId,
                malId: malId,
                mediaTitle: mediaTitle,
                startAt: startAt
            )
#else
            Text("Playback is only supported on iOS.")
#endif
        }
    }
}

#if os(iOS)
private struct AVPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var timeObserver: Any?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var errorMessage: String?
    @State private var skipSegments: [AniSkipSegment] = []
    @State private var activeSkip: AniSkipSegment?
    @State private var didMarkWatched: Bool = false
    @State private var isSeeking: Bool = false
    @State private var shouldLogBufferState: Bool = true
    @State private var itemObservers: [NSKeyValueObservation] = []
    @State private var playbackStallObserver: NSObjectProtocol?
    @State private var pendingSeekRequest: PendingSeekRequest?
    @State private var pendingResumeTime: Double?
    @State private var isRemoteStream: Bool = false

    var body: some View {
        ZStack {
            if let player {
                AVPlayerViewControllerRepresentable(
                    player: player,
                    skipButtonTitle: overlaySkipButtonTitle,
                    onSkipTapped: handleOverlaySkipAction
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
        .onDisappear(perform: stopPlayback)
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
        let isRemoteStream = !resolved.isFileURL
        self.isRemoteStream = isRemoteStream
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
            item.preferredForwardBufferDuration = 2
            if #available(iOS 10.0, *) {
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            }
        }
        self.playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = !isRemoteStream
        self.player = avPlayer

        addObservers(to: avPlayer, item: item)
        avPlayer.play()
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
        pendingSeekRequest = nil
        pendingResumeTime = nil
        isSeeking = false
        shouldLogBufferState = true
        isRemoteStream = false
        activeSkip = nil
        didMarkWatched = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerItem = nil
    }

    private func addObservers(to player: AVPlayer, item: AVPlayerItem) {
        let startTime = startAt ?? (PlaybackHistoryStore.shared.position(for: episode.id) ?? 0)
        pendingResumeTime = startTime > 0 ? startTime : nil

        statusObserver = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            switch observed.status {
            case .readyToPlay:
                applyPendingResumeIfNeeded(reason: "readyToPlay")
                performPendingSeekIfPossible(reason: "statusReady")
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
                if observed.isPlaybackLikelyToKeepUp {
                    applyPendingResumeIfNeeded(reason: "likelyToKeepUp")
                    performPendingSeekIfPossible(reason: "keepUp")
                }
            },
            item.observe(\.seekableTimeRanges, options: [.initial, .new]) { _, _ in
                applyPendingResumeIfNeeded(reason: "seekableRanges")
                performPendingSeekIfPossible(reason: "seekableRanges")
            }
        ]

        playbackStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: item,
            queue: .main
        ) { _ in
            AppLog.debug(.player, "buffer: stalled remote=\(isRemoteStream) seeking=\(isSeeking)")
            guard isRemoteStream else { return }
            if let pendingSeekRequest {
                performPendingSeekIfPossible(reason: "stall")
            } else {
                player.playImmediately(atRate: 1.0)
            }
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
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
                        PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                        PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
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
        let tolerance = CMTime(seconds: isRemoteStream ? 1.0 : 0.25, preferredTimescale: 600)
        let target = CMTime(seconds: clampedSeconds, preferredTimescale: 600)
        let shouldResume = request.shouldResumePlayback

        item.cancelPendingSeeks()
        player.pause()
        AppLog.debug(.player, "seek: perform time=\(clampedSeconds) reason=\(request.reason) trigger=\(reason)")
        player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
            AppLog.debug(.player, "seek: finished=\(finished) time=\(clampedSeconds) reason=\(request.reason)")
            isSeeking = false

            if let next = pendingSeekRequest {
                AppLog.debug(.player, "seek: chaining next time=\(next.seconds) reason=\(next.reason)")
                performPendingSeekIfPossible(reason: "chain")
                return
            }

            if shouldResume {
                if isRemoteStream {
                    player.playImmediately(atRate: 1.0)
                } else {
                    player.play()
                }
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

    private var overlaySkipButtonTitle: String {
        if let activeSkip {
            return skipButtonTitle(for: activeSkip)
        }
        return "+85s"
    }

    private var currentPlaybackTime: Double {
        let seconds = player?.currentTime().seconds ?? 0
        return seconds.isFinite ? seconds : 0
    }

    private func handleOverlaySkipAction() {
        if let activeSkip {
            seekToSkipEnd(activeSkip)
        } else {
            seekForwardByDefaultInterval()
        }
    }

    private struct PendingSeekRequest: Equatable {
        let seconds: Double
        let reason: String
        let shouldResumePlayback: Bool
    }
}

private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer
    let skipButtonTitle: String
    let onSkipTapped: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSkipTapped: onSkipTapped)
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
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
        context.coordinator.installSkipButtonIfNeeded(in: uiViewController)
        context.coordinator.updateSkipButtonTitle(skipButtonTitle)
    }

    final class Coordinator: NSObject {
        var onSkipTapped: () -> Void
        private weak var skipButton: UIButton?
        private weak var blurView: UIVisualEffectView?
        private weak var progressSlider: UISlider?
        private weak var buttonHostView: UIView?
        private var syncTask: Task<Void, Never>?
        private var placementConstraints: [NSLayoutConstraint] = []

        init(onSkipTapped: @escaping () -> Void) {
            self.onSkipTapped = onSkipTapped
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

            let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
            blur.translatesAutoresizingMaskIntoConstraints = false
            blur.clipsToBounds = true
            blur.layer.cornerRadius = 18
            blur.layer.cornerCurve = .continuous
            blur.layer.borderWidth = 1
            blur.layer.borderColor = UIColor.white.withAlphaComponent(0.14).cgColor

            let button = UIButton(type: .system)
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setTitleColor(.white, for: .normal)
            button.titleLabel?.font = .systemFont(ofSize: 13, weight: .semibold)
            button.contentEdgeInsets = UIEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
            button.addTarget(self, action: #selector(handleSkipTap), for: .touchUpInside)

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
                    buttonHostView = host
                }
            } else if blurView.superview == nil, let overlay = controller.contentOverlayView {
                overlay.addSubview(blurView)
                NSLayoutConstraint.deactivate(placementConstraints)
                placementConstraints = [
                    blurView.leadingAnchor.constraint(equalTo: overlay.leadingAnchor, constant: 16),
                    blurView.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -56)
                ]
                NSLayoutConstraint.activate(placementConstraints)
                buttonHostView = overlay
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
    }
}
#endif
