import SwiftUI
import AVKit

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    @Environment(\.dismiss) private var dismiss
    @State private var player = AVPlayer()
    @State private var playbackSpeed: Float = 1.0
    @State private var selectedSource: SoraSource?
    @State private var selectedAudio: String = "Sub"
    @State private var selectedQuality: String = "Auto"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            PlayerContainer(player: $player)
                .ignoresSafeArea()
                .onAppear {
                    AppLog.player.debug("player appear episode=\(episode.id, privacy: .public)")
                    let initial = pickSource(audio: selectedAudio, quality: selectedQuality) ?? sources.first
                    selectedSource = initial
                    if let src = initial {
                        let item = AVPlayerItem(url: src.url)
                        player.replaceCurrentItem(with: item)
                    }
                    if let saved = PlaybackHistoryStore.shared.position(for: episode.id) {
                        let cm = CMTime(seconds: saved, preferredTimescale: 600)
                        player.seek(to: cm, toleranceBefore: .zero, toleranceAfter: .zero)
                    }
                    player.play()
                }
                .onDisappear {
                    let seconds = player.currentTime().seconds
                    if seconds.isFinite {
                        PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                    }
                    player.pause()
                    AppLog.player.debug("player disappear episode=\(episode.id, privacy: .public)")
                }

            HStack(spacing: 12) {
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .padding(10)
                        .background(Color.black.opacity(0.5), in: Circle())
                }

                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                        Button("\(String(format: "%.2gx", speed))") {
                            setSpeed(speed)
                        }
                    }
                } label: {
                    Text("\(String(format: "%.2gx", playbackSpeed))")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }

                Menu {
                    ForEach(audioOptions(), id: \.self) { audio in
                        Button(audio) {
                            selectedAudio = audio
                            switchSource(audio: audio, quality: selectedQuality)
                        }
                    }
                } label: {
                    Text(selectedAudio)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }

                Menu {
                    ForEach(qualityOptions(for: selectedAudio), id: \.self) { q in
                        Button(q) {
                            selectedQuality = q
                            switchSource(audio: selectedAudio, quality: q)
                        }
                    }
                } label: {
                    Text(selectedQuality)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.5), in: Capsule())
                }
            }
            .padding(16)
        }
        .statusBar(hidden: true)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func setSpeed(_ speed: Double) {
        AppLog.player.debug("player speed change \(speed)")
        playbackSpeed = Float(speed)
        let currentTime = player.currentTime()
        player.rate = playbackSpeed
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    private func audioKey(_ value: String) -> String {
        let v = value.lowercased()
        if v.contains("sub") || v.contains("jpn") || v.contains("jp") { return "sub" }
        if v.contains("dub") || v.contains("eng") { return "dub" }
        return "sub"
    }

    private func qualityOptions(for audio: String) -> [String] {
        let key = audioKey(audio)
        let pool = sources.filter { audioKey($0.subOrDub) == key }
        let list = pool.isEmpty ? sources : pool
        let qualities = Set(list.map { $0.quality.isEmpty ? "Auto" : $0.quality })
        return qualities.sorted { a, b in
            if a == "Auto" { return true }
            if b == "Auto" { return false }
            return a > b
        }
    }

    private func audioOptions() -> [String] {
        let options = Set(sources.map { audioKey($0.subOrDub) == "dub" ? "Dub" : "Sub" })
        return options.isEmpty ? ["Sub"] : Array(options)
    }

    private func pickSource(audio: String, quality: String) -> SoraSource? {
        let key = audioKey(audio)
        var pool = sources.filter { audioKey($0.subOrDub) == key }
        if pool.isEmpty { pool = sources }
        if quality.lowercased() != "auto" {
            if let exact = pool.first(where: { $0.quality.lowercased().contains(quality.lowercased()) }) {
                return exact
            }
        }
        return pool.first
    }

    private func switchSource(audio: String, quality: String) {
        guard let target = pickSource(audio: audio, quality: quality) else { return }
        AppLog.player.debug("player source switch audio=\(audio, privacy: .public) quality=\(quality, privacy: .public)")
        selectedSource = target
        let currentTime = player.currentTime()
        let item = AVPlayerItem(url: target.url)
        player.replaceCurrentItem(with: item)
        player.seek(to: currentTime, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }
}

private struct PlayerContainer: UIViewControllerRepresentable {
    @Binding var player: AVPlayer

    func makeUIViewController(context: Context) -> PlayerHostController {
        let controller = PlayerHostController()
        controller.player = player
        return controller
    }

    func updateUIViewController(_ uiViewController: PlayerHostController, context: Context) {
        uiViewController.player = player
    }
}

final class PlayerHostController: AVPlayerViewController {
    override var prefersStatusBarHidden: Bool { true }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscape }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }
}
