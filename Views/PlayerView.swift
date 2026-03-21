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
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isPlaying: Bool = false
    @State private var isScrubbing: Bool = false
    @State private var scrubPosition: Double = 0
    @State private var areControlsVisible: Bool = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var playerStateObserver: NSKeyValueObservation?
    @State private var bufferObservers: [NSKeyValueObservation] = []

    var body: some View {
        ZStack {
            if let player {
                AVPlayerLayerView(player: player)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {
                        handlePlayerSurfaceTap()
                    }
            } else {
                Color.black.ignoresSafeArea()
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
            }

            LinearGradient(
                colors: [
                    Color.black.opacity(areControlsVisible ? 0.32 : 0),
                    Color.clear,
                    Color.black.opacity(areControlsVisible ? 0.4 : 0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if player != nil, areControlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .animation(.easeInOut(duration: 0.2), value: areControlsVisible)
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

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topControls
            Spacer()
            centerControls
            Spacer()
            bottomControls
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 18)
        .ignoresSafeArea()
    }

    private var topControls: some View {
        HStack(spacing: 12) {
            liquidGlassIconButton(systemName: "chevron.backward", size: 16) {
                dismiss()
            }
            Spacer()
            VStack(alignment: .center, spacing: 2) {
                Text(mediaTitle ?? "Now Playing")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("Episode \(episode.number)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.78))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(liquidGlassBackground(cornerRadius: 18))
            Spacer()
            Color.clear
                .frame(width: 40, height: 40)
        }
    }

    private var centerControls: some View {
        HStack(spacing: 18) {
            liquidGlassIconButton(systemName: "gobackward.15", size: 20, diameter: 52) {
                seekRelative(by: -15)
            }
            liquidGlassIconButton(systemName: isPlaying ? "pause.fill" : "play.fill", size: 24, diameter: 66) {
                togglePlayback()
            }
            liquidGlassIconButton(systemName: "goforward.15", size: 20, diameter: 52) {
                seekRelative(by: 15)
            }
        }
    }

    private var bottomControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(formatTime(displayedCurrentTime))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))

                Slider(
                    value: Binding(
                        get: { sliderValue },
                        set: { newValue in
                            scrubPosition = newValue
                        }
                    ),
                    in: 0...sliderUpperBound,
                    onEditingChanged: handleScrubbingChanged
                )
                .tint(.white)

                Text(formatTime(duration))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.82))
            }

            HStack(alignment: .center, spacing: 12) {
                Text(playbackStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
                    .lineLimit(1)
                Spacer()
                liquidGlassTextButton(title: overlaySkipButtonTitle) {
                    handleOverlaySkipAction()
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(liquidGlassBackground(cornerRadius: 26))
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
        self.isPlaying = true
        self.currentTime = 0
        self.duration = 0
        self.scrubPosition = 0
        self.areControlsVisible = true

        addObservers(to: avPlayer, item: item)
        avPlayer.play()
        scheduleControlsAutoHide()
    }

    private func stopPlayback() {
        guard let player else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        statusObserver?.invalidate()
        statusObserver = nil
        playerStateObserver?.invalidate()
        playerStateObserver = nil
        bufferObservers.forEach { $0.invalidate() }
        bufferObservers.removeAll()
        controlsHideTask?.cancel()
        controlsHideTask = nil
        seekToken = nil
        isSeeking = false
        shouldLogBufferState = true
        activeSkip = nil
        didMarkWatched = false
        isScrubbing = false
        isPlaying = false
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
        bufferObservers = [bufferEmptyObserver, bufferFullObserver, keepUpObserver]

        playerStateObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { observed, _ in
            Task { @MainActor in
                isPlaying = observed.timeControlStatus == .playing
                if isPlaying {
                    scheduleControlsAutoHide()
                } else {
                    controlsHideTask?.cancel()
                    areControlsVisible = true
                }
            }
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            currentTime = seconds
            if !isScrubbing {
                scrubPosition = seconds
            }
            updateActiveSkip(at: seconds)
            if isSeeking { return }
            let itemDuration = player.currentItem?.duration.seconds ?? 0
            duration = itemDuration.isFinite && itemDuration > 0 ? itemDuration : 0
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
        let resolvedTarget = max(0, min(seconds, duration > 0 ? duration : seconds))
        let token = UUID()
        seekToken = token
        isSeeking = true
        currentTime = resolvedTarget
        if !isScrubbing {
            scrubPosition = resolvedTarget
        }
        let target = CMTime(seconds: resolvedTarget, preferredTimescale: 600)
        let tolerance = CMTime(seconds: 0.35, preferredTimescale: 600)
        AppLog.debug(.player, "seek: request time=\(resolvedTarget) reason=\(reason)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            guard seekToken == token else { return }
            player.seek(to: target, toleranceBefore: tolerance, toleranceAfter: tolerance) { finished in
                if seekToken == token {
                    isSeeking = false
                }
                AppLog.debug(.player, "seek: finished=\(finished) time=\(resolvedTarget)")
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
        noteControlsInteraction()
        if let activeSkip {
            seekToSkipEnd(activeSkip)
        } else {
            seekForwardByDefaultInterval()
        }
    }

    private func togglePlayback() {
        guard let player else { return }
        noteControlsInteraction()
        if isPlaying {
            player.pause()
            isPlaying = false
            areControlsVisible = true
            controlsHideTask?.cancel()
        } else {
            player.play()
            isPlaying = true
            scheduleControlsAutoHide()
        }
    }

    private func seekRelative(by delta: Double) {
        noteControlsInteraction()
        requestSeek(to: currentPlaybackTime + delta, reason: "relative:\(delta)")
    }

    private func handlePlayerSurfaceTap() {
        if areControlsVisible {
            areControlsVisible = false
            controlsHideTask?.cancel()
        } else {
            areControlsVisible = true
            scheduleControlsAutoHide()
        }
    }

    private func noteControlsInteraction() {
        areControlsVisible = true
        scheduleControlsAutoHide()
    }

    private func scheduleControlsAutoHide() {
        controlsHideTask?.cancel()
        guard isPlaying, !isScrubbing else { return }
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, isPlaying, !isScrubbing else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                areControlsVisible = false
            }
        }
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        isScrubbing = editing
        if editing {
            noteControlsInteraction()
        } else {
            requestSeek(to: scrubPosition, reason: "scrub")
            scheduleControlsAutoHide()
        }
    }

    private func formatTime(_ seconds: Double) -> String {
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

    private func liquidGlassBackground(cornerRadius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.24), radius: 18, x: 0, y: 10)
    }

    private func liquidGlassTextButton(title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(liquidGlassBackground(cornerRadius: 18))
        }
        .buttonStyle(.plain)
    }

    private func liquidGlassIconButton(
        systemName: String,
        size: CGFloat,
        diameter: CGFloat = 40,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: diameter, height: diameter)
                .background(liquidGlassBackground(cornerRadius: diameter / 2))
        }
        .buttonStyle(.plain)
    }

    private var sliderUpperBound: Double {
        max(duration, 1)
    }

    private var sliderValue: Double {
        min(max(isScrubbing ? scrubPosition : currentTime, 0), sliderUpperBound)
    }

    private var displayedCurrentTime: Double {
        isScrubbing ? scrubPosition : currentTime
    }

    private var playbackStatusText: String {
        if let activeSkip {
            return skipButtonTitle(for: activeSkip)
        }
        return isPlaying ? "Playing" : "Paused"
    }
}

private struct AVPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerContainerUIView {
        let view = PlayerContainerUIView()
        view.player = player
        return view
    }

    func updateUIView(_ uiView: PlayerContainerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.player = player
        }
    }
}

private final class PlayerContainerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    var player: AVPlayer? {
        get { playerLayer.player }
        set {
            playerLayer.player = newValue
            playerLayer.videoGravity = .resizeAspect
            backgroundColor = .black
        }
    }
}
#endif
