import Foundation

typealias AniListService = AniListClient
typealias MediaRemuxer = MediaConversionManager

struct DependencyContainer {
    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: MediaTracker
}

@MainActor
actor AppDependencyContainer {
    static let shared = AppDependencyContainer()

    let aniListService: AniListService
    let downloadManager: DownloadManager
    let mediaRemuxer: MediaRemuxer
    let libraryStore: MediaTracker

    init(
        aniListService: AniListService? = nil,
        downloadManager: DownloadManager? = nil,
        mediaRemuxer: MediaRemuxer? = nil,
        libraryStore: MediaTracker? = nil
    ) {
        self.aniListService = aniListService ?? AniListClient(cacheStore: CacheStore())
        self.downloadManager = downloadManager ?? .shared
        self.mediaRemuxer = mediaRemuxer ?? .shared
        self.libraryStore = libraryStore ?? MediaTracker()
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
