import SwiftUI
import AVKit

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    @State private var player: AVPlayer? = nil

    var body: some View {
        BasicAVPlayerContainer(player: $player)
            .ignoresSafeArea()
            .onAppear {
                AppLog.debug(.player, "player appear episode=\(episode.id)")
                if player == nil {
                    player = makePlayer()
                }
                player?.play()
                UIApplication.shared.isIdleTimerDisabled = true
            }
            .onDisappear {
                if let current = player?.currentTime().seconds, current.isFinite {
                    PlaybackHistoryStore.shared.save(position: current, for: episode.id)
                }
                player?.pause()
                player = nil
                UIApplication.shared.isIdleTimerDisabled = false
                AppLog.debug(.player, "player disappear episode=\(episode.id)")
            }
            .statusBar(hidden: true)
    }

    private func pickSource(audio: String, quality: String) -> SoraSource? {
        _ = audio
        _ = quality
        return bestSource()
    }

    private func bestSource() -> SoraSource? {
        if sources.isEmpty { return nil }
        let ranked = sources.sorted { lhs, rhs in
            let left = sourceRank(lhs)
            let right = sourceRank(rhs)
            if left != right { return left < right }
            return qualityScore(lhs.quality) > qualityScore(rhs.quality)
        }
        return ranked.first
    }

    private func sourceRank(_ source: SoraSource) -> Int {
        switch source.format.lowercased() {
        case "m3u8": return 0
        case "ts": return 1
        case "mp4": return 2
        default: return 3
        }
    }

    private func qualityScore(_ value: String) -> Int {
        let digits = value.filter { $0.isNumber }
        return Int(digits) ?? 0
    }

    private func makePlayer() -> AVPlayer? {
        guard let src = pickSource(audio: "sub", quality: "auto") else { return nil }
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": src.headers
        ]
        let asset = AVURLAsset(url: src.url, options: options)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        if let saved = PlaybackHistoryStore.shared.position(for: episode.id), saved.isFinite {
            player.seek(to: CMTime(seconds: saved, preferredTimescale: 600))
        }
        return player
    }
}

private struct BasicAVPlayerContainer: UIViewControllerRepresentable {
    @Binding var player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
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

