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
    @State private var seekToken: UUID?
    @State private var isSeeking: Bool = false
    @State private var shouldLogBufferState: Bool = true

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
            item.preferredForwardBufferDuration = 8
            if #available(iOS 10.0, *) {
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
            }
        }
        self.playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = true
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
        seekToken = nil
        isSeeking = false
        shouldLogBufferState = true
        activeSkip = nil
        didMarkWatched = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerItem = nil
    }

    private func addObservers(to player: AVPlayer, item: AVPlayerItem) {
        let startTime = startAt ?? (PlaybackHistoryStore.shared.position(for: episode.id) ?? 0)

        statusObserver = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            switch observed.status {
            case .readyToPlay:
                if startTime > 0 {
                    requestSeek(to: startTime, reason: "resume")
                }
            case .failed:
                errorMessage = observed.error?.localizedDescription ?? "Playback failed."
            default:
                break
            }
        }

        item.observe(\.isPlaybackBufferEmpty, options: [.new]) { observed, _ in
            if observed.isPlaybackBufferEmpty {
                AppLog.debug(.player, "buffer: empty")
            }
        }
        item.observe(\.isPlaybackBufferFull, options: [.new]) { observed, _ in
            if observed.isPlaybackBufferFull {
                AppLog.debug(.player, "buffer: full")
            }
        }
        item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { observed, _ in
            if shouldLogBufferState {
                AppLog.debug(.player, "buffer: likelyToKeepUp=\(observed.isPlaybackLikelyToKeepUp)")
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
        requestSeek(to: segment.end, reason: "skip:\(segment.type)")
    }

    private func seekForwardByDefaultInterval() {
        let target = currentPlaybackTime + 85
        requestSeek(to: target, reason: "skip:+85")
    }

    private func requestSeek(to seconds: Double, reason: String) {
        guard let player else { return }
        let token = UUID()
        seekToken = token
        isSeeking = true
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.35, preferredTimescale: 600)
        AppLog.debug(.player, "seek: request time=\(seconds) reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard seekToken == token else { return }
            player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if seekToken == token {
                    isSeeking = false
                }
                AppLog.debug(.player, "seek: finished=\(finished) time=\(seconds)")
            }
        }
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

        init(onSkipTapped: @escaping () -> Void) {
            self.onSkipTapped = onSkipTapped
        }

        func installSkipButtonIfNeeded(in controller: AVPlayerViewController) {
            guard skipButton == nil || blurView == nil else { return }
            guard let overlay = controller.contentOverlayView else { return }

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
            overlay.addSubview(blur)

            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: blur.contentView.leadingAnchor),
                button.trailingAnchor.constraint(equalTo: blur.contentView.trailingAnchor),
                button.topAnchor.constraint(equalTo: blur.contentView.topAnchor),
                button.bottomAnchor.constraint(equalTo: blur.contentView.bottomAnchor),

                blur.trailingAnchor.constraint(equalTo: overlay.trailingAnchor, constant: -16),
                blur.bottomAnchor.constraint(equalTo: overlay.safeAreaLayoutGuide.bottomAnchor, constant: -22)
            ])

            skipButton = button
            blurView = blur
        }

        func updateSkipButtonTitle(_ title: String) {
            skipButton?.setTitle(title, for: .normal)
            blurView?.isHidden = title.isEmpty
        }

        @objc
        private func handleSkipTap() {
            onSkipTapped()
        }
    }
}
#endif
