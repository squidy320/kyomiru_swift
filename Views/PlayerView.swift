import SwiftUI
import AVKit

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    @EnvironmentObject private var appState: AppState
    @State private var player: AVPlayer?
    @State private var timeObserverToken: Any?

    var body: some View {
        AVPlayerContainer(player: $player)
            .ignoresSafeArea()
            .onAppear {
                AppLog.debug(.player, "player appear episode=\(episode.id)")
                if let src = sources.first {
                    startPlayback(source: src, seekToSaved: true)
                }
                seedProgressFromHistory()
                attachProgressObserver()
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                detachProgressObserver()
                if let seconds = player?.currentTime().seconds, seconds.isFinite {
                    PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                }
                if let duration = player?.currentItem?.duration.seconds, duration.isFinite {
                    PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
                }
                player?.pause()
                player = nil
                UIApplication.shared.isIdleTimerDisabled = false
                AppLog.debug(.player, "player disappear episode=\(episode.id)")
            }
        .statusBar(hidden: true)
    }

    private func startPlayback(source: SoraSource, seekToSaved: Bool) {
        let item = makePlayerItem(source: source)
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        if seekToSaved, let saved = PlaybackHistoryStore.shared.position(for: episode.id), saved.isFinite {
            player?.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
        }
        player?.play()
    }

    private func attachProgressObserver() {
        guard timeObserverToken == nil, let player else { return }
        let interval = CMTime(seconds: 1, preferredTimescale: 2)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard let duration = player.currentItem?.duration.seconds, duration.isFinite else { return }
            let current = time.seconds
            if current.isFinite {
                appState.services.playbackEngine.updateProgress(
                    for: String(mediaId),
                    currentTime: current,
                    duration: duration
                )
                appState.services.playbackEngine.updateProgress(
                    for: "episode:\(episode.id)",
                    currentTime: current,
                    duration: duration
                )
                PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
            }
        }
    }

    private func detachProgressObserver() {
        if let token = timeObserverToken, let player {
            player.removeTimeObserver(token)
        }
        timeObserverToken = nil
    }

    private func seedProgressFromHistory() {
        if let position = PlaybackHistoryStore.shared.position(for: episode.id),
           let duration = PlaybackHistoryStore.shared.duration(for: episode.id),
           duration.isFinite, position.isFinite {
            appState.services.playbackEngine.updateProgress(
                for: "episode:\(episode.id)",
                currentTime: position,
                duration: duration
            )
        }
    }

    private func makePlayerItem(source: SoraSource) -> AVPlayerItem {
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": source.headers
        ]
        let asset = AVURLAsset(url: source.url, options: options)
        return AVPlayerItem(asset: asset)
    }

}

private struct AVPlayerContainer: UIViewControllerRepresentable {
    @Binding var player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        controller.player = player
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }
}
