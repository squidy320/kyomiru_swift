import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
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
    private static let controlAutoHideDelay: TimeInterval = 4

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
    @State private var playerObservers: [NSKeyValueObservation] = []
    @State private var itemObservers: [NSKeyValueObservation] = []
    @State private var errorMessage: String?
    @State private var skipSegments: [AniSkipSegment] = []
    @State private var activeSkip: AniSkipSegment?
    @State private var didMarkWatched: Bool = false
    @State private var seekToken: UUID?
    @State private var isSeeking: Bool = false
    @State private var shouldLogBufferState: Bool = true
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    @State private var controlsVisible: Bool = true
    @State private var hideControlsWorkItem: DispatchWorkItem?
    @State private var isScrubbing: Bool = false
    @State private var scrubPosition: Double = 0

    var body: some View {
        ZStack {
            if let player {
                PlayerSurfaceRepresentable(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        toggleControls()
                    }
            } else {
                Color.black.ignoresSafeArea()
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
            }

            if controlsVisible || !isPlaying {
                controlsOverlay
                    .transition(.opacity)
            }

            if let activeSkip {
                Button {
                    registerInteraction()
                    seekToSkipEnd(activeSkip)
                } label: {
                    Text(skipButtonTitle(for: activeSkip))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.black.opacity(0.7))
                        )
                }
                .padding(.trailing, 16)
                .padding(.bottom, 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .buttonStyle(.plain)
            }
        }
        .onAppear {
            loadSkipSegments()
            startPlayback()
        }
        .onDisappear(perform: stopPlayback)
        .statusBarHidden(true)
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

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .padding(.top, 18)
        .padding(.horizontal, 18)
        .padding(.bottom, 18)
        .background(
            LinearGradient(
                colors: [
                    Color.black.opacity(0.55),
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.6)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .animation(.easeInOut(duration: 0.18), value: controlsVisible)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            controlButton(systemName: "chevron.backward", size: 16, diameter: 42) {
                dismiss()
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaTitle ?? "Player")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text("Episode \(episode.number)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.72))
            }

            Spacer()
        }
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            controlButton(systemName: "gobackward.10", size: 20, diameter: 52) {
                skipBy(-10)
            }

            controlButton(systemName: isPlaying ? "pause.fill" : "play.fill", size: 24, diameter: 64) {
                togglePlayback()
            }

            controlButton(systemName: "goforward.10", size: 20, diameter: 52) {
                skipBy(10)
            }
        }
    }

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubPosition : currentTime },
                    set: { newValue in
                        scrubPosition = min(max(newValue, 0), max(duration, 0))
                    }
                ),
                in: 0...max(duration, 0.1),
                onEditingChanged: handleScrubbingChanged
            )
            .tint(.white)

            HStack {
                Text(formatTime(isScrubbing ? scrubPosition : currentTime))
                Spacer()
                Text(formatTime(duration))
            }
            .font(.system(size: 12, weight: .medium, design: .monospaced))
            .foregroundColor(.white.opacity(0.86))
        }
        .padding(.horizontal, 4)
    }

    private func controlButton(systemName: String, size: CGFloat, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button {
            registerInteraction()
            action()
        } label: {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: diameter, height: diameter)
                .background(
                    Circle()
                        .fill(Color.black.opacity(0.5))
                )
                .overlay(
                    Circle()
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
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
            item.preferredForwardBufferDuration = 4
            if #available(iOS 10.0, *) {
                item.canUseNetworkResourcesForLiveStreamingWhilePaused = false
            }
        }
        self.playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
        avPlayer.automaticallyWaitsToMinimizeStalling = false
        self.player = avPlayer

        addObservers(to: avPlayer, item: item)
        avPlayer.play()
        isPlaying = true
        controlsVisible = true
        scheduleControlsAutoHide()
    }

    private func stopPlayback() {
        hideControlsWorkItem?.cancel()
        hideControlsWorkItem = nil
        guard let player else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        playerObservers.forEach { $0.invalidate() }
        playerObservers.removeAll()
        itemObservers.forEach { $0.invalidate() }
        itemObservers.removeAll()
        seekToken = nil
        isSeeking = false
        shouldLogBufferState = true
        activeSkip = nil
        didMarkWatched = false
        currentTime = 0
        duration = 0
        isPlaying = false
        isScrubbing = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerItem = nil
    }

    private func addObservers(to player: AVPlayer, item: AVPlayerItem) {
        let startTime = startAt ?? (PlaybackHistoryStore.shared.position(for: episode.id) ?? 0)

        let statusObserver = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            switch observed.status {
            case .readyToPlay:
                duration = observed.duration.seconds.isFinite ? observed.duration.seconds : 0
                if startTime > 0 {
                    requestSeek(to: startTime, reason: "resume")
                }
            case .failed:
                errorMessage = observed.error?.localizedDescription ?? "Playback failed."
            default:
                break
            }
        }

        let rateObserver = player.observe(\.rate, options: [.initial, .new]) { observed, _ in
            let playing = observed.rate > 0
            isPlaying = playing
            if playing {
                scheduleControlsAutoHide()
            } else {
                controlsVisible = true
                hideControlsWorkItem?.cancel()
                hideControlsWorkItem = nil
            }
        }

        let bufferEmptyObserver = item.observe(\.isPlaybackBufferEmpty, options: [.new]) { observed, _ in
            if observed.isPlaybackBufferEmpty {
                AppLog.debug(.player, "buffer: empty")
            }
        }
        let bufferFullObserver = item.observe(\.isPlaybackBufferFull, options: [.new]) { observed, _ in
            if observed.isPlaybackBufferFull {
                AppLog.debug(.player, "buffer: full")
            }
        }
        let keepUpObserver = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { observed, _ in
            if shouldLogBufferState {
                AppLog.debug(.player, "buffer: likelyToKeepUp=\(observed.isPlaybackLikelyToKeepUp)")
            }
        }

        playerObservers = [rateObserver]
        itemObservers = [statusObserver, bufferEmptyObserver, bufferFullObserver, keepUpObserver]

        let interval = CMTime(seconds: 1.0, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            currentTime = seconds
            updateActiveSkip(at: seconds)
            if isSeeking { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration.isFinite && duration > 0 {
                self.duration = duration
                let fraction = seconds / duration
                if !didMarkWatched, fraction >= 0.85 {
                    didMarkWatched = true
                    Task { await appState.markEpisodeWatched(mediaId: mediaId, episodeNumber: episode.number) }
                    PlaybackHistoryStore.shared.clearMedia(mediaId: mediaId)
                }
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

    private func loadSkipSegments() {
        guard let malId else {
            skipSegments = []
            activeSkip = nil
            AppLog.debug(.player, "aniskip: no malId for mediaId=\(mediaId) ep=\(episode.number)")
            return
        }
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: episode.number) {
            skipSegments = cached
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
                currentTime = seconds
                AppLog.debug(.player, "seek: finished=\(finished) time=\(seconds)")
            }
        }
    }

    private func registerInteraction() {
        controlsVisible = true
        scheduleControlsAutoHide()
    }

    private func toggleControls() {
        if controlsVisible {
            controlsVisible = false
            hideControlsWorkItem?.cancel()
            hideControlsWorkItem = nil
        } else {
            registerInteraction()
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
    }

    private func skipBy(_ delta: Double) {
        let target = min(max(currentTime + delta, 0), max(duration, 0))
        requestSeek(to: target, reason: "skipBy:\(delta)")
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        isScrubbing = editing
        registerInteraction()
        if editing {
            scrubPosition = currentTime
        } else {
            requestSeek(to: scrubPosition, reason: "scrub")
        }
    }

    private func scheduleControlsAutoHide() {
        hideControlsWorkItem?.cancel()
        guard isPlaying else { return }
        let workItem = DispatchWorkItem {
            guard isPlaying, !isScrubbing else { return }
            controlsVisible = false
        }
        hideControlsWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.controlAutoHideDelay, execute: workItem)
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let totalSeconds = Int(seconds.rounded(.down))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let secs = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
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
}

private struct PlayerSurfaceRepresentable: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerSurfaceView {
        let view = PlayerSurfaceView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceView, context: Context) {
        if uiView.player !== player {
            uiView.player = player
        }
    }
}

private final class PlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    var player: AVPlayer? {
        get { playerLayer.player }
        set { playerLayer.player = newValue }
    }

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
        playerLayer.videoGravity = .resizeAspect
    }
}
#endif
