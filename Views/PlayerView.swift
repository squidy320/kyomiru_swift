import SwiftUI
import AVKit

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    @EnvironmentObject private var appState: AppState
    @State private var player: AVPlayer?
    @State private var selectedSource: SoraSource?
    @State private var selectedAudio: String = "Sub"
    @State private var selectedQuality: String = "Auto"

    var body: some View {
        ZStack(alignment: .topTrailing) {
            AVPlayerContainer(player: $player)
                .ignoresSafeArea()
                .onAppear {
                    AppLog.debug(.player, "player appear episode=\(episode.id)")
                    applyDefaultsFromSettings()
                    let initial = pickSource(audio: selectedAudio, quality: selectedQuality) ?? sources.first
                    selectedSource = initial
                    if let src = initial {
                        startPlayback(source: src, seekToSaved: true)
                    }
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onDisappear {
                    if let seconds = player?.currentTime().seconds, seconds.isFinite {
                        PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                    }
                    player?.pause()
                    player = nil
                    UIApplication.shared.isIdleTimerDisabled = false
                    AppLog.debug(.player, "player disappear episode=\(episode.id)")
                }

            HStack(spacing: 10) {
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
            .padding(12)
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

    private func makePlayerItem(source: SoraSource) -> AVPlayerItem {
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": source.headers
        ]
        let asset = AVURLAsset(url: source.url, options: options)
        return AVPlayerItem(asset: asset)
    }

    private func applyDefaultsFromSettings() {
        let audio = appState.settings.defaultAudio
        let quality = appState.settings.defaultQuality
        selectedAudio = audio.isEmpty ? "Sub" : audio
        selectedQuality = quality.isEmpty ? "Auto" : quality
    }

    private func audioKey(_ value: String) -> String {
        let v = value.lowercased()
        if v.contains("any") { return "any" }
        if v.contains("sub") || v.contains("jpn") || v.contains("jp") { return "sub" }
        if v.contains("dub") || v.contains("eng") { return "dub" }
        return "sub"
    }

    private func qualityOptions(for audio: String) -> [String] {
        let key = audioKey(audio)
        let pool = key == "any" ? sources : sources.filter { audioKey($0.subOrDub) == key }
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
        var out = Array(options)
        out.sort()
        if !out.contains("Any") { out.insert("Any", at: 0) }
        return out
    }

    private func pickSource(audio: String, quality: String) -> SoraSource? {
        let key = audioKey(audio)
        var pool = key == "any" ? sources : sources.filter { audioKey($0.subOrDub) == key }
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
        AppLog.debug(.player, "player source switch audio=\(audio) quality=\(quality)")
        selectedSource = target
        let currentTime = player?.currentTime().seconds ?? 0
        startPlayback(source: target, seekToSaved: false)
        if currentTime.isFinite && currentTime > 0 {
            player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
        }
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
