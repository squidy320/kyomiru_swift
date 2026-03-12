import SwiftUI
import AVKit
import AVFoundation

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    @EnvironmentObject private var appState: AppState
    @StateObject private var viewModel = PlayerViewModel()
    @State private var timeObserverToken: Any?

    var body: some View {
        ZStack {
            AVPlayerContainer(player: $viewModel.player)
                .ignoresSafeArea()
            if viewModel.isPreparing {
                Color.black.opacity(0.55).ignoresSafeArea()
                VStack(spacing: 12) {
                    ProgressView(value: viewModel.conversionProgress)
                        .tint(.white)
                        .frame(width: 160)
                    Text("Preparing Video...")
                        .foregroundColor(.white)
                        .font(.system(size: 14, weight: .semibold))
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.black.opacity(0.75))
                )
            }
        }
        .onAppear {
            AppLog.debug(.player, "player appear episode=\(episode.id)")
            PlaybackHistoryStore.shared.saveLastEpisode(
                mediaId: mediaId,
                episodeId: episode.id,
                episodeNumber: episode.number
            )
            if let src = sources.first {
                startPlayback(source: src, seekToSaved: true)
            }
            seedProgressFromHistory()
            attachProgressObserver()
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            detachProgressObserver()
            if let seconds = viewModel.player?.currentTime().seconds, seconds.isFinite {
                PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
            }
            if let duration = viewModel.player?.currentItem?.duration.seconds, duration.isFinite {
                PlaybackHistoryStore.shared.saveDuration(duration, for: episode.id)
            }
            viewModel.player?.pause()
            viewModel.player = nil
            UIApplication.shared.isIdleTimerDisabled = false
            AppLog.debug(.player, "player disappear episode=\(episode.id)")
        }
        .alert("Playback Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { _ in viewModel.errorMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "Unknown error")
        }
        .statusBar(hidden: true)
    }

    private func startPlayback(source: SoraSource, seekToSaved: Bool) {
        viewModel.prepareAndPlay(
            source: source,
            episodeId: episode.id,
            seekToSaved: seekToSaved,
            headers: source.headers
        )
    }

    private func attachProgressObserver() {
        guard timeObserverToken == nil, let player = viewModel.player else { return }
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
        if let token = timeObserverToken, let player = viewModel.player {
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

}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var isPreparing = false
    @Published var conversionProgress: Double = 0
    @Published var errorMessage: String?

    func prepareAndPlay(source: SoraSource, episodeId: String, seekToSaved: Bool, headers: [String: String]) {
        if source.url.isFileURL && source.url.pathExtension.lowercased() == "ts" {
            let mp4URL = source.url.deletingPathExtension().appendingPathExtension("mp4")
            if FileManager.default.fileExists(atPath: mp4URL.path) {
                let item = makePlayerItem(url: mp4URL, headers: [:])
                replaceAndPlay(item: item, episodeId: episodeId, seekToSaved: seekToSaved)
                return
            }
            if !FileManager.default.fileExists(atPath: source.url.path) {
                errorMessage = "Missing local file."
                AppLog.error(.player, "local ts missing episode=\(episodeId)")
                return
            }
            isPreparing = true
            conversionProgress = 0
            Task {
                do {
                    let output = try await MediaConversionManager.shared.convertToMp4(inputURL: source.url) { value in
                        Task { @MainActor in
                            self.conversionProgress = value
                        }
                    }
                    isPreparing = false
                    let item = makePlayerItem(url: output, headers: [:])
                    replaceAndPlay(item: item, episodeId: episodeId, seekToSaved: seekToSaved)
                } catch {
                    isPreparing = false
                    errorMessage = "Conversion failed: \(error.localizedDescription)"
                    AppLog.error(.player, "remux failed episode=\(episodeId) error=\(error.localizedDescription)")
                }
            }
        } else {
            let item = makePlayerItem(url: source.url, headers: headers)
            replaceAndPlay(item: item, episodeId: episodeId, seekToSaved: seekToSaved)
        }
    }

    private func replaceAndPlay(item: AVPlayerItem, episodeId: String, seekToSaved: Bool) {
        if player == nil {
            player = AVPlayer(playerItem: item)
        } else {
            player?.replaceCurrentItem(with: item)
        }
        if seekToSaved, let saved = PlaybackHistoryStore.shared.position(for: episodeId), saved.isFinite {
            player?.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
        }
        player?.play()
    }

    private func makePlayerItem(url: URL, headers: [String: String]) -> AVPlayerItem {
        let options: [String: Any] = headers.isEmpty ? [:] : ["AVURLAssetHTTPHeaderFieldsKey": headers]
        let asset = AVURLAsset(url: url, options: options)
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
