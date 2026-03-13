import Foundation

typealias AniListService = AniListClient
typealias MediaRemuxer = MediaConversionManager

struct DependencyContainer: Sendable {
    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: MediaTracker
}

actor AppDependencyContainer {
    static let shared = AppDependencyContainer()

    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: MediaTracker

    init(
        aniListService: AniListService = AniListClient(cacheStore: CacheStore()),
        downloadManager: DownloadManager = .shared,
        mediaRemuxer: MediaRemuxer = .shared,
        libraryStore: MediaTracker = MediaTracker()
    ) {
        self.aniListService = aniListService
        self.downloadManager = downloadManager
        self.mediaRemuxer = mediaRemuxer
        self.libraryStore = libraryStore
    }

    func container() -> DependencyContainer {
        DependencyContainer(
            aniListService: aniListService,
            downloadManager: downloadManager,
            mediaRemuxer: mediaRemuxer,
            libraryStore: libraryStore
        )
    }
}
