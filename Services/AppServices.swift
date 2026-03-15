import Foundation

@MainActor
final class AppServices {
    let keychain = KeychainService()
    let cacheStore = CacheStore()
    let aniListClient: AniListClient
    let aniListAuth: AniListAuthService
    let mediaTracker: MediaTracker
    let playbackEngine: PlaybackEngine
    let offlineManager: OfflineManager
    let metadataService: MetadataService
    let aniSkipService: AniSkipService
    let downloadManager: DownloadManager
    let libraryStore: MediaTracker
    let episodeService: EpisodeService

    init() {
        self.aniListClient = AniListClient(cacheStore: cacheStore)
        self.aniListAuth = AniListAuthService()
        self.mediaTracker = MediaTracker()
        self.playbackEngine = PlaybackEngine()
        self.offlineManager = OfflineManager()
        self.metadataService = MetadataService(cacheStore: cacheStore)
        self.aniSkipService = AniSkipService()
        self.downloadManager = DownloadManager.shared
        self.libraryStore = MediaTracker()
        self.episodeService = EpisodeService()
    }
}
