import SwiftUI
import AVKit

struct PlayerView: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    @EnvironmentObject private var appState: AppState
    @StateObject private var playerModel = MPVPlayerViewModel()
    @State private var selectedSource: SoraSource?
    @State private var selectedAudio: String = "Sub"
    @State private var selectedQuality: String = "Auto"

    @State private var pipPlayer: AVPlayer?
    @State private var pipController: AVPlayerViewController?
    @State private var showPipController = false
    @State private var pipSource: SoraSource?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            MPVPlayerContainer(viewModel: playerModel)
                .ignoresSafeArea()
                .onAppear {
                    AppLog.debug(.player, "player appear episode=\(episode.id)")
                    applyDefaultsFromSettings()
                    playerModel.initializeIfNeeded()
                    let initial = pickSource(audio: selectedAudio, quality: selectedQuality) ?? sources.first
                    selectedSource = initial
                    if let src = initial {
                        playerModel.load(url: src.url, headers: src.headers)
                    }
                    if let saved = PlaybackHistoryStore.shared.position(for: episode.id) {
                        playerModel.seek(to: saved)
                    }
                    playerModel.setPaused(false)
                    UIApplication.shared.isIdleTimerDisabled = true
                }
                .onDisappear {
                    if let seconds = playerModel.currentTime(), seconds.isFinite {
                        PlaybackHistoryStore.shared.save(position: seconds, for: episode.id)
                    }
                    playerModel.setPaused(true)
                    playerModel.destroy()
                    UIApplication.shared.isIdleTimerDisabled = false
                    AppLog.debug(.player, "player disappear episode=\(episode.id)")
                }

            HStack(spacing: 10) {
                Button(action: startPiP) {
                    Image(systemName: "pip.enter")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
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
            .padding(12)
        }
        .sheet(isPresented: $showPipController) {
            if let controller = pipController {
                PiPControllerHost(
                    controller: controller,
                    player: $pipPlayer,
                    onPiPEnded: { resumeTime in
                        resumeFromPiP(at: resumeTime)
                    }
                )
                .ignoresSafeArea()
            }
        }
        .statusBar(hidden: true)
    }

    private func startPiP() {
        guard let source = selectedSource ?? pickSource(audio: selectedAudio, quality: selectedQuality) else { return }
        let currentTime = playerModel.currentTime() ?? 0
        pipSource = source
        pipPlayer = makePiPPlayer(source: source, startTime: currentTime)
        if pipController == nil {
            let controller = AVPlayerViewController()
            controller.allowsPictureInPicturePlayback = true
            controller.showsPlaybackControls = true
            pipController = controller
        }
        playerModel.setPaused(true)
        showPipController = true
    }

    private func resumeFromPiP(at time: Double?) {
        guard let source = pipSource else { return }
        let resumeTime = time ?? 0
        playerModel.load(url: source.url, headers: source.headers)
        if resumeTime.isFinite && resumeTime > 0 {
            playerModel.seek(to: resumeTime)
        }
        playerModel.setPaused(false)
        pipPlayer?.pause()
        pipPlayer = nil
        pipSource = nil
    }

    private func makePiPPlayer(source: SoraSource, startTime: Double) -> AVPlayer {
        let options: [String: Any] = [
            "AVURLAssetHTTPHeaderFieldsKey": source.headers
        ]
        let asset = AVURLAsset(url: source.url, options: options)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        if startTime.isFinite && startTime > 0 {
            player.seek(to: CMTime(seconds: startTime, preferredTimescale: 600))
        }
        player.play()
        return player
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
        let currentTime = playerModel.currentTime()
        playerModel.load(url: target.url, headers: target.headers)
        if let seconds = currentTime, seconds.isFinite {
            playerModel.seek(to: seconds)
        }
        playerModel.setPaused(false)
    }
}

private struct PiPControllerHost: UIViewControllerRepresentable {
    let controller: AVPlayerViewController
    @Binding var player: AVPlayer?
    let onPiPEnded: (Double?) -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        controller.delegate = context.coordinator
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.showsPlaybackControls = true
        return controller
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        if uiViewController.player !== player {
            uiViewController.player = player
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPiPEnded: onPiPEnded)
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        private let onPiPEnded: (Double?) -> Void

        init(onPiPEnded: @escaping (Double?) -> Void) {
            self.onPiPEnded = onPiPEnded
        }

        func playerViewControllerDidStopPictureInPicture(_ playerViewController: AVPlayerViewController) {
            let time = playerViewController.player?.currentTime().seconds
            onPiPEnded(time)
        }
    }
}
