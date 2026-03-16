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
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
#if os(iOS)
            if appState.settings.playerEngine == .avplayer {
                AVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    mediaTitle: mediaTitle
                )
            } else {
                MPVPlayerScreen(
                    episode: episode,
                    sources: sources,
                    mediaId: mediaId,
                    malId: malId,
                    mediaTitle: mediaTitle
                )
            }
#else
            MPVPlayerScreen(
                episode: episode,
                sources: sources,
                mediaId: mediaId,
                malId: malId,
                mediaTitle: mediaTitle
            )
#endif
        }
    }
}

private struct MPVPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player = MPVPlayerModel()
    @State private var controlsVisible = true
    @State private var isScrubbing = false
    @State private var scrubValue: Double = 0
    @State private var autoHideTask: Task<Void, Never>?
    @State private var autoHideToken: Int = 0
    @State private var isBackgrounding = false
    @State private var skipSegments: [AniSkipSegment] = []
    @State private var activeSkip: AniSkipSegment?
    @State private var skipTask: Task<Void, Never>?
    private let progressTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            MPVVideoView(player: player)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { toggleControls() }

            if !player.isReady {
                loadingOverlay
            }

            if controlsVisible {
                controlsOverlay
                    .transition(.opacity)
            }

            if let activeSkip {
                skipButton(for: activeSkip)
            }
        }
        .onAppear(perform: startPlayback)
        .onDisappear(perform: stopPlayback)
        .onReceive(progressTimer) { _ in
            syncProgress()
            updateSkipState()
        }
        .onChange(of: player.isPlaying) { _, _ in
            scheduleAutoHide()
        }
        .onChange(of: appState.settings.showPlayerDebugOverlay) { _, value in
            player.setDebugOverlayEnabled(value)
        }
        .onChange(of: scenePhase) { _, phase in
#if os(iOS) && !targetEnvironment(macCatalyst)
            if phase == .inactive {
                isBackgrounding = true
                AppLog.debug(.player, "player scenePhase inactive isPlaying=\(player.isPlaying)")
                if player.isPlaying {
                    _ = player.startPictureInPictureIfPossible()
                }
            } else if phase == .active {
                isBackgrounding = false
                AppLog.debug(.player, "player scenePhase active pipActive=\(player.isPictureInPictureActive)")
                if player.isPictureInPictureActive {
                    player.stopPictureInPicture()
                }
            }
#endif
        }
#if os(iOS) && !targetEnvironment(macCatalyst)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            guard player.isPlaying else { return }
            AppLog.debug(.player, "player willResignActive -> request pip")
            _ = player.startPictureInPictureIfPossible()
        }
#endif
        .alert("Playback Error", isPresented: Binding(
            get: { player.errorMessage != nil },
            set: { _ in player.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(player.errorMessage ?? "Unknown error")
        }
        .statusBar(hidden: true)
    }

    private var loadingOverlay: some View {
        Color.black.opacity(0.45).ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    ProgressView()
                        .tint(.white)
                    Text("Loading player...")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                )
            )
    }

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            centerControls
            Spacer()
            bottomBar
        }
        .foregroundColor(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [Color.black.opacity(0.75), Color.black.opacity(0)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 140)
                Spacer()
                LinearGradient(
                    colors: [Color.black.opacity(0), Color.black.opacity(0.75)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 180)
            }
            .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Episode \(episode.number)")
                    .font(.system(size: 15, weight: .semibold))
                Text(episode.id)
                    .font(.system(size: 11))
                    .opacity(0.65)
            }

            Spacer()

#if os(iOS) && !targetEnvironment(macCatalyst)
            Button {
                _ = player.startPictureInPictureIfPossible()
                showControls()
            } label: {
                Image(systemName: "pip")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 36, height: 36)
                    .background(Color.white.opacity(0.12))
                    .clipShape(Circle())
            }
#endif

            Menu {
                ForEach(speedOptions, id: \.self) { value in
                    Button("\(String(format: "%.2gx", value))") {
                        player.setRate(value)
                        showControls()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "speedometer")
                    Text("\(String(format: "%.2gx", player.rate))")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.12))
                .clipShape(Capsule())
            }
        }
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            Button {
                player.seekBy(-10)
                showControls()
            } label: {
                controlCircle(icon: "gobackward.10")
            }

            Button {
                player.togglePlay()
                showControls()
            } label: {
                controlCircle(icon: player.isPlaying ? "pause.fill" : "play.fill", size: 20)
            }

            Button {
                player.seekBy(10)
                showControls()
            } label: {
                controlCircle(icon: "goforward.10")
            }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 12) {
            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : player.position },
                    set: { newValue in
                        scrubValue = newValue
                    }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if editing {
                        showControls()
                    } else {
                        player.seek(to: scrubValue)
                        showControls()
                    }
                }
            )

            HStack {
                Text(formatTime(isScrubbing ? scrubValue : player.position))
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.85)

                Spacer()

                Text(formatTime(player.duration))
                    .font(.system(size: 12, weight: .semibold))
                    .opacity(0.85)
            }
        }
    }

    private var speedOptions: [Double] {
        [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
    }

    private func controlCircle(icon: String, size: CGFloat = 18) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .semibold))
            .frame(width: 54, height: 54)
            .background(Color.white.opacity(0.12))
            .clipShape(Circle())
    }

    private func startPlayback() {
        player.setDebugOverlayEnabled(appState.settings.showPlayerDebugOverlay)
        AppLog.debug(.player, "player appear episode=\(episode.id)")
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
        if let source = sources.first {
            let saved = PlaybackHistoryStore.shared.position(for: episode.id)
            let resolved = PlaybackService.resolvePlayableURL(for: source.url, title: mediaTitle, episode: episode.number)
            let headers = resolved.isFileURL ? [:] : source.headers
            player.load(url: resolved, headers: headers, startTime: saved)
        }
        scheduleAutoHide()
        startSkipFetch()
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = true
#endif
    }

    private func stopPlayback() {
#if os(iOS) && !targetEnvironment(macCatalyst)
        if isBackgrounding, player.isPlaying {
            AppLog.debug(.player, "player disappear skipped due to backgrounding")
            return
        }
#endif
        if player.position.isFinite {
            PlaybackHistoryStore.shared.save(position: player.position, for: episode.id)
        }
        if player.duration.isFinite {
            PlaybackHistoryStore.shared.saveDuration(player.duration, for: episode.id)
        }
        skipTask?.cancel()
        skipTask = nil
        player.shutdown()
        AppLog.debug(.player, "player disappear episode=\(episode.id)")
#if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = false
#endif
    }

    private func syncProgress() {
        guard player.duration.isFinite, player.duration > 0 else { return }
        let current = player.position
        if current.isFinite {
            appState.services.playbackEngine.updateProgress(
                for: String(mediaId),
                currentTime: current,
                duration: player.duration
            )
            appState.services.playbackEngine.updateProgress(
                for: "episode:\(episode.id)",
                currentTime: current,
                duration: player.duration
            )
            PlaybackHistoryStore.shared.saveDuration(player.duration, for: episode.id)
        }
    }

    private func toggleControls() {
        if controlsVisible {
            hideControls()
        } else {
            showControls()
        }
    }

    private func showControls() {
        if !controlsVisible {
            withAnimation(.easeInOut(duration: 0.2)) {
                controlsVisible = true
            }
        }
        scheduleAutoHide()
    }

    private func hideControls() {
        autoHideTask?.cancel()
        autoHideToken += 1
        withAnimation(.easeInOut(duration: 0.2)) {
            controlsVisible = false
        }
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        autoHideToken += 1
        let token = autoHideToken
        autoHideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if token == autoHideToken, player.isPlaying {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        controlsVisible = false
                    }
                }
            }
        }
    }

    private func startSkipFetch() {
        guard let malId, episode.number > 0 else { return }
        skipTask?.cancel()
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: episode.number) {
            skipSegments = cached
            return
        }
        skipTask = Task {
            let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: episode.number)
            await MainActor.run {
                self.skipSegments = segments
                if !segments.isEmpty {
                    appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: episode.number)
                }
            }
        }
    }

    private func updateSkipState() {
        guard !skipSegments.isEmpty else {
            activeSkip = nil
            return
        }
        let time = player.position
        if let segment = skipSegments.first(where: { time >= $0.start && time < $0.end }) {
            activeSkip = segment
        } else {
            activeSkip = nil
        }
    }

    private func skipButton(for segment: AniSkipSegment) -> some View {
        let label = segmentLabel(segment)
        return VStack {
            HStack {
                Spacer()
                Button {
                    player.seek(to: segment.end)
                    activeSkip = nil
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "forward.fill")
                        Text(label)
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.7))
                    )
                }
                .padding(.trailing, 16)
                .padding(.top, 80)
            }
            Spacer()
        }
    }

    private func segmentLabel(_ segment: AniSkipSegment) -> String {
        let type = segment.type.lowercased()
        if type.contains("op") || type.contains("intro") {
            return "Skip Intro"
        }
        if type.contains("ed") || type.contains("outro") {
            return "Skip Outro"
        }
        if type.contains("recap") {
            return "Skip Recap"
        }
        if type.contains("preview") {
            return "Skip Preview"
        }
        return "Skip"
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

#if os(iOS)
private struct AVPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let mediaTitle: String?
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var playerItem: AVPlayerItem?
    @State private var timeObserver: Any?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var errorMessage: String?

    var body: some View {
        ZStack {
            if let player {
                AVPlayerViewControllerRepresentable(player: player)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                ProgressView("Loading player...")
                    .tint(.white)
                    .foregroundColor(.white)
            }
        }
        .onAppear(perform: startPlayback)
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
        self.playerItem = item
        let avPlayer = AVPlayer(playerItem: item)
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
        player.pause()
        player.replaceCurrentItem(with: nil)
        self.player = nil
        self.playerItem = nil
    }

    private func addObservers(to player: AVPlayer, item: AVPlayerItem) {
        let startTime = PlaybackHistoryStore.shared.position(for: episode.id) ?? 0

        statusObserver = item.observe(\.status, options: [.initial, .new]) { observed, _ in
            switch observed.status {
            case .readyToPlay:
                if startTime > 0 {
                    player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
                }
            case .failed:
                errorMessage = observed.error?.localizedDescription ?? "Playback failed."
            default:
                break
            }
        }

        let interval = CMTime(seconds: 1.0, preferredTimescale: 2)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            let seconds = time.seconds
            guard seconds.isFinite else { return }
            let duration = player.currentItem?.duration.seconds ?? 0
            if duration.isFinite && duration > 0 {
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
                    PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                    PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
                }
            }
        }
    }
}

private struct AVPlayerViewControllerRepresentable: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        if #available(iOS 14.2, *) {
            controller.canStartPictureInPictureAutomaticallyFromInline = true
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
#endif
