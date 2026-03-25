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
    struct Context {
        let episode: SoraEpisode
        let mediaId: Int
        let malId: Int?
        let mediaTitle: String?
        let startAt: Double?
    }

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isPaused = false
    @Published var isBuffering = true
    @Published var errorMessage: String?
    @Published var showControls = true
    @Published var activeSkip: AniSkipSegment?
    @Published var isPictureInPictureActive = false
    @Published var isPictureInPicturePossible = AVPictureInPictureController.isPictureInPictureSupported()
    @Published private(set) var commandToken = 0
    @Published private(set) var pendingCommand: MPVPlaybackCommand?

    let context: Context

    private var appState: AppState?
    private var skipSegments: [AniSkipSegment] = []
    private var didApplyResume = false
    private var pendingResumeTime: Double?
    private var didMarkWatched = false
    private var autoHideTask: Task<Void, Never>?
    private var holdSpeedRestoreRate: Double = 1.0
    private var isHoldSpeedActive = false
    private var onRestoreAfterPictureInPicture: (() -> Void)?
    private var onDismissForPictureInPicture: (() -> Void)?
    private var currentSource: MPVResolvedSource?

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
        Task { await loadSkipSegments() }
        scheduleAutoHide()
    }

    func cleanup() {
        autoHideTask?.cancel()
    }

    func toggleControlsVisibility() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls.toggle()
        }
        scheduleAutoHide()
    }

    func noteInteraction() {
        withAnimation(.easeInOut(duration: 0.2)) {
            showControls = true
        }
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
        sendCommand(.seek(seconds))
        noteInteraction()
    }

    func skip(by interval: Double) {
        let target = max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude, currentTime + interval))
        seek(to: target)
    }

    func beginHoldSpeed() {
        guard !isHoldSpeedActive else { return }
        guard !isPaused else { return }
        guard let appState else { return }
        isHoldSpeedActive = true
        holdSpeedRestoreRate = 1.0
        sendCommand(.setRate(appState.settings.playerHoldSpeed.rawValue))
    }

    func endHoldSpeed() {
        guard isHoldSpeedActive else { return }
        isHoldSpeedActive = false
        sendCommand(.setRate(holdSpeedRestoreRate))
    }

    func handleReady() {
        isBuffering = false
        guard !didApplyResume, let pendingResumeTime else { return }
        didApplyResume = true
        seek(to: pendingResumeTime)
        self.pendingResumeTime = nil
    }

    func handleTimeChanged(_ time: Double) {
        currentTime = time
        updateActiveSkip(at: time)
        syncProgress(currentTime: time, duration: duration)
    }

    func handleDurationChanged(_ duration: Double) {
        self.duration = duration
    }

    func handlePauseChanged(_ paused: Bool) {
        isPaused = paused
        if paused {
            autoHideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) {
                showControls = true
            }
        } else {
            scheduleAutoHide()
        }
    }

    func handleBufferingChanged(_ buffering: Bool) {
        isBuffering = buffering
    }

    func handleEnded() {
        currentTime = duration
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
            },
            onRestore: { [weak self] in
                self?.onRestoreAfterPictureInPicture?()
            },
            onError: { [weak self] message in
                self?.isPictureInPictureActive = false
                self?.errorMessage = message
            }
        )
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
        } else if let saved = PlaybackHistoryStore.shared.position(for: context.episode.id), saved >= 5 {
            pendingResumeTime = saved
        } else {
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
        pendingCommand = command
        commandToken += 1
    }

    private func loadSkipSegments() async {
        guard let appState, let malId = context.malId else { return }
        if let cached = appState.services.downloadManager.cachedSkipSegments(malId: malId, episode: context.episode.number) {
            skipSegments = cached
            updateActiveSkip(at: currentTime)
        }
        let segments = await appState.services.aniSkipService.fetchSkipSegments(malId: malId, episode: context.episode.number)
        guard !segments.isEmpty else { return }
        skipSegments = segments
        updateActiveSkip(at: currentTime)
        appState.services.downloadManager.storeSkipSegments(segments, malId: malId, episode: context.episode.number)
    }

    private func updateActiveSkip(at time: Double) {
        let matches = skipSegments.filter { time >= $0.start && time <= $0.end }
        activeSkip = matches.min(by: { $0.end < $1.end })
    }

    private func scheduleAutoHide() {
        autoHideTask?.cancel()
        guard !isPaused else { return }
        autoHideTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                self.showControls = false
            }
        }
    }
}

private final class MPVPictureInPictureSession: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = MPVPictureInPictureSession()

    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var controller: AVPictureInPictureController?
    private var hostWindow: UIWindow?
    private var timeObserver: Any?
    private var onStart: (() -> Void)?
    private var onStop: ((Double) -> Void)?
    private var onRestore: (() -> Void)?
    private var onError: ((String) -> Void)?
    private weak var appState: AppState?
    private var didMarkWatched = false

    func start(
        source: MPVResolvedSource,
        startTime: Double,
        mediaId: Int,
        episodeId: String,
        episodeNumber: Int,
        appState: AppState?,
        onStart: @escaping () -> Void,
        onStop: @escaping (Double) -> Void,
        onRestore: @escaping () -> Void,
        onError: @escaping (String) -> Void
    ) {
        stopInternal()

        self.appState = appState
        self.onStart = onStart
        self.onStop = onStop
        self.onRestore = onRestore
        self.onError = onError
        self.didMarkWatched = false

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
        let hostWindow = windowScene.map { UIWindow(windowScene: $0) } ?? UIWindow(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        hostWindow.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        hostWindow.windowLevel = .normal + 1
        hostWindow.backgroundColor = .clear

        let hostController = UIViewController()
        hostController.view.backgroundColor = .clear
        hostWindow.rootViewController = hostController
        hostWindow.isHidden = false
        self.hostWindow = hostWindow

        let playerLayer = AVPlayerLayer(player: player)
        playerLayer.frame = hostController.view.bounds
        playerLayer.videoGravity = .resizeAspect
        hostController.view.layer.addSublayer(playerLayer)
        self.playerLayer = playerLayer

        let pip = AVPictureInPictureController(playerLayer: playerLayer)
        pip.delegate = self
        if #available(iOS 14.2, *) {
            pip.canStartPictureInPictureAutomaticallyFromInline = true
        }
        self.controller = pip

        player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        installTimeObserver(mediaId: mediaId, episodeId: episodeId, episodeNumber: episodeNumber)
        pip.startPictureInPicture()
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
        onRestore?()
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
    @StateObject private var playbackController: MPVPlaybackController
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var wasPausedBeforeScrubbing = false

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

    private var displayedTime: Double {
        isScrubbing ? scrubTime : playbackController.currentTime
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
                .onTapGesture {
                    playbackController.toggleControlsVisibility()
                }
                .overlay(alignment: .center) {
                    if playbackController.isBuffering {
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(.white)
                    }
                }

                overlayChrome
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
            guard let source else { return }
            playbackController.configure(
                appState: appState,
                source: source,
                onRestoreAfterPictureInPicture: onRestoreAfterPictureInPicture,
                onDismissForPictureInPicture: { dismiss() }
            )
        }
        .onDisappear {
            playbackController.cleanup()
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
    }

    private var overlayChrome: some View {
        ZStack {
            if playbackController.showControls {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    centerControls
                    Spacer()
                    bottomBar
                }
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: playbackController.showControls)
    }

    private var topBar: some View {
        LinearGradient(
            colors: [Color.black.opacity(0.78), Color.black.opacity(0.38), .clear],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: 128)
        .overlay(alignment: .top) {
            HStack(spacing: 14) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.12))
                        .clipShape(Circle())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(mediaTitle ?? "Now Playing")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Episode \(episode.number)")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.76))
                        .lineLimit(1)
                }

                Spacer()

                if playbackController.isPictureInPicturePossible {
                    Button {
                        playbackController.startPictureInPicture()
                    } label: {
                        Image(systemName: playbackController.isPictureInPictureActive ? "pip.exit" : "pip.enter")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Circle())
                    }
                    .disabled(playbackController.isPictureInPictureActive)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 10)
        }
    }

    private var centerControls: some View {
        HStack(spacing: 28) {
            transportButton(systemName: "gobackward", title: "\(Int(appState.settings.playerSkipIntervalSeconds))s") {
                playbackController.skip(by: -appState.settings.playerSkipIntervalSeconds)
            }

            Button {
                playbackController.togglePaused()
            } label: {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.16))
                        .frame(width: 82, height: 82)
                    Circle()
                        .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                        .frame(width: 82, height: 82)
                    Image(systemName: playbackController.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .onLongPressGesture(minimumDuration: 0.35, maximumDistance: 24, pressing: { isPressing in
                if isPressing {
                    playbackController.beginHoldSpeed()
                } else {
                    playbackController.endHoldSpeed()
                }
            }, perform: {})

            transportButton(systemName: "goforward", title: "\(Int(appState.settings.playerSkipIntervalSeconds))s") {
                playbackController.skip(by: appState.settings.playerSkipIntervalSeconds)
            }
        }
    }

    private var bottomBar: some View {
        LinearGradient(
            colors: [.clear, Color.black.opacity(0.44), Color.black.opacity(0.84)],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(maxWidth: .infinity)
        .frame(height: 188)
        .overlay(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    if let activeSkip = playbackController.activeSkip {
                        Button {
                            playbackController.seek(to: activeSkip.end)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "forward.end.fill")
                                Text(mpvSkipTitle(for: activeSkip))
                                    .fontWeight(.semibold)
                            }
                            .font(.footnote)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.14))
                            .clipShape(Capsule())
                        }
                    }

                    Spacer()

                    if playbackController.isBuffering {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                            Text("Buffering")
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.84))
                        }
                    }
                }

                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { displayedTime },
                            set: { newValue in
                                scrubTime = newValue
                            }
                        ),
                        in: 0...(max(playbackController.duration, 1)),
                        onEditingChanged: handleScrubbingChanged
                    )
                    .tint(.white)

                    HStack {
                        Text(mpvTimeString(displayedTime))
                        Spacer()
                        Text("-\(mpvTimeString(max(playbackController.duration - displayedTime, 0)))")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.84))
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 22)
        }
    }

    private func transportButton(systemName: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 23, weight: .semibold))
                Text(title)
                    .font(.caption2.weight(.semibold))
            }
            .foregroundStyle(.white)
            .frame(width: 64, height: 64)
            .background(Color.white.opacity(0.12))
            .clipShape(Circle())
        }
    }

    private func handleScrubbingChanged(_ editing: Bool) {
        playbackController.noteInteraction()
        if editing {
            isScrubbing = true
            scrubTime = playbackController.currentTime
            wasPausedBeforeScrubbing = playbackController.isPaused
            playbackController.setPaused(true)
        } else {
            isScrubbing = false
            playbackController.seek(to: scrubTime)
            if !wasPausedBeforeScrubbing {
                playbackController.setPaused(false)
            }
        }
    }
}

private protocol MPVViewControllerDelegate: AnyObject {
    func mpvViewControllerDidBecomeReady(_ controller: MPVViewController)
    func mpvViewController(_ controller: MPVViewController, didUpdateTime time: Double)
    func mpvViewController(_ controller: MPVViewController, didUpdateDuration duration: Double)
    func mpvViewController(_ controller: MPVViewController, didChangePauseState isPaused: Bool)
    func mpvViewController(_ controller: MPVViewController, didChangeBufferingState isBuffering: Bool)
    func mpvViewControllerDidFinishPlayback(_ controller: MPVViewController)
    func mpvViewController(_ controller: MPVViewController, didFailWithError message: String)
}

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
        if let command = controller.pendingCommand {
            uiViewController.handle(command: command, token: controller.commandToken)
        }
    }
}

private final class MPVViewController: UIViewController {
    weak var delegate: MPVViewControllerDelegate?

    private let renderLayer = MPVMetalLayer()
    private var mpvHandle: OpaquePointer?
    private var eventsQueue = DispatchQueue(label: "kyomiru.mpv.events", qos: .userInitiated)
    private var observationTimer: Timer?
    private var currentSource: MPVResolvedSource?
    private var lastCommandToken = -1
    private var isReady = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        renderLayer.frame = view.bounds
        view.layer.addSublayer(renderLayer)
        initializeMPV()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        renderLayer.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if self.isBeingDismissed || self.view.window == nil {
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

    func handle(command: MPVPlaybackCommand, token: Int) {
        guard token != lastCommandToken else { return }
        lastCommandToken = token

        switch command {
        case .seek(let seconds):
            sendCommand(["seek", "\(seconds)", "absolute+exact"])
        case .setPaused(let paused):
            setFlagProperty(name: "pause", value: paused)
        case .setRate(let rate):
            setDoubleProperty(name: "speed", value: rate)
        }
    }

    private func initializeMPV() {
        guard mpvHandle == nil else { return }
        guard let handle = mpv_create() else {
            delegate?.mpvViewController(self, didFailWithError: "mpv could not be created.")
            return
        }

        mpvHandle = handle
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "gpu-api", "vulkan")
        mpv_set_option_string(handle, "gpu-context", "moltenvk")
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        mpv_set_option_string(handle, "keep-open", "yes")
        mpv_set_option_string(handle, "osc", "no")
        mpv_set_option_string(handle, "input-default-bindings", "yes")
        mpv_set_option_string(handle, "input-vo-keyboard", "no")
        mpv_set_option_string(handle, "sub-auto", "fuzzy")

        var wid = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(renderLayer).toOpaque())))
        withUnsafePointer(to: &wid) { ptr in
            _ = mpv_set_option(handle, "wid", MPV_FORMAT_INT64, UnsafeRawPointer(ptr))
        }

        let result = mpv_initialize(handle)
        guard result >= 0 else {
            delegate?.mpvViewController(self, didFailWithError: "mpv failed to initialize.")
            teardownMPV()
            return
        }

        startObserving()
        if currentSource != nil {
            loadCurrentSource()
        }
    }

    private func loadCurrentSource() {
        guard let handle = mpvHandle, let source = currentSource else { return }
        isReady = false
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
        observationTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.pollState()
        }
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
        }

        delegate?.mpvViewController(self, didUpdateDuration: duration)
        delegate?.mpvViewController(self, didUpdateTime: timePos)
        delegate?.mpvViewController(self, didChangePauseState: pause)
        delegate?.mpvViewController(self, didChangeBufferingState: cache || !isReady)

        if eof {
            delegate?.mpvViewControllerDidFinishPlayback(self)
        }
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
        if let handle = mpvHandle {
            mpv_terminate_destroy(handle)
            mpvHandle = nil
        }
    }

    deinit {
        teardownMPV()
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
