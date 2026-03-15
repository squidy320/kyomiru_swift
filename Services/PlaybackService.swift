import Foundation

struct PlaybackService {
    @MainActor
    static func resolvePlayableURL(for sourceURL: URL, title: String?, episode: Int?) -> URL {
        if let title, let episode,
           let item = DownloadManager.shared.downloadedItem(title: title, episode: episode),
           let local = DownloadManager.shared.playableURL(for: item) {
            AppLog.debug(.player, "playback resolve: matched download title=\(title) ep=\(episode) local=\(local.path)")
            return local
        }
        if let item = DownloadManager.shared.items.first(where: { $0.url == sourceURL }),
           let local = DownloadManager.shared.playableURL(for: item) {
            AppLog.debug(.player, "playback resolve: download item=\(item.id) local=\(local.path)")
            return local
        }
        AppLog.debug(.player, "playback resolve: using remote url=\(sourceURL)")
        return sourceURL
    }

}
