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
    let tmdbMatchingService: TMDBMatchingService
    let aniSkipService: AniSkipService
    let trendingService: TrendingService
    let ratingService: RatingService
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
        self.tmdbMatchingService = TMDBMatchingService(cacheStore: cacheStore)
        self.episodeMetadataService = EpisodeMetadataService(
            cacheStore: cacheStore,
            aniListClient: aniListClient,
            provider: .tmdb,
            tmdbMatcher: tmdbMatchingService
        )
        self.aniSkipService = AniSkipService()
        self.trendingService = TrendingService(cacheStore: cacheStore)
        self.ratingService = RatingService(cacheStore: cacheStore, tmdbMatcher: tmdbMatchingService)
        self.downloadManager = DownloadManager.shared
        self.libraryStore = MediaTracker()
        self.episodeService = EpisodeService()
    }
}
