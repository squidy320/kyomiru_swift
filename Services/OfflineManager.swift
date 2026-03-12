import Foundation

final class OfflineManager: ObservableObject {
    @Published private(set) var activeDownloads: Set<UUID> = []

    func beginDownload(for item: MediaItem) {
        guard !activeDownloads.contains(item.id) else { return }
        activeDownloads.insert(item.id)
        AppLog.debug(.downloads, "offline download start media=\(item.title)")
    }

    func endDownload(for item: MediaItem) {
        guard activeDownloads.contains(item.id) else { return }
        activeDownloads.remove(item.id)
        AppLog.debug(.downloads, "offline download complete media=\(item.title)")
    }

    func isDownloading(_ item: MediaItem) -> Bool {
        activeDownloads.contains(item.id)
    }
}
