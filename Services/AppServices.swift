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
    let episodeMetadataService: EpisodeMetadataService
    let aniSkipService: AniSkipService
    let trendingService: TrendingService
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
        self.episodeMetadataService = EpisodeMetadataService(cacheStore: cacheStore, provider: .tmdb)
        self.aniSkipService = AniSkipService()
        self.trendingService = TrendingService(cacheStore: cacheStore)
        self.downloadManager = DownloadManager.shared
        self.libraryStore = MediaTracker()
        self.episodeService = EpisodeService()
    }
}
