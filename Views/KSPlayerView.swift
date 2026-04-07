import SwiftUI
#if os(iOS)
import AVFoundation
import UIKit
import KSPlayer
#endif

#if os(iOS)
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
            AppLog.error(.playback, "No sources available for KSPlayer")
            return
        }

        let mediaURL = PlaybackService.resolvePlayableURL(
            for: source.url,
            title: mediaTitle,
            episode: episode.number
        )

        var options = KSOptions()
        options.isAutoPlay = true
        options.startPlayTime = startAt ?? 0
        options.hardwareDecode = true

        if !mediaURL.isFileURL && !source.headers.isEmpty {
            for (key, value) in source.headers {
                options.appendHeader([key: value])
            }
        }

        let definition = KSPlayerResourceDefinition(
            url: mediaURL,
            definition: source.quality ?? "default",
            options: options
        )

        let resource = KSPlayerResource(
            name: mediaTitle ?? episode.title ?? "Episode \(episode.number)",
            definitions: [definition]
        )

        playerView.set(resource: resource)

        AppLog.debug(.playback, "KSPlayer loading: \(mediaURL.absoluteString) (quality: \(source.quality ?? "default"))")
    }

    class Coordinator {
        var playerView: IOSVideoPlayerView?
        var controller: UIViewController?
    }
}

#endif
