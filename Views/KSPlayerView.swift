import SwiftUI
#if os(iOS) && canImport(KSPlayer)
import AVFoundation
import UIKit
import KSPlayer
#endif

#if os(iOS) && canImport(KSPlayer)
struct KSPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onRestoreAfterPictureInPicture: (() -> Void)?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        KSPlayerViewRepresentable(
            episode: episode,
            sources: sources,
            mediaId: mediaId,
            malId: malId,
            mediaTitle: mediaTitle,
            startAt: startAt
        )
        .ignoresSafeArea()
    }
}

struct KSPlayerViewRepresentable: UIViewControllerRepresentable {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.backgroundColor = .black

        let playerView = IOSVideoPlayerView()
        playerView.backBlock = {
            // Navigate back
        }

        controller.view.addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: controller.view.topAnchor),
            playerView.leftAnchor.constraint(equalTo: controller.view.leftAnchor),
            playerView.rightAnchor.constraint(equalTo: controller.view.rightAnchor),
            playerView.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
        ])

        setupPlayback(playerView: playerView)
        context.coordinator.playerView = playerView
        context.coordinator.controller = controller

        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func setupPlayback(playerView: IOSVideoPlayerView) {
        guard let source = sources.first else {
            AppLog.error(.player, "No sources available for KSPlayer")
            return
        }

        let mediaURL = PlaybackService.resolvePlayableURL(
            for: source.url,
            title: mediaTitle,
            episode: episode.number
        )

        var options = KSOptions()
        options.startPlayTime = startAt ?? 0
        options.hardwareDecode = true

        if !mediaURL.isFileURL && !source.headers.isEmpty {
            for (key, value) in source.headers {
                options.appendHeader([key: value])
            }
        }

        let definition = KSPlayerResourceDefinition(
            url: mediaURL,
            definition: source.quality,
            options: options
        )

        let resource = KSPlayerResource(
            name: mediaTitle ?? "Episode \(episode.number)",
            definitions: [definition]
        )

        playerView.set(resource: resource)

        AppLog.debug(.player, "KSPlayer loading: \(mediaURL.absoluteString) (quality: \(source.quality))")
    }

    class Coordinator {
        var playerView: IOSVideoPlayerView?
        var controller: UIViewController?
    }
}

#endif

#if os(iOS) && !canImport(KSPlayer)
struct KSPlayerScreen: View {
    let episode: SoraEpisode
    let sources: [SoraSource]
    let mediaId: Int
    let malId: Int?
    let mediaTitle: String?
    let startAt: Double?
    let onRestoreAfterPictureInPicture: (() -> Void)?

    var body: some View {
        Color.black
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "play.slash.fill")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                    Text("KSPlayer is not available in this build.")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Switch the playback engine to AVPlayer or mpv.")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.72))
                }
                .multilineTextAlignment(.center)
                .padding(24)
            }
    }
}
#endif
