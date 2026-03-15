import Foundation

struct PlaybackService {
    @MainActor
    static func resolvePlayableURL(for sourceURL: URL) -> URL {
        if let item = DownloadManager.shared.items.first(where: { $0.url == sourceURL }),
           let local = DownloadManager.shared.playableURL(for: item) {
            AppLog.debug(.player, "playback resolve: download item=\(item.id) local=\(local.path)")
            return local
        }
        AppLog.debug(.player, "playback resolve: using remote url=\(sourceURL)")
        return sourceURL
    }

}
