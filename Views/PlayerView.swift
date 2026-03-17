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
            AVPlayerScreen(
                episode: episode,
                sources: sources,
                mediaId: mediaId,
                mediaTitle: mediaTitle
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
